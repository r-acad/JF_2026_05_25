# Automatic launcher selection only. An explicit `julia -J` remains untouched.
include(joinpath(@__DIR__, "sysimage_provenance.jl"))
length(ARGS) in (2,3) || (println(stderr, "usage: check_sysimage.jl ROOT IMAGE [solver|boxer]"); exit(2))
current, reason = JFEMSysimageProvenance.check_sysimage(ARGS[1], ARGS[2];kind=length(ARGS)==3 ? ARGS[3] : "solver")
if !current
    println(stderr, "OpenJFEM: automatic sysimage skipped (", reason, "); using normal package loading. Rebuild with deploy_fast.jl to refresh it.")
end
exit(current ? 0 : 1)
