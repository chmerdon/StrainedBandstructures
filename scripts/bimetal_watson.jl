module bimetal

using NanoWiresJulia
using GradientRobustMultiPhysics
using ExtendableGrids
using SimplexGridFactory
using Triangulate
using GridVisualize
using DrWatson
using DataFrames

## start with run_watson() --> result goto data directory
## postprocess data with postprocess(; Plotter = PyPlot) --> images go to plots directory

# configure Watson
@quickactivate "NanoWiresJulia" # <- project name
# set parameters that should be included in filename
watson_accesses = ["scale", "latfac", "femorder", "full_nonlin", "nrefs", "strainm", "mb"] 
watson_allowedtypes = (Real, String, Symbol, Array, DataType)
watson_datasubdir = "bimetal_watson"

function run_watson(; force::Bool = false)

    allparams = Dict(
        "latfac" => Array{Float64,1}(0:0.02:0.2),  # lattice factor between material A and B (lc = [5,5*(1+latfac)])
        "E" => [[1e-6, 1e-6]],                     # elastic moduli of material A and B
        "ν" => [[0.15, 0.15]],                     # Poisson numbers of material A and B
        "strainm" => [NonlinearStrain2D],          # strain model
        "full_nonlin" => [true],                   # use complicated model (ignored if linear strain is used)
        "use_emb" => [true],                       # use embedding (true) or damping (false) solver ?
        "nsteps" => [4],                           # number of embedding steps in embedding solver
        "maxits" => [100],                         # max number of iteration in each embedding step
        "tres" => [1e-12],                         # target residual in each embedding step
        "scale" => [[50,2000], [100, 2000]],       # dimensions of bimetal
        "mb" => [0.25, 0.5, 0.75],                 # share of material A vs. material B
        "femorder" => [3],                         # order of the finite element discretisation
        "upscaling" => [2],                        # upscaling of results (does so many extra nrefs for plots)
        "nrefs" => [1],                            # number of uniform refinements before solve
        "avgc" => [2],                             # lattice number calculation method (average case)
    )

    dicts = dict_list(allparams)
    @info "Starting bimetal simulations..." dicts

    # run the simulations and save data
    for (i, d) in enumerate(dicts)
        filename = savename(d, "jld2"; allowedtypes = watson_allowedtypes, accesses = watson_accesses)
        if isfile(datadir(watson_datasubdir, filename)) && !force
            @info "Skipping dataset $filename, because it already exists (and force = $force)..."
        else
            @info "Running dataset $filename..."
            f = makesim(d)
            wsave(datadir(watson_datasubdir, filename), f)
            ## export data to VTK
            filename_vtk = savename(d, ""; allowedtypes = watson_allowedtypes, accesses = watson_accesses)
            writeVTK(datadir(watson_datasubdir, filename_vtk), f["solution"][1]; upscaling = f["upscaling"], strain_model = f["strainm"])
        end
    end
end

function makesim(d::Dict)

    ## compute lattice_mismatch
    fulld = copy(d)
    latfac = d["latfac"]
    mb = d["mb"]
    avgc = d["avgc"]
    scale = d["scale"]
    lc = [5, 5 * ( 1 + latfac )]
    misfit_strain, α = get_lattice_mismatch_bimetal(avgc, [scale[1] * mb, scale[1] * (1 - mb)], lc)
    fulld["misfit_strain"] = misfit_strain
    fulld["α"] = α

    # run simulation
    solution = main(fulld)

    # save additional data
    fulld["solution"] = solution
    return fulld
end

## this calculates with user-given misfit strain
function main(d::Dict; verbosity = 0)

    ## unpack paramers
    @unpack latfac, E, ν, misfit_strain, α, full_nonlin, use_emb, nsteps, maxits, tres, scale, mb, femorder, nrefs, strainm, avgc = d
    
    ## set log level
    set_verbosity(verbosity)
    
    ## compute Lame' coefficients μ and λ from ν and E
    μ = E ./ (2  .* (1 .+ ν))
    λ = E .* ν ./ ( (1 .- 2*ν) .* (1 .+ ν))

    ## generate bimetal mesh
    dim::Int = length(scale)
    @assert (femorder in 1:2) || (dim == 2)
    if dim == 3
        xgrid = bimetal_strip3D(; material_border = mb, scale = scale)
        FEType = (femorder == 1) ? H1P1{3} : H1P2{3,3}
    else
        xgrid = bimetal_strip2D(; material_border = mb, scale = scale)
        FEType = H1Pk{2,2,femorder}
    end
    xgrid = uniform_refine(xgrid,nrefs)

    ## setup model
    full_nonlin *= strainm <: NonlinearStrain
    emb::Array{Float64,1} = [full_nonlin ? 1.0 : 0] # array with embedding parameters for complicated model terms

    ## generate problem description
    Problem = PDEDescription("bimetal deformation under misfit strain")
    add_unknown!(Problem; unknown_name = "u", equation_name = "displacement equation")
    add_operator!(Problem, 1, get_displacement_operator(IsotropicElasticityTensor(λ[1], μ[1], dim), strainm, misfit_strain[1], α[1]; dim = dim, emb = emb, regions = [1], quadorder = 2*(femorder-1)))
    add_operator!(Problem, 1, get_displacement_operator(IsotropicElasticityTensor(λ[2], μ[2], dim), strainm, misfit_strain[2], α[2]; dim = dim, emb = emb, regions = [2], quadorder = 2*(femorder-1)))
    add_boundarydata!(Problem, 1, [1], HomogeneousDirichletBoundary)
    @show Problem

    ## solve system with FEM
    if use_emb
        Solution = solve_by_embedding(Problem, xgrid, emb, nsteps = [nsteps], FETypes = [FEType], target_residual = [tres], maxiterations = [maxits])
    else
        energy = get_energy_integrator(stress_tensor, strainm, α; dim = dim)
        Solution = solve_by_damping(Problem, xgrid, energy; FETypes = [FEType], target_residual = tres, maxiterations = maxits)
    end

    return Solution
