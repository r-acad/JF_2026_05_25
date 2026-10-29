# One-command deployment for fast OpenJFEM runs.
#
# Usage:
#   julia --threads=auto --startup-file=no --project=JFEM "JFEM/utils/julia_tools/deploy_fast.jl"
#   julia --threads=auto --startup-file=no --project=JFEM "JFEM/utils/julia_tools/deploy_fast.jl" --deck path/to/representative.bdf
#   julia --threads=auto --startup-file=no --project=JFEM "JFEM/utils/julia_tools/deploy_fast.jl" --manifest cases.json
#
# Optional:
#   --sysimage=JFEM/sysimage/OpenJFEM_sysimage.dll
#   --install-packagecompiler

using JSON
using Pkg
include(joinpath(@__DIR__, "precompile_deployment.jl"))
include(joinpath(@__DIR__, "sysimage_provenance.jl"))
include(joinpath(@__DIR__, "shared_precompile_workloads.jl"))

get!(ENV,"JULIA_NUM_PRECOMPILE_TASKS","2")
get!(ENV,"JULIA_IMAGE_THREADS","2")
const DEFAULT_FLAGS = "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1,JFEM_PRECOMPILE_BOXER="*get(ENV,"JFEM_PRECOMPILE_BOXER","1")

function _usage()
    return """
    usage:
      julia --threads=auto --startup-file=no --project=JFEM "JFEM/utils/julia_tools/deploy_fast.jl" [options]

    options:
      --deck <path>                 Add one representative deck to the precompile workload.
      --manifest <path>             Add every case input from a JSON batch manifest.
      --flags <FLAG=val,...>        Precompile flags. Default: $(DEFAULT_FLAGS)
      --sysimage=<path>             Optionally build a PackageCompiler sysimage.
      --install-packagecompiler     Allow this script to add PackageCompiler if --sysimage is used.

    With no --deck or --manifest, the bundled
    utils/examples/precompile decks are used. Those decks are tiny
    redistributable cases intended only to warm common parser/assembly/solve
    paths.
    """
end

function _bundled_decks()
    dir = normpath(joinpath(@__DIR__, "..", "examples", "precompile"))
    isdir(dir) || return String[]
    paths = String[]
    for name in sort(readdir(dir))
        ext = lowercase(splitext(name)[2])
        ext in (".bdf", ".dat", ".nas") || continue
        path = joinpath(dir, name)
        isfile(path) && push!(paths, abspath(path))
    end
    return paths
end

function _abs_file(path::AbstractString)
    p = normpath(isabspath(path) ? path : joinpath(pwd(), path))
    isfile(p) || error("file not found: $p")
    return abspath(p)
end

function _manifest_decks(path::AbstractString)
    p = _abs_file(path)
    data = JSON.parsefile(p)
    data isa AbstractDict || error("manifest must be a JSON object: $p")
    cases = get(data, "cases", nothing)
    cases isa AbstractVector || error("manifest requires cases array: $p")
    base = dirname(p)
    decks = String[]
    for (idx, item) in enumerate(cases)
        item isa AbstractDict || error("case $idx must be an object")
        raw = get(item, "input", get(item, "deck", nothing))
        raw === nothing && error("case $idx missing input")
        deck = normpath(isabspath(string(raw)) ? string(raw) : joinpath(base, string(raw)))
        isfile(deck) || error("case $idx deck not found: $deck")
        push!(decks, abspath(deck))
    end
    return decks
end

function _parse_args(args)
    decks = String[]
    manifests = String[]
    flags = DEFAULT_FLAGS
    sysimage = ""
    install_packagecompiler = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("-h", "--help", "help")
            print(_usage())
            exit(0)
        elseif arg == "--deck"
            i += 1; i <= length(args) || error("--deck requires a path")
            push!(decks, _abs_file(args[i]))
        elseif startswith(arg, "--deck=")
            push!(decks, _abs_file(arg[length("--deck=")+1:end]))
        elseif arg == "--manifest"
            i += 1; i <= length(args) || error("--manifest requires a path")
            push!(manifests, args[i])
        elseif startswith(arg, "--manifest=")
            push!(manifests, arg[length("--manifest=")+1:end])
        elseif arg == "--flags"
            i += 1; i <= length(args) || error("--flags requires a value")
            flags = args[i]
        elseif startswith(arg, "--flags=")
            flags = arg[length("--flags=")+1:end]
        elseif startswith(arg, "--sysimage=")
            sysimage = normpath(arg[length("--sysimage=")+1:end])
        elseif arg == "--install-packagecompiler"
            install_packagecompiler = true
        else
            error("unknown option: $arg")
        end
        i += 1
    end
    for m in manifests
        append!(decks, _manifest_decks(m))
    end
    isempty(decks) && append!(decks, _bundled_decks())
    unique!(decks)
    return decks, flags, sysimage, install_packagecompiler
