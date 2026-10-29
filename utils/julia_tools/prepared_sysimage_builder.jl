module JFEMPreparedSysimageBuilder
using Pkg, TOML, Libdl
include("environment_setup.jl")
include("prepared_sysimage_environment.jl")
include("sysimage_provenance.jl")
const Environment = JFEMPreparedSysimageEnvironment
const Provenance = JFEMSysimageProvenance

function usage(io=stdout)
    println(io, """
    Build a shared JFEM image from existing packages, without running setup.

      julia --startup-file=no --threads=2 utils/julia_tools/build_prepared_sysimage.jl [options]

    Set JFEM_PACKAGE_ENV to the existing prepared Project/Manifest directory and
    JULIA_DEPOT_PATH to its hydrated depot before starting Julia.

      --check-only         Check cached packages, native artifacts and compiler.
      --sysimage=PATH      Image destination (default: sysimage/OpenJFEM_sysimage.$(Libdl.dlext)).
      --deck PATH          Representative input deck; repeatable.
      --manifest PATH      JSON batch manifest of representative decks.
      --flags FLAGS        Workload flags, as in deploy_fast.jl.
      --help               Show this help.

    The default workload covers the solver, PANDEATOR and Boxer. Build metadata
    and diagnostics stay under sysimage/builds/. Original Project/Manifest files
    are preserved. Missing caches cause an error before compilation. PackageCompiler
    performs its normal cache checks/precompilation in the derived environment.
    """)
end

function options(args, root)
    check_only=false; help=false
    image=joinpath(root,"sysimage","OpenJFEM_sysimage."*Libdl.dlext)
    workload=String[]; i=1
    while i<=length(args)
        arg=args[i]
        if arg=="--check-only"
            check_only=true
        elseif arg in ("--help","-h","help")
            help=true
        elseif startswith(arg,"--sysimage=")
            value=chopprefix(arg,"--sysimage=");isempty(value)&&error("--sysimage requires a file path")
            image=abspath(expanduser(value))
        elseif arg in ("--deck","--manifest","--flags")
            i<length(args)||error("$arg requires a value")
            append!(workload,[arg,args[i+1]]);i+=1
        elseif any(prefix->startswith(arg,prefix),("--deck=","--manifest=","--flags="))
            push!(workload,arg)
        else
            error("Unsupported option: $arg. This build command does not install packages; use --help.")
        end
        i+=1
    end
    isdir(image)&&error("Image destination is a directory: $image")
    lowercase(splitext(image)[2])=="."*Libdl.dlext||error("This platform requires an image ending in .$(Libdl.dlext)")
    (check_only=check_only, help=help, image=abspath(image), workload=workload)
end

function offline!()
    ENV["JULIA_PKG_OFFLINE"]="true"
    ENV["JULIA_PKG_SERVER"]=""
    ENV["JULIA_PKG_PRECOMPILE_AUTO"]="0"
    ENV["JFEM_AUTO_INSTALL"]="0"
    ENV["JFEM_NO_SYSIMAGE"]="1"
    ENV["JFEM_SYSIMAGE"]=""
    get!(ENV,"JULIA_NUM_PRECOMPILE_TASKS","2")
    get!(ENV,"JULIA_IMAGE_THREADS","2")
    Pkg.offline(true)
end

function bare_process!()
    # Building on top of a previously baked solver could retain stale code.
    for id in keys(Base.loaded_modules)
        id.name in ("OpenJFEM","WingFEGen") && error("Start this builder with bare Julia, without -J/--sysimage; $(id.name) is already loaded.")
    end
end

function compiler_check(packagecompiler)
    # PackageCompiler checks JULIA_CC and the native GCC/Clang toolchain.
    # Its Windows compiler artifact has already passed cache_preflight.
    command=Base.invokelatest(()->packagecompiler.get_compiler_cmd())
    resolved=Sys.which(first(command.exec))
    resolved===nothing&&error("C compiler is unavailable: $(first(command.exec)). Select an existing compiler with JULIA_CC.")
    command
end

function smoke_image(root, environment, image; packages=["OpenJFEM","WingFEGen"])
    checker=joinpath(@__DIR__,"environment_setup.jl")
    imports=join(["Base.require(Main, Symbol("*repr(name)*"))" for name in packages],"\n")
    code="include("*repr(checker)*")\nJFEMEnvironmentSetup.ensure_environment("*repr(root)*")\n"*
        imports*"\nprintln(\"JFEM_PREPARED_IMAGE_OK\")\n"
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    command=`$executable --startup-file=no --history-file=no --threads=1 --project=$environment --sysimage=$image -e $code`
    output=read(command,String)
    occursin("JFEM_PREPARED_IMAGE_OK",output)||error("Fresh-process image validation failed")
    nothing
end

function atomic_replace(source, destination)
    temp,io=mktemp(dirname(destination);cleanup=false);close(io)
    try
        cp(source,temp;force=true)
        # Same-directory OS rename replaces the complete file atomically.
        # Unlike mv(force=true), this does not delete the destination on failure.
        Base.Filesystem.rename(temp,destination)
    finally
        isfile(temp)&&rm(temp)
    end
end