end

function get_lattice_mismatch_bimetal(avgc, geometry, lc)
    r::Array{Float64,1} = geometry[1:2]
    a::Array{Float64,1} = zeros(Float64,2)

    A_core = r[1]
    A_stressor = r[2]
    lc_avg = (lc[1]*A_core + lc[2]*A_stressor)/(A_core + A_stressor)

    for j = 1 : 2
        if avgc == 1
            a[j] = (lc[j] - lc[1])/lc[1]
        elseif avgc == 2
            a[j] = (lc[j] - lc_avg)/lc[j]
        elseif avgc == 3
            a[j] = (lc[j] - lc_avg)/lc_avg
        end
    end

    return a .* (1 .+ a./2), a
end


function postprocess(; scales = [[50, 2000], [100, 2000]], maxlc = [0.1, 0.2], nrefs = 1, mb = 0.75, strainm = NonlinearStrain2D, Plotter = nothing)

    @assert Plotter !== nothing "need a Plotter (e.g. PyPlot)"
    Plotter.close("all")
    @info "Starting postprocessing..."

    # load all data
    alldata = collect_results(datadir(watson_datasubdir))

    # init plot
    fig, (ax1, ax2) = Plotter.subplots(2, 1);
    marker = ["o","s"]
    color = ["red", "blue"]
    legend = []

    for j = 1 : length(scales)

        # filter and sort
        scale = scales[j]
        df = filter(:scale => ==(scale), alldata)
        df = filter(:nrefs => ==(nrefs), df)
        df = filter(:mb => ==(mb), df)
        df = filter(:strainm => ==(strainm), df)
        df = filter(:latfac => <=(maxlc[j]), df)
        sort!(df, [:latfac])
        @show df

        # compute curvature etc
        lattice_mismatch = []
        sim_angle = []
        ana_angle = []
        sim_curvature = []
        ana_curvature = []
        for data in eachrow(df)
            solution = data[:solution]
            scale = data[:scale]
        # misfit_strain = data[:misfit_strain]
                ## compute bending statistics (todo: check curvature formula in 3D)
            angle, curvature, dist_bend, farthest_point = compute_statistics(solution[1].FES.xgrid, solution[1], scale)

            # calculate analytic curvature
            E = data[:E]
            α = data[:α]
            mb = data[:mb]
            factor = 1/2*(α[2] - α[1])*(2 + α[1] + α[2])
            h1 = data[:scale][1] * mb
            h2 = data[:scale][1] * (1-mb)
            m = h1/h2
            n = E[1]/E[2]
            analytic_curvature = abs( 6.0 * factor * (1+m)^2 / ((h1+h2) * ( 3*(1+m)^2 + (1+m*n)*(m^2+1/(m*n)))) )
            if farthest_point[1] > 0
                analytic_angle = asin(dist_bend/2*analytic_curvature) * 180/π
            else
                analytic_angle = 180 - asin(dist_bend/2*analytic_curvature) * 180/π
            end
            #@info "dist_bend = $(dist_bend)"
            #@info "simulation ===> R = $(1/curvature) | curvature = $curvature | bending angle = $(angle)°"
            #@info "analytic   ===> R = $(1/analytic_curvature) | curvature = $analytic_curvature | bending angle = $(analytic_angle)°"
            push!(lattice_mismatch, data[:latfac])
            push!(sim_angle, angle)
            push!(ana_angle, analytic_angle)
            push!(sim_curvature, curvature)
            push!(ana_curvature, analytic_curvature)
        end
            
        @info "Plotting ..."
        lattice_mismatch *= 100
        ax1.plot(lattice_mismatch, sim_curvature, color = color[j], marker = marker[j])
        ax1.plot(lattice_mismatch, ana_curvature, color = color[j], linestyle = "--")
        ax2.plot(lattice_mismatch, sim_angle, color = color[j], marker = marker[j])
        ax2.plot(lattice_mismatch, ana_angle, color = color[j], linestyle = "--")

        ax1.set_title("Core: $(Int(mb*100))%, Stressor: $(Int((1-mb)*100))%")
        append!(legend, ["simulation, d = $(scale[1])","analytic, d = $(scale[1])"])
        ax1.set_ylabel("curvature")
        ax2.set_ylabel("angle")
        ax2.set_xlabel("lattice mismatch (%)")
    end

    ax1.legend(legend)
    ax2.legend(legend)
    Plotter.savefig("plots/curvature_angle_material_border=$(mb).png")
end

end