end

function _setenv_preserving!(old::Dict{String,Union{Nothing,String}}, key, value)
    k = string(key)
    old[k] = haskey(ENV, k) ? ENV[k] : nothing
    ENV[k] = string(value)
end

function _restore_env!(old)
    for (key, value) in old
        if value === nothing
            delete!(ENV, key)
        else
            ENV[key] = value
        end
    end
end

function _write_sysimage_precompile_script(path::AbstractString, decks::Vector{String}, flags::AbstractString)
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    open(path, "w") do io
        println(io, "using OpenJFEM")
        println(io, "const _decks = ", repr(decks))
        println(io, "const _flags = ", repr(flags))
        println(io, "const _repo_root = ", repr(repo_root))
        println(io, "function _apply_flags(raw)")
        println(io, "    sep = occursin(\";\", raw) ? \";\" : \",\"")
        println(io, "    for kv in split(raw, sep)")
        println(io, "        isempty(strip(kv)) && continue")
        println(io, "        parts = split(kv, \"=\"; limit=2)")
        println(io, "        length(parts) == 2 || continue")
        println(io, "        ENV[strip(parts[1])] = strip(parts[2])")
        println(io, "    end")
        println(io, "end")
        println(io, "_apply_flags(_flags)")
        println(io, "ENV[\"JFEM_SUPPRESS_THREAD_HINT\"] = \"1\"")
        # --- (1) CLI path: OpenJFEM.main on each deck (covers run_bdf.jl / jfem) ---
        println(io, "for deck in _decks")
        println(io, "    println(\"Shared warmup: native solver \", basename(deck)); flush(stdout)")
        println(io, "    out = mktempdir(; prefix=\"openjfem_sysimage_precompile_\")")
        println(io, "    try")
        println(io, "        redirect_stdout(devnull) do; redirect_stderr(devnull) do")
        println(io, "            OpenJFEM.main(deck; output_dir=out, export_jfem_binary=true,")
        println(io, "                          export_json=true, export_report=true)")
        println(io, "        end; end")
        println(io, "    catch err")
        println(io, "        @warn \"sysimage precompile (main) deck failed\" deck exception=(err, catch_backtrace())")
        println(io, "        rethrow()")
        println(io, "    end")
        println(io, "end")
        # Exercise real MessagePack POST requests, including service validation
        # and viewer export. Every route and analysis must succeed.
        println(io, "include(",repr(joinpath(@__DIR__,"shared_precompile_workloads.jl")),")")
        println(io, "JFEMSharedPrecompileWorkloads.required_packages()")
        println(io, "println(\"Shared warmup: PANDEATOR HTTP analyses\"); flush(stdout)")
        println(io, "JFEMSharedPrecompileWorkloads.run_pandeator(_repo_root, _decks)")
        println(io, "println(\"Shared warmup: imported-model adjoint\"); flush(stdout)")
        println(io, "include(",repr(joinpath(@__DIR__,"sensitivity_precompile_workload.jl")),")")
        println(io, "println(\"Shared warmup: JFEM-Boxer generation, VLM and server\"); flush(stdout)")
        println(io, "include(",repr(joinpath(@__DIR__,"boxer_precompile_workload.jl")),")")
        println(io, "println(\"Shared warmup: all required workloads passed\"); flush(stdout)")
    end
    return path
end

