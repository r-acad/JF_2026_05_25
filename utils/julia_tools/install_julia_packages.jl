#!/usr/bin/env julia
module JFEMPackageSetup
include("environment_setup.jl")
using .JFEMEnvironmentSetup
using Pkg
using Libdl
using SHA
include("sysimage_provenance.jl")
include("sysimage_build_guard.jl")

repo_root()=normpath(joinpath(@__DIR__,"..",".."))
function usage(io=stdout)
    print(io,"""
    Usage: julia --startup-file=no "utils/julia_tools/install_julia_packages.jl" [options]

    Sets up JFEM CLI, JFEM-Boxer, PANDEATOR and the static results viewer. Installs the
    single recorded Julia environment for every application; the
    static viewer uses bundled browser assets. No manual package list is needed.

      --no-precompile       Skip explicit package precompilation.
      --no-verify           Skip module-load verification (download-only setup).
      --solver-only         Verify only the solver after shared installation.
      --boxer-only          Verify only Boxer after shared installation.
      --boxer-project=PATH  Compatibility option; must name bundled APPS/JFEM-Boxer.
      --offline             Use only the existing Julia package/artifact cache.
      --update-registry     Refresh registries before installing.
      --dry-run             Print the setup plan without installing anything.
      --sysimage[=PATH]      Build/refresh the shared local image (default).
      --no-sysimage          Skip image builds; use normal Julia package loading.
      --sysimage-threads=N|auto  Build-process threads (default: 2).
      --deck PATH           Representative sysimage deck; repeatable.
      --manifest PATH       JSON batch manifest for the sysimage workload.
      --flags VALUE         Workload FLAG=value,... overrides.
      -h, --help            Show this help.

    Setup may download packages/artifacts and take several minutes.
    --no-precompile alone does not prevent verification from compiling;
    combine it with --no-verify for download-only setup.
    Setup reuses a current shared image or creates one when memory allows.
    Low memory or an image-build error automatically keeps normal Julia package
    loading available and setup completes successfully. Its first numerical
    operation may compile code. Package precompilation uses one task/image thread
    and skips solver training workloads by default; explicit settings are kept.
    --no-sysimage explicitly skips image creation. Combine it with --no-precompile
    and --no-verify for download-only setup.
    A current image is reused only when its source/runtime receipt matches.
    """)
end

function parse_options(args)
    options=Dict{Symbol,Any}(:precompile=>true,:verify=>true,:offline=>false,
        :update_registry=>false,:selection=>:all,:dry_run=>false,:wingfegen=>nothing,
        :sysimage=>"",:sysimage_threads=>"2",:workload=>String[])
    i=1; image_options=false
    while i<=length(args)
        arg=args[i]
        if arg in ("--help","-h","help");return nothing
        elseif arg=="--no-precompile";options[:precompile]=false
        elseif arg=="--no-verify";options[:verify]=false
        elseif arg=="--offline";options[:offline]=true
        elseif arg=="--update-registry";options[:update_registry]=true
        elseif arg=="--dry-run";options[:dry_run]=true
        elseif arg=="--sysimage";options[:sysimage]=""
        elseif arg=="--no-sysimage";options[:sysimage]=nothing
        elseif startswith(arg,"--sysimage=")
            value=chopprefix(arg,"--sysimage=");isempty(value)&&error("Sysimage path is empty")
            options[:sysimage]=abspath(value)
        elseif startswith(arg,"--sysimage-threads=")
            image_options=true
            value=chopprefix(arg,"--sysimage-threads=")
            (value=="auto" || (tryparse(Int,value)!==nothing && parse(Int,value)>0)) || error("Sysimage threads must be auto or a positive integer")
            options[:sysimage_threads]=value
        elseif arg in ("--deck","--manifest","--flags") || any(prefix->startswith(arg,prefix), ("--deck=","--manifest=","--flags="))
            image_options=true
            parts=split(arg,'=';limit=2)
            key=parts[1]
            if length(parts)==1
                i+=1;i<=length(args)||error("$key requires a value")
                value=args[i]
            else
                value=parts[2]
            end
            isempty(value) && error("$key requires a nonempty value")
            if key in ("--deck","--manifest")
                value=abspath(value);isfile(value)||error("$key file not found: $value")
            end
            append!(options[:workload],[key,value])
        elseif arg in ("--solver-only","--wingfegen-only","--boxer-only")
            options[:selection]==:all || error("Choose at most one project-selection option")
            options[:selection]=arg=="--solver-only" ? :solver : :wingfegen
        elseif startswith(arg,"--wingfegen-project=")||startswith(arg,"--boxer-project=")
            path=last(split(arg,'=';limit=2));isempty(path)&&error("JFEM-Boxer project path is empty")
            options[:wingfegen]=abspath(path)
        else;error("Unknown setup option: $arg (see --help)")
        end
        i+=1
    end
    options[:sysimage]===nothing && image_options && error("Workload/build options cannot be combined with --no-sysimage")
    options[:wingfegen]!==nothing &&
        normpath(options[:wingfegen])!=normpath(joinpath(repo_root(),"APPS","JFEM-Boxer")) &&
        error("All applications use the repository environment and bundled APPS/JFEM-Boxer package")
    options
