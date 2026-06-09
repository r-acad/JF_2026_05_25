module OpenJFEM

# Eager `using` of every external dep so the precompile cache image bakes
# them in. First `using OpenJFEM` after precompile is a few seconds;
# subsequent sessions pull straight from the cache instead of re-parsing
# HDF5 / KrylovKit / ForwardDiff / AlgebraicMultigrid / WriteVTK / ...
using LinearAlgebra
using SparseArrays
using Statistics
using StaticArrays
using Printf
using Dates
using JSON
using HDF5
using WriteVTK
using KrylovKit
using IterativeSolvers
using AlgebraicMultigrid
using ForwardDiff
using PrecompileTools

# ---- Submodule: FEM (element kernels) -----------------------------------
include("FEMKernels.jl")
using .FEM

# ---- Submodule: NastranParser -------------------------------------------
include("parsing/NastranParser.jl")
using .NastranParser

# ---- Submodule: Solver --------------------------------------------------
include("solver/SolverCore.jl")
# Eagerly load the full solver (adjoint, buckling adjoint, optimizer) so
# those are baked into the precompile cache too. The lazy-load hooks in
# JFEMSolver.jl become no-ops.
Solver.load_full_solver_extensions!()
using .Solver

# ---- Top-level OpenJFEM files ------------------------------------------
# Order: ModelBuilder -> JFEMSolver -> Export -> main.
# JFEMSolver's _export_results_impl references symbols that are defined
# in Export.jl, but only at call time, so parsing order is safe.
include("backend/BackendInterface.jl")
include("backend/tacs_formulation/core.jl")
include("backend/tacs_formulation/sol101.jl")
include("ModelBuilder.jl")
include("JFEMSolver.jl")
include("Export.jl")
include("MarkdownReport.jl")
include("main.jl")
include("precompile_workload.jl")

const _THREAD_HINT_SHOWN = Ref(false)
function __init__()
    if Threads.nthreads() == 1 && !haskey(ENV, "JFEM_SUPPRESS_THREAD_HINT")
        @info "OpenJFEM: running with 1 Julia thread. Start Julia with `--threads=N` " *
              "(e.g. `julia --project=. --threads=8 ...`) to parallelize assembly; " *
              "this typically cuts stiffness-assembly time by 6-10x on large models. " *
              "Silence this with `ENV[\"JFEM_SUPPRESS_THREAD_HINT\"]=1`."
    end
    _THREAD_HINT_SHOWN[] = true
    return nothing
end

# ---- Public API ---------------------------------------------------------
export main,
       bdf_to_model, bdf_to_model_json, json_to_model,
       solve_model,
       AbstractJFEMBackend, NastranParityBackend, TACSFormulationBackend,
       backend_from_model, backend_from_name, backend_name,
       static_compliance_thickness_gradient, static_displacement_thickness_gradient,
       static_compliance_design_gradient, static_displacement_design_gradient,
       static_ks_displacement_design_gradient,
       static_ks_von_mises_design_gradient,
       static_ks_ply_failure_design_gradient,
       structural_mass_design_gradient,
       buckling_load_factor_thickness_gradient, buckling_load_factor_design_gradient,
       buckling_load_factor_ks_design_gradient,
       modal_eigenvalue_design_gradient,
       eigen_mode_tracking_reference, eigen_mode_continuation_update,
       solve_adjoint, solve_adjoint_buckling,
       optimize_thickness, optimize_sizing,
       build_model, resolve_nested_coords!, transform_geometry!,
       export_results, export_adjoint_json,
       FEM, NastranParser, Solver

end # module OpenJFEM
