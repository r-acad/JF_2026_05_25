#!/usr/bin/env julia

using Pkg

function _usage()
    return """
    usage:
      julia --startup-file=no --project=<repo> JFEM_installation/julia_tools/install_julia_packages.jl [options]

    options:
      --no-precompile     Install/instantiate packages but skip explicit precompile.
      --offline           Ask Julia Pkg to use only already cached package artifacts.
      --update-registry   Update Julia package registries before instantiating.
      -h, --help          Show this help.

    This script installs the OpenJFEM Julia environment declared by Project.toml
    and Manifest.toml. It does not maintain a second hand-written dependency
    list; the repository package files remain the source of truth.
    """
end

function _repo_root()
    return normpath(joinpath(@__DIR__, "..", ".."))
end

function _parse_args(args)
    precompile = true
    offline = false
    update_registry = false

    for arg in args
        if arg in ("-h", "--help", "help")
            print(_usage())
            return nothing
        elseif arg == "--no-precompile"
            precompile = false
        elseif arg == "--offline"
            offline = true
        elseif arg == "--update-registry"
            update_registry = true
        else
            error("unknown option: $arg")
        end
    end

    return (; precompile, offline, update_registry)
end

function main(args=ARGS)
    options = _parse_args(args)
    options === nothing && return 0

    repo = _repo_root()
    project = joinpath(repo, "Project.toml")
    manifest = joinpath(repo, "Manifest.toml")
    isfile(project) || error("Project.toml not found: $project")

    println("OpenJFEM Julia package setup")
    println("  project:  $project")
    if isfile(manifest)
        println("  manifest: $manifest")
    else
        println("  manifest: not found; Julia will resolve Project.toml dependencies")
    end
    println()

    if options.offline
        ENV["JULIA_PKG_OFFLINE"] = "true"
        println("Using Julia Pkg offline mode.")
    end

    Pkg.activate(repo)

    if options.update_registry && !options.offline
        println("Updating Julia package registries...")
        Pkg.Registry.update()
    elseif options.update_registry
        println("Skipping registry update because --offline was requested.")
    end

    println("Instantiating packages from Project.toml/Manifest.toml...")
    Pkg.instantiate()

    if options.precompile
        println("Precompiling packages...")
        Pkg.precompile()
    else
        println("Skipping explicit precompile; the sysimage builder will run its workload next.")
    end

    println("Verifying OpenJFEM can be loaded...")
    @eval using OpenJFEM

    println()
    println("OpenJFEM Julia package setup complete.")
    return 0
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main())
end