end

function setup_projects(repo,options)
    path=abspath(repo)
    isfile(joinpath(path,"Project.toml"))||error("Repository Project.toml missing at $path")
    isfile(joinpath(path,"APPS","JFEM-Boxer","Project.toml"))||error("Extract the complete JFEM repository, including APPS/JFEM-Boxer")
    JFEMEnvironmentSetup.check_runtime(path)
    ["JFEM"=>path]
end

function verification_command(name,project)
    script=if name=="JFEM"
        "using OpenJFEM; println(\"JFEM module verified.\")"
    elseif name in ("JFEM-Boxer","FGen")
        "using WingFEGen; println(\"JFEM-Boxer module verified.\")"
    elseif name=="PANDEATOR"
        "include("*repr(joinpath(project,"APPS","PANDEATOR_APP","panel_server.jl"))*"); "*
        "for route in (\"/\",\"/health\",\"/vendor/msgpack.min.js\",\"/vendor/babylon.js\",\"/jfem_binary.js\",\"/jfem_graphics.js\",\"/vendor/glslang/glslang.js\",\"/vendor/glslang/glslang.wasm\",\"/vendor/twgsl/twgsl.js\",\"/vendor/twgsl/twgsl.wasm\"); "*
        "handle(HTTP.Request(\"GET\",route)).status==200 || error(\"PANDEATOR route failed: \"*route); end; "*
        "println(\"PANDEATOR module and browser routes verified (no analysis run).\")"
    else
        error("Unknown application: $name")
    end
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    JFEMEnvironmentSetup.configure_compilation_defaults!()
    addenv(`$executable --startup-file=no --history-file=no --project=$project -e $script`,
        "JULIA_NUM_PRECOMPILE_TASKS"=>ENV["JULIA_NUM_PRECOMPILE_TASKS"],
        "JULIA_IMAGE_THREADS"=>ENV["JULIA_IMAGE_THREADS"],
        "JFEM_SOL105_PRECOMPILE_WORKLOAD"=>ENV["JFEM_SOL105_PRECOMPILE_WORKLOAD"])
end

function browser_asset_groups(selection=:all)
    selection in (:all,:solver,:wingfegen) || error("Unknown browser asset selection: $selection")
    groups=Pair{String,String}[]
    selection!=:solver && push!(groups,"APPS/JFEM-Boxer/web"=>"APPS/JFEM-Boxer/web/vendor")
    if selection!=:wingfegen
        push!(groups,"APPS/PANDEATOR_APP"=>"APPS/PANDEATOR_APP/vendor")
        push!(groups,"APPS/JFEM_results_viewer"=>"APPS/PANDEATOR_APP/vendor")
    end
    groups
end

function browser_asset_path(repo,base,relative)
    # Reject CDN substitutions and paths outside the extracted distribution.
    occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:",relative) && error("Browser assets must be bundled locally: $relative")
    startswith(relative,"//") && error("Browser assets must be bundled locally: $relative")
    plain=first(split(relative,r"[?#]";limit=2))
    isabspath(plain) && error("Browser asset path must be relative: $relative")
    path=normpath(joinpath(base,plain));inside=relpath(path,abspath(repo))
    (inside==".."||startswith(inside,"../")||startswith(inside,"..\\")) && error("Browser asset escapes the repository: $relative")
    isfile(path) || error("Bundled browser asset missing: $(relpath(path,repo)). Extract the complete repository again.")
    path
end

"""Check local HTML dependencies before package installation; only stdlibs are needed."""
function verify_browser_asset_files(repo;selection=:all)
    root=abspath(repo)
    for (directory,vendor) in browser_asset_groups(selection)
        base=joinpath(root,directory)
        entry=directory=="APPS/JFEM-Boxer/web" ? "index.html" : directory=="APPS/PANDEATOR_APP" ? "panel_app.html" : "postv11.html"
        browser_asset_path(root,base,entry)
        browser_asset_path(root,joinpath(root,vendor),"provenance.json")
        # Include table/plan windows as well as each application's initial page.
        for file in readdir(base;join=true)
            endswith(lowercase(file),".html")||continue
            for tag in eachmatch(r"(?is)<(?:script|link)\b[^>]*>",read(file,String))
                attribute=startswith(lowercase(tag.match),"<script") ? "src" : "href"
                found=match(Regex("(?i)\\b"*attribute*"\\s*=\\s*[\"']([^\"']+)[\"']"),tag.match)
                if found!==nothing
                    # Boxer serves explicitly shared application scripts through
                    # /shared; the on-disk files live directly under APPS.
                    relative=found[1]
                    if directory=="APPS/JFEM-Boxer/web" && startswith(relative,"shared/")
                        browser_asset_path(root,joinpath(root,"APPS"),chopprefix(relative,"shared/"))
                    else
                        browser_asset_path(root,base,relative)
                    end
                end
            end
        end
    end
    return true
