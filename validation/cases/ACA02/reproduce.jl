# Run from the JFEM repository using: julia --project=. validation/cases/ACA02/reproduce.jl
# Results go to a new local rerun folder; published artifacts are preserved.
empty!(ARGS)
append!(ARGS,[dirname(@__DIR__),joinpath(@__DIR__,"reruns",string(time_ns())),"ACA02"])
include(joinpath(@__DIR__,"..","..","run_academic_cases.jl"))
