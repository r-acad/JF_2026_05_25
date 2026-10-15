#!/usr/bin/env julia
# Explicit full install/repair. First launch also installs missing package sources.
include(joinpath(@__DIR__,"src","runtime_bootstrap.jl"))
WingFEGenBootstrap.restart_if_needed(@__DIR__,@__FILE__;use_image=false)
repo=WingFEGenBootstrap.locate_solver(@__DIR__)
repo===nothing&&error("Enclosing JFEM checkout not found. Keep the JFEM-Boxer application folder inside the solver repository, or set WINGFEGEN_JFEM.")
include(joinpath(repo,"utils","julia_tools","install_julia_packages.jl"))
exit(JFEMPackageSetup.main(vcat(["--wingfegen-project="*@__DIR__],ARGS)))
