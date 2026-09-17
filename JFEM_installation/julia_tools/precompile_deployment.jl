using Pkg

"""
    refresh_deployment_precompile!(package)

Build the requested package cache using the deployment environment already set
by the caller. Ordinary `Pkg.precompile()` can reuse a valid package cache even
when the representative deck path, its contents, or workload flags have changed:
those environment-selected inputs are not package-cache dependencies.

This explicit deployment operation refreshes the package without deleting any
cache directory. Run it before loading the package in the current process.
"""
function refresh_deployment_precompile!(package::Base.PkgId)
    haskey(Base.loaded_modules, package) && throw(ArgumentError(
        "$(package.name) is already loaded; run deployment in a fresh Julia process without its custom sysimage"))

    # Avoid compiling OpenJFEM implicitly and then immediately compiling it a
    # second time. compilecache also builds any missing dependency caches.
    Pkg.instantiate(; allow_autoprecomp=false)
    println("Refreshing $(package.name) with the requested representative workload...")
    compiled = Base.compilecache(package)
    compiled isa Tuple || error("$(package.name) did not produce a precompiled cache")

    # Also cover project dependencies not imported by the target package.
    Pkg.precompile()
    return compiled
end