function _maybe_build_sysimage(sysimage::AbstractString, decks::Vector{String}, flags::AbstractString, install_packagecompiler::Bool)
    isempty(sysimage) && return nothing
    packagecompiler_available = Base.find_package("PackageCompiler") !== nothing
    if !packagecompiler_available
        if install_packagecompiler
            println("Installing PackageCompiler because --install-packagecompiler was requested...")
            Pkg.add("PackageCompiler")
        else
            error("PackageCompiler is required for the shared image. Run setup in the complete repository, or explicitly choose --no-sysimage there.")
        end
    end
    packagecompiler = Base.require(Base.PkgId(
        Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"),
        "PackageCompiler"))
    mkpath(dirname(abspath(sysimage)))
    script = joinpath(mktempdir(; prefix="openjfem_sysimage_"), "precompile_execution.jl")
    _write_sysimage_precompile_script(script, decks, flags)
    println("Building OpenJFEM sysimage: $sysimage")
    println("This can take several minutes.")
    # Every installed application shares these packages and the same image.
    # Missing applications or failed warmups must never look like a full build.
    pkgs = JFEMSharedPrecompileWorkloads.required_packages()
    println("  sysimage packages: ", join(string.(pkgs), ", "))
    flush(stdout)
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    source_before = JFEMSysimageProvenance.input_hashes(repo_root)
    environment_before = JFEMSysimageProvenance.environment_identity(repo_root; environment=repo_root)
    workload_before = JFEMSysimageProvenance.workload_hashes(decks, flags)
    Base.invokelatest(getfield(packagecompiler, :create_sysimage), pkgs;
        sysimage_path=sysimage,
        precompile_execution_file=script)
    receipt = JFEMSysimageProvenance.write_sidecar(repo_root, sysimage, source_before, workload_before;
        environment=repo_root, environment_before)
    println("Sysimage provenance: $receipt")
    println("Sysimage complete: $sysimage")
    return sysimage
end

function deploy_main(args=ARGS)
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    selected = JFEMSysimageProvenance.environment_directory(repo_root,nothing)
    selected == realpath(repo_root) || error("For an existing prepared package environment, use build_prepared_sysimage.jl (JFEM_BUILD_SYSIMAGE); ordinary deployment uses the repository environment.")
    active = Base.active_project()
    active !== nothing && realpath(dirname(active)) == realpath(repo_root) ||
        error("Run ordinary deployment with --project pointing to the repository, or use build_prepared_sysimage.jl for a prepared environment.")
    decks, flags, sysimage, install_packagecompiler = _parse_args(args)
    isempty(decks) && error("no precompile decks found")

    println("OpenJFEM fast deployment")
    println("  decks:   $(length(decks))")
    for deck in decks
        println("    - ", deck)
    end
    println("  flags:   ", flags)
    println("  threads: ", Threads.nthreads())
    println()

    old_env = Dict{String,Union{Nothing,String}}()
    try
        _setenv_preserving!(old_env, "JFEM_PRECOMPILE_WORKLOAD", "true")
        _setenv_preserving!(old_env, "JFEM_PRECOMPILE_BDF", join(decks, ";"))
        _setenv_preserving!(old_env, "JFEM_PRECOMPILE_FLAGS", flags)
        _setenv_preserving!(old_env, "JFEM_SOL105_PRECOMPILE_WORKLOAD", "true")
        _setenv_preserving!(old_env, "JFEM_SOL105_PRECOMPILE_BDF", join(decks, ";"))
        _setenv_preserving!(old_env, "JFEM_SOL105_PRECOMPILE_FLAGS", flags)
        _setenv_preserving!(old_env, "JFEM_SUPPRESS_THREAD_HINT", "1")

        if isempty(sysimage)
            println("Instantiating dependencies and refreshing the requested package workload...")
            refresh_deployment_precompile!(Base.PkgId(
                Base.UUID("5f27aa24-1c38-4f48-8d29-0194396c76b2"), "OpenJFEM"))
        else
            # The image's execution script runs every requested deck below. Reuse
            # current package caches instead of rebuilding them immediately after
            # setup; Pkg still compiles missing or stale package sources normally.
            println("Instantiating dependencies and reusing current package caches...")
            Pkg.instantiate(;allow_autoprecomp=false)
            Pkg.precompile()
        end

        println("Verifying package load...")
        @eval using OpenJFEM
    finally
        _restore_env!(old_env)
    end

    _maybe_build_sysimage(sysimage, decks, flags, install_packagecompiler)

    println()
    println("OpenJFEM fast deployment complete.")
    println("For command-line batches use JFEM/utils/julia_tools/run_batch_manifest.jl.")
    println("For Python optimization loops start JFEM/utils/julia_tools/jfem_worker_jsonl.jl once and send JSONL commands.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    deploy_main()
end
