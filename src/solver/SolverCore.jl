module Solver

using LinearAlgebra
using SparseArrays
using Statistics
using IterativeSolvers
using AlgebraicMultigrid
using KrylovKit
using Dates
using StaticArrays
using JSON
using ForwardDiff
using ..FEM

include("helpers.jl")
include("snorm.jl")
include("loads.jl")
include("constraints.jl")
include("assembly.jl")
include("boundary_conditions.jl")
include("stress_recovery.jl")
include("buckling_result.jl")
include("sol105_calibrated_constants.jl")
include("sol105_options.jl")
include("solve_case.jl")

const _full_solver_extensions_loaded = Ref(false)

function load_full_solver_extensions!()
    if !_full_solver_extensions_loaded[]
        Base.include(@__MODULE__, joinpath(@__DIR__, "dKdx.jl"))
        Base.include(@__MODULE__, joinpath(@__DIR__, "adjoint.jl"))
        Base.include(@__MODULE__, joinpath(@__DIR__, "adjoint_buckling.jl"))
        Base.include(@__MODULE__, joinpath(@__DIR__, "optimize_thickness.jl"))
        _full_solver_extensions_loaded[] = true
    end
    return nothing
end

end # module Solver
