#!/usr/bin/env julia
# Compatibility entry: all applications now use the same repository image.
length(ARGS)==2||error("usage: build_boxer_sysimage.jl REPOSITORY IMAGE")
repo,image=abspath.(ARGS)
empty!(ARGS);push!(ARGS,"--sysimage="*image)
using Pkg
Pkg.activate(repo;io=devnull)
include("deploy_fast.jl")
deploy_main()
