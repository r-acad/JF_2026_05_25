# Dependency-free startup/discovery shared by the launchers and the web app.
# TOML is a Julia standard library; no Pkg environment must be installed yet.
module WingFEGenBootstrap
using TOML

function solver_candidates(root)
    candidates=String[];folder=abspath(root)
    while true
        # Test the ancestor itself: a checkout may have any directory name.
        append!(candidates,(folder,joinpath(folder,"JFEM"),
            joinpath(folder,"01_PUBLIC_PROJECT_REPOSITORY","JFEM")))
        parent=dirname(folder);parent==folder&&break;folder=parent
    end
    unique(candidates)
end

function locate_solver(root;hint=get(ENV,"WINGFEGEN_JFEM",""))
    canonical=nothing
    for path in solver_candidates(root)
        if isfile(joinpath(path,"src","OpenJFEM.jl"))
            canonical=path;break
        end
    end
    if !isempty(strip(hint))
        expanded=expanduser(strip(hint));path=isabspath(expanded) ? expanded : joinpath(root,expanded)
        path=abspath(isfile(path) ? dirname(path) : path)
        matches=canonical!==nothing&&isdir(path)&&realpath(path)==realpath(canonical)
        if !matches
            @warn "Ignoring foreign legacy WINGFEGEN_JFEM: all applications use the enclosing JFEM repository" canonical maxlog=1
        end
    end
    canonical
end

function runtime_candidates(;current=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia"),environment=ENV,user_home=homedir())
    candidates=String[];configured=strip(get(environment,"WINGFEGEN_JULIA",""))
    if !isempty(configured)
        resolved=Sys.which(configured);push!(candidates,resolved===nothing ? expanduser(configured) : resolved)
    end
    push!(candidates,current)
    # Read installed version directories, not the juliaup alias: a missing
    # default channel must not initiate an implicit runtime download.
    depots=unique([get(environment,"JULIAUP_DEPOT_PATH",joinpath(user_home,".julia")),joinpath(user_home,".julia")])
    for depot in depots
        versions=joinpath(depot,"juliaup")
        isdir(versions)||continue
        for name in sort!(readdir(versions);rev=true)
            startswith(name,"julia-")&&push!(candidates,joinpath(versions,name,"bin",Sys.iswindows() ? "julia.exe" : "julia"))
        end
    end
    from_path=Sys.which("julia");from_path===nothing||push!(candidates,from_path)
    if Sys.iswindows()
        programs=joinpath(user_home,"AppData","Local","Programs")
        if isdir(programs)
            for name in sort!(readdir(programs);rev=true)
                startswith(lowercase(name),"julia-")&&push!(candidates,joinpath(programs,name,"bin","julia.exe"))
            end
        end
    else
        append!(candidates,(joinpath(user_home,".juliaup","bin","julia"),"/usr/local/bin/julia","/opt/homebrew/bin/julia"))
        if Sys.isapple()&&isdir("/Applications")
            for name in readdir("/Applications")
                startswith(name,"Julia-")&&endswith(name,".app")&&push!(candidates,joinpath("/Applications",name,"Contents","Resources","julia","bin","julia"))
            end
        end
    end
    unique(candidates)
end

function probe_runtime(executable)
    isfile(executable)||return nothing
    script="print(\"WINGFEGEN_RUNTIME\\t\", VERSION, \"\\t\", joinpath(Sys.BINDIR, Sys.iswindows() ? \"julia.exe\" : \"julia\"))"
    command=`$executable --startup-file=no --history-file=no -e $script`
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    try
        fields=split(read(pipeline(command;stderr=devnull),String),'\t')
        length(fields)==3&&fields[1]=="WINGFEGEN_RUNTIME"||return nothing
        (version=VersionNumber(fields[2]),executable=strip(fields[3]))
    catch
        nothing
    end
end

function requirements(root;repo=locate_solver(root))
    versions=VersionNumber[]
    for project in (repo===nothing ? root : repo,)
        project===nothing&&continue
        file=joinpath(project,"Manifest.toml");isfile(file)||continue
        value=get(TOML.parsefile(file),"julia_version",nothing)
        value===nothing||push!(versions,VersionNumber(value))
    end
    pairs=unique([(v.major,v.minor) for v in versions])
    isempty(pairs)&&push!(pairs,(1,12))
    length(pairs)==1||error("The repository manifest must record one Julia minor version")
    only(pairs)
end

function restart_if_needed(root,entry,args=ARGS;use_image=true)
    major,minor=requirements(root)
    if VERSION.major==major&&VERSION.minor==minor
        use_image&&restart_with_image(root,entry,args)
        return nothing
    end
    for candidate in runtime_candidates()
        found=probe_runtime(candidate);found===nothing&&continue
        found.version.major==major&&found.version.minor==minor||continue
        println("JFEM-Boxer: using Julia $(found.version) for the recorded dependencies.");flush(stdout)
        command=Cmd(vcat([found.executable,"--startup-file=no","--threads=auto","--project="*abspath(something(locate_solver(root),root)),abspath(entry)],String.(args)))
        exit(run(ignorestatus(command)).exitcode)
    end
    error("JFEM-Boxer needs Julia $major.$minor.x for this checkout. Run `juliaup add $major.$minor` to install the latest matching patch, or set WINGFEGEN_JULIA to its executable. Then run setup.cmd, setup.sh or setup.command at the repository root. No input files were changed.")
end

# Include before runtime functions are called, so Julia's binding world age is
# respected both during ordinary loading and in an application sysimage.
let repo=locate_solver(dirname(@__DIR__))
    if repo!==nothing
        helper=joinpath(repo,"utils","julia_tools","runtime_images.jl")
        isfile(helper)&&include(helper)
    end
end

function restart_with_image(root,entry,args)
    repo=locate_solver(root);repo===nothing&&return nothing
    isdefined(@__MODULE__,:JFEMRuntimeImages)||return nothing
    selected,reason=JFEMRuntimeImages.selected_image(repo;kind="boxer")
    loaded=unsafe_string(Base.JLOptions().image_file)
    baked=Base.PkgId(Base.UUID("88b3fba0-1c22-4de6-bb97-e868cbde42d1"),"WingFEGen") in keys(Base.loaded_modules)
    selected!==nothing&&abspath(loaded)==abspath(selected)&&return nothing
    if selected===nothing&&!baked
        reason in ("image_missing","disabled")||println("JFEM-Boxer: local image skipped ($reason); run setup to refresh it.")
        return nothing
    end
    println(selected===nothing ? "JFEM-Boxer: restarting without stale application image ($reason)." : "JFEM-Boxer: using verified shared sysimage.")
    command=Cmd(vcat([joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")],selected===nothing ? String[] : ["--sysimage="*selected],
        ["--startup-file=no","--threads=auto","--project="*abspath(something(locate_solver(root),root)),abspath(entry)],String.(args)))
    exit(run(ignorestatus(command)).exitcode)
end
end
