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
    Usage: julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl [options]

    Sets up JFEM CLI, FGen, PANDEATOR and the static results viewer. Installs the
    two recorded Julia environments; PANDEATOR shares JFEM's environment and the
    static viewer uses bundled browser assets. No manual package list is needed.

      --no-precompile       Skip explicit package precompilation.
      --no-verify           Skip module-load verification (download-only setup).
      --solver-only         Set up only the JFEM environment.
      --wingfegen-only      Set up only the FGen environment.
      --wingfegen-project=PATH  Use another FGen checkout.
      --offline             Use only the existing Julia package/artifact cache.
      --update-registry     Refresh registries before installing.
      --dry-run             Print the setup plan without installing anything.
      --sysimage[=PATH]      Also build an optional local solver/PANDEATOR image.
      --sysimage-threads=N|auto  Build-process threads (default: auto).
      --deck PATH           Representative sysimage deck; repeatable.
      --manifest PATH       JSON batch manifest for the sysimage workload.
      --flags VALUE         Workload FLAG=value,... overrides.
      -h, --help            Show this help.

    Setup may download packages/artifacts and take several minutes.
    --no-precompile alone does not prevent verification from compiling;
    combine it with --no-verify for download-only setup.
    A requested sysimage is still built with --no-precompile or --no-verify.
    Sysimages are machine-specific and optional; normal setup does not build one.
    """)
end

function parse_options(args)
    options=Dict{Symbol,Any}(:precompile=>true,:verify=>true,:offline=>false,
        :update_registry=>false,:selection=>:all,:dry_run=>false,:wingfegen=>nothing,
        :sysimage=>nothing,:sysimage_threads=>"auto",:workload=>String[])
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
        elseif arg in ("--solver-only","--wingfegen-only")
            options[:selection]==:all || error("Choose at most one project-selection option")
            options[:selection]=arg=="--solver-only" ? :solver : :wingfegen
        elseif startswith(arg,"--wingfegen-project=")
            path=chopprefix(arg,"--wingfegen-project=");isempty(path)&&error("FGen project path is empty")
            options[:wingfegen]=abspath(path)
        else;error("Unknown setup option: $arg (see --help)")
        end
        i+=1
    end
    options[:sysimage]===nothing && (!isempty(options[:workload]) || options[:sysimage_threads]!="auto") && error("Workload/build options require --sysimage")
    options[:sysimage]!==nothing && options[:selection]==:wingfegen && error("--sysimage requires the JFEM environment; omit --wingfegen-only")
    options
end

function setup_projects(repo,options)
    app=something(options[:wingfegen],joinpath(repo,"WingFEGen"))
    projects=Pair{String,String}[]
    options[:selection]!=:wingfegen && push!(projects,"JFEM"=>abspath(repo))
    options[:selection]!=:solver && push!(projects,"FGen"=>abspath(app))
    for (name,path) in projects
        isfile(joinpath(path,"Project.toml")) || error("$name Project.toml missing at $path. Extract the complete repository, or use --solver-only for a solver-only checkout.")
        JFEMEnvironmentSetup.check_runtime(path)
    end
    projects
end

function verification_command(name,project)
    script=if name=="JFEM"
        "using OpenJFEM; println(\"JFEM module verified.\")"
    elseif name=="FGen"
        "include("*repr(joinpath(project,"src","WingFEGen.jl"))*"); println(\"FGen module verified.\")"
    elseif name=="PANDEATOR"
        "include("*repr(joinpath(project,"POST","PANDEATOR_APP","panel_server.jl"))*"); "*
        "for route in (\"/\",\"/health\",\"/vendor/msgpack.min.js\",\"/vendor/babylon.js\",\"/jfem_binary.js\"); "*
        "handle(HTTP.Request(\"GET\",route)).status==200 || error(\"PANDEATOR route failed: \"*route); end; "*
        "println(\"PANDEATOR module and browser routes verified (no analysis run).\")"
    else
        error("Unknown application: $name")
    end
    `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$project -e $script`
end

function verify_viewer_assets(repo)
    for path in ("POST/JFEM_results_viewer/postv11.html","POST/jfem_binary.js","POST/PANDEATOR_APP/vendor/babylon.js")
        isfile(joinpath(repo,path)) || error("Static results viewer asset missing: $path. Extract the complete repository.")
    end
    return true
end

sysimage_path(repo,options)=options[:sysimage]===nothing ? nothing :
    isempty(options[:sysimage]) ? joinpath(repo,"sysimage","OpenJFEM_sysimage."*Libdl.dlext) : options[:sysimage]

function sysimage_command(repo,options)
    image=sysimage_path(repo,options);image===nothing && error("No sysimage requested")
    script=joinpath(repo,"JFEM_installation","julia_tools","deploy_fast.jl")
    command=`$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$repo --threads=$(options[:sysimage_threads]) $script --sysimage=$image $(options[:workload])`
    return options[:offline] ? addenv(command,"JULIA_PKG_OFFLINE"=>"true") : command
end

function build_sysimage(repo,options;runner=run,checker=JFEMSysimageProvenance.check_sysimage)
    runner(sysimage_command(repo,options))
    image=sysimage_path(repo,options)
    valid,reason=checker(repo,image)
    valid || error("Sysimage build did not produce an eligible image and receipt: $reason")
    println("Verified local sysimage: ",image)
    return image
end

function main(args=ARGS)
    options=parse_options(args);options===nothing && (usage();return 0)
    repo=repo_root();projects=setup_projects(repo,options)
    println("JFEM application setup with Julia ",VERSION)
    for (name,path) in projects;println("  ",name,": ",path);end
    options[:selection]!=:wingfegen && println("  Applications: JFEM CLI, PANDEATOR, static results viewer")
    options[:selection]!=:solver && println("  Application: FGen / WingFEGen")
    println("  Package precompile: ",options[:precompile],"; application verification: ",options[:verify])
    if options[:sysimage]!==nothing
        println("  Optional sysimage build: ",sysimage_path(repo,options))
        println("  Build command: ",sysimage_command(repo,options))
        isempty(options[:workload]) && println("  Workload: bundled tiny SOL101/103/105 decks plus PANDEATOR handlers")
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
            Pkg.precompile()
        end
        if options[:verify]
            println("[$name] Verifying module loading in its own project...");flush(stdout)
            run(verification_command(name,project))
        end
    end
    if options[:verify] && options[:selection]!=:wingfegen
        println("[PANDEATOR] Verifying server and browser routes without a warm-up solve...");flush(stdout)
        run(verification_command("PANDEATOR",repo))
        verify_viewer_assets(repo)
        println("[Static viewer] Bundled browser assets verified; open POST/JFEM_results_viewer/postv11.html.")
    end
    println("\nApplication dependency setup complete.")
    if options[:sysimage]!==nothing
        println("[Optional sysimage] Building locally; this can require substantial time and memory...");flush(stdout)
        try
            build_sysimage(repo,options)
        catch failure
            println(stderr,"Optional sysimage build failed: ",sprint(showerror,failure))
            println(stderr,"Dependencies are installed. Applications can run without this optional image. Retry setup --sysimage after resolving the build error.")
            return 2
        end
    end
    println("Start FGen: julia --startup-file=no --project=WingFEGen WingFEGen/run.jl")
    println("Solve a deck: jfem.cmd model.bdf (Windows) or bash jfem model.bdf (macOS/Linux).")
    println("Start PANDEATOR: POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd or bash POST/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh.")
    return 0
end
end

if abspath(PROGRAM_FILE)==abspath(@__FILE__)
    try
        exit(JFEMPackageSetup.main())
    catch failure
        println(stderr,"Package setup failed: ",sprint(showerror,failure))
        println(stderr,"Rerun setup after checking Julia version, network/proxy access and write permissions. See JFEM_installation/INSTALLATION.md.")
        exit(1)
    end
end
