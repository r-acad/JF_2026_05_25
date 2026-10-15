#!/usr/bin/env julia
module JFEMPackageSetup
include("environment_setup.jl")
using .JFEMEnvironmentSetup
using Pkg
using Libdl
include("sysimage_provenance.jl")

repo_root()=normpath(joinpath(@__DIR__,"..",".."))
function usage(io=stdout)
    print(io,"""
    Usage: julia --startup-file=no "__Start here!__/julia_tools/install_julia_packages.jl" [options]

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
    A requested sysimage is still built with --no-precompile or --no-verify.
    Normal setup builds one machine-specific image for JFEM and all applications.
    The current image is reused only when its source/runtime receipt matches.
    Download-only setup also requires --no-sysimage.
    """)
end

function parse_options(args)
    options=Dict{Symbol,Any}(:precompile=>true,:verify=>true,:offline=>false,
        :update_registry=>false,:selection=>:all,:dry_run=>false,:wingfegen=>nothing,
        :sysimage=>"",:sysimage_threads=>"2",:workload=>String[])
    i=1
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
            value=chopprefix(arg,"--sysimage-threads=")
            (value=="auto" || (tryparse(Int,value)!==nothing && parse(Int,value)>0)) || error("Sysimage threads must be auto or a positive integer")
            options[:sysimage_threads]=value
        elseif arg in ("--deck","--manifest","--flags") || any(prefix->startswith(arg,prefix), ("--deck=","--manifest=","--flags="))
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
    options[:sysimage]===nothing && (!isempty(options[:workload]) || options[:sysimage_threads]!="2") && error("Workload/build options require --sysimage")
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
        "for route in (\"/\",\"/health\",\"/vendor/msgpack.min.js\",\"/vendor/babylon.js\",\"/jfem_binary.js\"); "*
        "handle(HTTP.Request(\"GET\",route)).status==200 || error(\"PANDEATOR route failed: \"*route); end; "*
        "println(\"PANDEATOR module and browser routes verified (no analysis run).\")"
    else
        error("Unknown application: $name")
    end
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    `$executable --startup-file=no --history-file=no --project=$project -e $script`
end

function verify_viewer_assets(repo)
    for path in ("APPS/JFEM_results_viewer/postv11.html","APPS/jfem_binary.js","APPS/PANDEATOR_APP/vendor/babylon.js")
        isfile(joinpath(repo,path)) || error("Static results viewer asset missing: $path. Extract the complete repository.")
    end
    return true
end

sysimage_path(repo,options)=options[:sysimage]===nothing ? nothing :
    isempty(options[:sysimage]) ? joinpath(repo,"sysimage","OpenJFEM_sysimage."*Libdl.dlext) : options[:sysimage]

function sysimage_command(repo,options)
    image=sysimage_path(repo,options);image===nothing && error("No sysimage requested")
    script=joinpath(repo,"__Start here!__","julia_tools","deploy_fast.jl")
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    command=`$executable --startup-file=no --history-file=no --project=$repo --threads=$(options[:sysimage_threads]) $script --sysimage=$image $(options[:workload])`
    command=addenv(command,"JFEM_PRECOMPILE_BOXER"=>"1",
        "JULIA_NUM_PRECOMPILE_TASKS"=>get(ENV,"JULIA_NUM_PRECOMPILE_TASKS","2"),
        "JULIA_IMAGE_THREADS"=>get(ENV,"JULIA_IMAGE_THREADS",options[:sysimage_threads]=="auto" ? string(max(1,Sys.CPU_THREADS÷2)) : options[:sysimage_threads]))
    return options[:offline] ? addenv(command,"JULIA_PKG_OFFLINE"=>"true") : command
end

function build_sysimage(repo,options;runner=run,checker=JFEMSysimageProvenance.check_sysimage)
    image=sysimage_path(repo,options)
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

function main(args=ARGS)
    options=parse_options(args);options===nothing && (usage();return 0)
    repo=repo_root();projects=setup_projects(repo,options)
    println("JFEM application setup with Julia ",VERSION)
    for (name,path) in projects;println("  ",name,": ",path);end
    options[:selection]!=:wingfegen && println("  Applications: JFEM CLI, PANDEATOR, static results viewer")
    options[:selection]!=:solver && println("  Application: JFEM-Boxer")
    println("  Package precompile: ",options[:precompile],"; application verification: ",options[:verify])
    if options[:sysimage]!==nothing
        # Print arguments only: Cmd's full display also exposes its inherited environment.
        println("  Shared image build/reuse: ",Cmd(sysimage_command(repo,options).exec))
        isempty(options[:workload]) && println("  Workload: tiny SOL101/103/105/106, sensitivity, generation and application handlers")
    else
        println("  Sysimage: not requested (use --sysimage to build one)")
    end
    options[:dry_run] && return 0
    Pkg.offline(options[:offline])
    options[:offline] && println("Offline mode: only existing package/artifact caches can be used.")
    for (name,project) in projects
        println("\n[$name] Installing recorded dependencies...");flush(stdout)
        Pkg.activate(project)
        options[:update_registry] && !options[:offline] && Pkg.Registry.update()
        Pkg.instantiate(;allow_autoprecomp=false)
        if options[:precompile]
            println("[$name] Precompiling packages (may take several minutes)...");flush(stdout)
            withenv("JULIA_NUM_PRECOMPILE_TASKS"=>get(ENV,"JULIA_NUM_PRECOMPILE_TASKS","2"),
                    "JULIA_IMAGE_THREADS"=>get(ENV,"JULIA_IMAGE_THREADS","2")) do
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
        verify_viewer_assets(repo)
        println("[Static viewer] Bundled browser assets verified; open APPS/JFEM_results_viewer/postv11.html.")
    end
    println("\nApplication dependency setup complete.")
    if options[:sysimage]!==nothing
        println("[Shared image] Reusing the current image or rebuilding it; builds can take several minutes...");flush(stdout)
        try
            build_sysimage(repo,options)
        catch failure
            println(stderr,"Local image build failed: ",sprint(showerror,failure))
            println(stderr,"Dependencies are installed and normal package loading remains available. Rerun setup to retry, or use --no-sysimage to skip local image builds.")
            return 2
        end
    end
    println("Start JFEM-Boxer: JFEM-Boxer.cmd (Windows) or bash JFEM-Boxer.sh (macOS/Linux).")
    println("Solve a deck: jfem.cmd model.bdf (Windows) or bash jfem model.bdf (macOS/Linux).")
    println("Start PANDEATOR: APPS/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd or bash APPS/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh.")
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