end

function read_browser_provenance(path)
    # JSON is an existing shared-project dependency. Load it only after
    # instantiate so a first installation does not require it in advance.
    isdefined(@__MODULE__,:JSON)||(@eval import JSON)
    # Keep both the newly imported binding and JSON methods in the latest world;
    # return ordinary Dicts so callers do not depend on newly loaded JSON types.
    Base.invokelatest(() -> JSON.parsefile(path;dicttype=Dict{String,Any}))
end

"""Verify the shipped browser bundles without contacting a CDN or registry."""
function verify_viewer_assets(repo;selection=:all)
    verify_browser_asset_files(repo;selection)
    for vendor in unique(last.(browser_asset_groups(selection)))
        base=joinpath(abspath(repo),vendor)
        receipt=read_browser_provenance(joinpath(base,"provenance.json"))
        entries=get(receipt,"dependencies",nothing)
        entries isa AbstractVector&&!isempty(entries)||error("No browser dependencies recorded in $vendor/provenance.json")
        for item in entries
            filename=get(item,"filename","");expected=lowercase(get(item,"local_sha256",""))
            !isempty(filename)&&occursin(r"^[0-9a-f]{64}$",expected)||error("Invalid browser asset receipt in $vendor/provenance.json")
            path=browser_asset_path(repo,base,filename)
            actual=open(sha256,path)|>bytes2hex
            actual==expected||error("Bundled browser asset checksum mismatch: $vendor/$filename. Extract the complete repository again; do not mix files from different versions.")
        end
    end
    return true
end

sysimage_path(repo,options)=options[:sysimage]===nothing ? nothing :
    isempty(options[:sysimage]) ? joinpath(repo,"sysimage","OpenJFEM_sysimage."*Libdl.dlext) : options[:sysimage]

function sysimage_command(repo,options)
    image=sysimage_path(repo,options);image===nothing && error("No sysimage requested")
    script=joinpath(repo,"utils","julia_tools","deploy_fast.jl")
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    command=`$executable --startup-file=no --history-file=no --project=$repo --threads=$(options[:sysimage_threads]) $script --sysimage=$image $(options[:workload])`
    command=addenv(command,"JFEM_PRECOMPILE_BOXER"=>"1",
        "JFEM_SOL105_PRECOMPILE_WORKLOAD"=>"true",
        "JULIA_NUM_THREADS"=>options[:sysimage_threads],
        "JULIA_NUM_PRECOMPILE_TASKS"=>get(ENV,"JULIA_NUM_PRECOMPILE_TASKS","1"),
        "JULIA_IMAGE_THREADS"=>get(ENV,"JULIA_IMAGE_THREADS",options[:sysimage_threads]=="auto" ? string(max(1,Sys.CPU_THREADS÷2)) : options[:sysimage_threads]))
    return options[:offline] ? addenv(command,"JULIA_PKG_OFFLINE"=>"true") : command
end

function build_sysimage(repo,options;runner=run,checker=JFEMSysimageProvenance.check_sysimage)
    image=sysimage_path(repo,options)
    image===nothing && return nothing
    valid,reason=checker(repo,image)
    if valid&&isempty(options[:workload])
        println("Reusing current shared image: ",image);return image
    end
    runner(sysimage_command(repo,options))
    valid,reason=checker(repo,image)
    valid || error("Sysimage build did not produce an eligible image and receipt: $reason")
    println("Verified local sysimage: ",image)
    return image
end

# Compatibility helpers use the same image and environment.
boxer_sysimage_command(repo,options)=sysimage_command(repo,options)
build_boxer_sysimage(repo,options;runner=run)=build_sysimage(repo,options;runner)

"""Complete the optional startup acceleration stage after dependencies are ready."""
function prepare_shared_image(repo, options;
        runner=command->JFEMSysimageBuildGuard.run_build(command;log_root=joinpath(repo,"sysimage","builds")),
        checker=JFEMSysimageProvenance.check_sysimage, io=stdout)
    options[:sysimage] === nothing && return :disabled
    try
        build_sysimage(repo, options; runner, checker)
        println(io, "Startup acceleration is ready.")
        return :ready
    catch failure
        failure isa InterruptException && rethrow()
        println(io, "Setup is ready using normal Julia package loading.")
        println(io, "Shared image creation was skipped: ", sprint(showerror, failure))
        if failure isa JFEMSysimageBuildGuard.BuildUnavailable && !isempty(failure.directory)
            println(io, "Image-build diagnostics: ", failure.directory)
        end
        return :source
    end