"""Keep an earlier image available if compilation or validation fails."""
function publish_image(candidate, destination; validator=()->nothing)
    destination=abspath(destination);candidate=abspath(candidate)
    candidate==destination&&error("Build into a separate candidate file before publication")
    candidate_receipt=Provenance.sidecar(candidate)
    isfile(candidate)&&isfile(candidate_receipt)||error("Candidate image/receipt is incomplete")
    mkpath(dirname(destination))
    backup=joinpath(dirname(candidate),"previous-image."*Libdl.dlext)
    receipt=Provenance.sidecar(destination);backup_receipt=Provenance.sidecar(backup)
    had_image=isfile(destination);had_receipt=isfile(receipt)
    had_image&&cp(destination,backup;force=true)
    had_receipt&&cp(receipt,backup_receipt;force=true)
    try
        atomic_replace(candidate,destination)
        atomic_replace(candidate_receipt,receipt)
        validator()
    catch
        # Restore only these explicitly named files; retain build diagnostics.
        had_image ? atomic_replace(backup,destination) : (isfile(destination)&&rm(destination))
        had_receipt ? atomic_replace(backup_receipt,receipt) : (isfile(receipt)&&rm(receipt))
        rethrow()
    end
    destination
end

function build(root, args=String[])
    root=realpath(root);opts=options(args,root)
    opts.help&&(usage();return nothing)
    bare_process!();offline!()
    environment,_=JFEMEnvironmentSetup.package_environment(root)
    JFEMEnvironmentSetup.check_runtime(environment)
    before=Provenance.environment_identity(root;environment)
    inputs=Provenance.input_hashes(root)
    # Persist the exact derived records for diagnosis; neither original graph is edited.
    builds=joinpath(root,"sysimage","builds");mkpath(builds)
    work=mktempdir(builds;prefix="prepared_",cleanup=false)
    println("JFEM prepared sysimage: ",opts.check_only ? "checking prerequisites" : "building")
    println("  Source: ",root,"\n  Packages: ",environment,"\n  Build records: ",work);flush(stdout)
    try
        derived=Environment.prepare_environment(root,environment,joinpath(work,"environment");
            preferences=before["preferences"],preference_packages=before["preference_packages"])
        derived_inputs=Dict(name=>Provenance.digest(joinpath(derived,name)) for name in readdir(derived) if endswith(name,".toml"))
        println("Checking existing package sources and native artifacts (including lazy artifacts)...");flush(stdout)
        Environment.cache_preflight(derived)
        Pkg.activate(derived;io=devnull)
        empty!(LOAD_PATH);append!(LOAD_PATH,[derived,"@stdlib"])
        ENV["JULIA_LOAD_PATH"]=join(LOAD_PATH,Sys.iswindows() ? ';' : ':')
        compiler=Base.require(Base.PkgId(Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"),"PackageCompiler"))
        println("Compiler: ",join(compiler_check(compiler).exec," "))
        # Validate the exact production image package list even in --check-only.
        # Finding a transitive package is insufficient for create_sysimage:
        # PackageCompiler also requires it in the build project's direct deps.
        deployment=Module(:PreparedImageWorkloads)
        Core.eval(deployment,:(include(path)=Base.include(@__MODULE__,path)))
        Base.include(deployment,joinpath(@__DIR__,"deploy_fast.jl"))
        packages=Base.invokelatest(()->deployment.JFEMSharedPrecompileWorkloads.required_packages())
        Base.invokelatest(()->compiler.check_packages_in_project(compiler.create_pkg_context(derived),packages))
        println("Shared image package contract verified: ",join(string.(packages),", "))
        # Recheck before building in case selectors or imports changed inputs.
        before==Provenance.environment_identity(root;environment)||error("Prepared environment changed during prerequisite checks")
        inputs==Provenance.input_hashes(root)||error("Repository inputs changed during prerequisite checks")
        if opts.check_only
            println("Prerequisite checks passed. No sysimage was built.")
            return nothing
        end
        decks,flags,_,_=Base.invokelatest(()->deployment._parse_args(opts.workload))
        isempty(decks)&&error("No representative workload decks found")
        script=joinpath(work,"precompile_execution.jl")
        Base.invokelatest(()->deployment._write_sysimage_precompile_script(script,decks,flags))
        workloads=Provenance.workload_hashes(decks,flags)
        candidate=joinpath(work,"OpenJFEM_candidate."*Libdl.dlext)
        println("Compiling shared solver/application image; this can take several minutes...");flush(stdout)
        Base.invokelatest(()->compiler.create_sysimage(packages;
            project=derived,sysimage_path=candidate,precompile_execution_file=script))
        all(isfile(joinpath(derived,name))&&Provenance.digest(joinpath(derived,name))==hash for (name,hash) in derived_inputs)||
            error("PackageCompiler changed the derived package records; candidate image will not replace the current image")
        println("Checking the image in a fresh Julia process...");flush(stdout)
        smoke_image(root,environment,candidate)
        Provenance.write_sidecar(root,candidate,inputs,workloads;environment,environment_before=before)
        publish_image(candidate,opts.image;validator=()->begin
            valid,reason=Provenance.check_sysimage(root,opts.image;environment)
            valid||error("Published image verification failed: $reason")
        end)
        println("Verified shared image: ",opts.image)
        println("Receipt: ",Provenance.sidecar(opts.image))
        println("Run JFEM_INFO to confirm automatic selection, then use JFEM normally.")
        opts.image
    catch failure
        open(joinpath(work,"failure.txt"),"w") do io
            showerror(io,failure,catch_backtrace());println(io)
        end
        println(stderr,"Build stopped. Diagnostics retained in ",work,". Existing source-mode launch remains available.")
        rethrow()
    end
end
end
