#!/usr/bin/env julia
# Build only from the already prepared package environment; never invoke setup.
include("prepared_sysimage_builder.jl")
if abspath(PROGRAM_FILE) == @__FILE__
    try
        JFEMPreparedSysimageBuilder.build(normpath(joinpath(@__DIR__,"..","..")),ARGS)
    catch failure
        println(stderr,"JFEM sysimage build failed: ",sprint(showerror,failure))
        exit(1)
    end
end