end

function main(args=ARGS; image_preparer=prepare_shared_image)
    options=parse_options(args);options===nothing && (usage();return 0)
    JFEMEnvironmentSetup.configure_compilation_defaults!()
    repo=repo_root();projects=setup_projects(repo,options)
    println("JFEM application setup with Julia ",VERSION)
    for (name,path) in projects;println("  ",name,": ",path);end
    options[:selection]!=:wingfegen && println("  Applications: JFEM CLI, PANDEATOR, static results viewer")
    options[:selection]!=:solver && println("  Application: JFEM-Boxer")
    println("  Package precompile: ",options[:precompile],"; application verification: ",options[:verify])
    println("  Package precompile tasks: ",ENV["JULIA_NUM_PRECOMPILE_TASKS"],
        "; image threads: ",ENV["JULIA_IMAGE_THREADS"],
        "; solver training workload: ",ENV["JFEM_SOL105_PRECOMPILE_WORKLOAD"])
    if options[:sysimage]!==nothing
        # Print arguments only: Cmd's full display also exposes its inherited environment.
        println("  Shared image build/reuse with automatic memory fallback: ",Cmd(sysimage_command(repo,options).exec))
        isempty(options[:workload]) && println("  Workload: tiny SOL101/103/105/106, sensitivity, generation and application handlers")
    else
        println("  Sysimage: skipped by --no-sysimage")
    end
    options[:dry_run] && return 0
    println("[Browser assets] Checking bundled app files before package installation...");flush(stdout)
    verify_browser_asset_files(repo;selection=options[:selection])
    Pkg.offline(options[:offline])
    options[:offline] && println("Offline mode: only existing package/artifact caches can be used.")
    for (name,project) in projects
        println("\n[$name] Installing recorded dependencies...");flush(stdout)
        Pkg.activate(project)
        options[:update_registry] && !options[:offline] && Pkg.Registry.update()
        Pkg.instantiate(;allow_autoprecomp=false)
        verify_viewer_assets(repo;selection=options[:selection])
        println("[Browser assets] Local scripts, styles and pinned bundle checksums verified; no CDN downloads are needed.")
        if options[:precompile]
            println("[$name] Precompiling packages (may take several minutes)...");flush(stdout)
            withenv("JULIA_NUM_PRECOMPILE_TASKS"=>ENV["JULIA_NUM_PRECOMPILE_TASKS"],
                    "JULIA_IMAGE_THREADS"=>ENV["JULIA_IMAGE_THREADS"],
                    "JFEM_SOL105_PRECOMPILE_WORKLOAD"=>ENV["JFEM_SOL105_PRECOMPILE_WORKLOAD"]) do
                Pkg.precompile()
            end
        end
        if options[:verify]
            println("[$name] Verifying module loading in the shared repository project...");flush(stdout)
            options[:selection]!=:wingfegen&&run(verification_command("JFEM",project))
            options[:selection]!=:solver&&run(verification_command("JFEM-Boxer",project))
        end
    end
    if options[:verify] && options[:selection]!=:wingfegen
        println("[PANDEATOR] Verifying server and browser routes without a warm-up solve...");flush(stdout)
        run(verification_command("PANDEATOR",repo))
        println("[Results viewer] Bundled browser assets verified; use APPS/JFEM_results_viewer/Windows, Linux or Mac.")
    end
    println("\nApplication dependency setup complete.")
    if options[:sysimage]!==nothing
        println("[Shared image] Checking startup acceleration; image creation uses available memory...");flush(stdout)
        image_preparer(repo, options)
    end
    println("Start JFEM-Boxer: choose the launcher in APPS/JFEM-Boxer/Windows, Linux or Mac.")
    println("Solve a deck: APPS/JFEM-solver/Windows/jfem.cmd model.bdf, or bash APPS/JFEM-solver/Linux/jfem model.bdf (Mac: use Mac/jfem).")
    println("Start PANDEATOR: choose the launcher in APPS/PANDEATOR_APP/Windows, Linux or Mac.")
    return 0
end
end

if abspath(PROGRAM_FILE)==abspath(@__FILE__)
    try
        exit(JFEMPackageSetup.main())
    catch failure
        println(stderr,"Package setup failed: ",sprint(showerror,failure))
        println(stderr,"Rerun setup after checking Julia version, network/proxy access and write permissions. See __Start here!__/README.md.")
        exit(1)
    end
end
