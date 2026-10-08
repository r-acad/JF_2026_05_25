#!/usr/bin/env julia
# Explicit package installation; running the app never silently installs packages.
include(joinpath(@__DIR__,"src","runtime_bootstrap.jl"))
WingFEGenBootstrap.restart_if_needed(@__DIR__,@__FILE__)
using Pkg
repo=WingFEGenBootstrap.locate_solver(@__DIR__)
repo===nothing&&error("Enclosing JFEM checkout not found. Keep WingFEGen inside the solver repository, or set WINGFEGEN_JFEM.")
for project in (repo,@__DIR__)
    println("Installing recorded dependencies: ",project);flush(stdout)
    Pkg.activate(project)
    Pkg.instantiate()
end
println("WingFEGen setup complete. Start with julia --project=\"$(@__DIR__)\" \"$(joinpath(@__DIR__,"run.jl"))\"")
