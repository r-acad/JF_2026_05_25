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
    if !isempty(strip(hint))
        expanded=expanduser(strip(hint));path=isabspath(expanded) ? expanded : joinpath(root,expanded)
        path=abspath(isfile(path) ? dirname(path) : path)
        isfile(joinpath(path,"src","OpenJFEM.jl"))||error("JFEM repository not found: $path")
        return path
    end
    for path in solver_candidates(root)
        isfile(joinpath(path,"src","OpenJFEM.jl"))&&return path
    end
    nothing
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
    for project in (root,repo)
        project===nothing&&continue
        file=joinpath(project,"Manifest.toml");isfile(file)||continue
        value=get(TOML.parsefile(file),"julia_version",nothing)
        value===nothing||push!(versions,VersionNumber(value))
    end
    pairs=unique([(v.major,v.minor) for v in versions])
    isempty(pairs)&&push!(pairs,(1,12))
    length(pairs)==1||error("WingFEGen and JFEM manifests require different Julia minor versions; use matching project environments")
    only(pairs)
end

function restart_if_needed(root,entry,args=ARGS)
    major,minor=requirements(root)
    VERSION.major==major&&VERSION.minor==minor&&return nothing
    for candidate in runtime_candidates()
        found=probe_runtime(candidate);found===nothing&&continue
        found.version.major==major&&found.version.minor==minor||continue
        println("WingFEGen: using Julia $(found.version) for the recorded dependencies.");flush(stdout)
        command=Cmd(vcat([found.executable,"--startup-file=no","--project="*abspath(root),abspath(entry)],String.(args)))
        exit(run(ignorestatus(command)).exitcode)
    end
    error("WingFEGen needs Julia $major.$minor.x. Install that runtime or set WINGFEGEN_JULIA to its executable. No input files were changed.")
end
end
