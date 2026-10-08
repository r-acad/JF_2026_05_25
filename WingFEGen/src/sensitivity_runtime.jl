# The GUI may already be running under an older Julia. Sensitivity loads both
# project environments in a fresh process and must honor their manifest runtime.
isdefined(@__MODULE__,:WingFEGenBootstrap)||include("runtime_bootstrap.jl")
function sensitivity_runtime_requirements(repo;generator=dirname(@__DIR__))
    requirements=Dict{String,VersionNumber}()
    for project in unique([abspath(generator),abspath(repo)])
        manifest=joinpath(project,"Manifest.toml")
        isfile(manifest)||continue
        value=get(TOML.parsefile(manifest),"julia_version",nothing)
        value===nothing|| (requirements[manifest]=VersionNumber(value))
    end
    requirements
end

sensitivity_runtime_compatible(version,requirements)=all(v->version.major==v.major&&version.minor==v.minor,values(requirements))

function sensitivity_runtime_candidates(;current=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia"),
                                         environment=ENV,user_home=homedir())
    candidates=WingFEGenBootstrap.runtime_candidates(;current,environment,user_home)
    configured=strip(get(environment,"WINGFEGEN_JULIA",""))
    isempty(configured)||push!(candidates,configured)
    push!(candidates,current)
    # Prefer known installed Juliaup binaries to its application alias: querying
    # a missing default channel could otherwise initiate an unrelated download.
    depot=get(environment,"JULIAUP_DEPOT_PATH",joinpath(user_home,".julia"))
    juliaup=joinpath(depot,"juliaup");config=joinpath(juliaup,"juliaup.json")
    if isfile(config)
        try
            versions=get(JSON.parsefile(config),"InstalledVersions",Dict())
            for key in sort!(collect(keys(versions));rev=true)
                path=get(versions[key],"Path","");isempty(path)&&continue
                root=isabspath(path) ? path : normpath(joinpath(juliaup,path))
                push!(candidates,joinpath(root,"bin",Sys.iswindows() ? "julia.exe" : "julia"))
            end
        catch
            # Malformed Juliaup metadata must not hide a usable PATH runtime.
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
    end
    unique(candidates)
end

function sensitivity_probe_runtime(executable)
    resolved=Sys.which(executable)
    resolved===nothing||(executable=resolved)
    isfile(executable)||return nothing
    script="print(\"WINGFEGEN_RUNTIME\\t\", VERSION, \"\\t\", joinpath(Sys.BINDIR, Sys.iswindows() ? \"julia.exe\" : \"julia\"))"
    command=`$executable --startup-file=no --history-file=no -e $script`
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    try
        output=read(pipeline(command;stderr=devnull),String)
        fields=split(output,'\t')
        length(fields)==3&&fields[1]=="WINGFEGEN_RUNTIME"||return nothing
        (version=VersionNumber(fields[2]),executable=strip(fields[3]))
    catch
        nothing
    end
end

function sensitivity_worker_runtime(repo;generator=dirname(@__DIR__),requirements=sensitivity_runtime_requirements(repo;generator),
                                    candidates=sensitivity_runtime_candidates(),probe=sensitivity_probe_runtime,
                                    parent_version=VERSION)
    pairs=unique([(v.major,v.minor) for v in values(requirements)])
    length(pairs)<=1||throw(ArgumentError("The generator and JFEM manifests require different Julia minor versions; use matching project environments before starting sensitivity"))
    attempted=String[]
    for executable in candidates
        found=probe(executable);found===nothing&&continue
        push!(attempted,"$(found.version) ($(found.executable))")
        sensitivity_runtime_compatible(found.version,requirements)||continue
        metadata=Dict("parent_julia_version"=>string(parent_version),"worker_julia_version"=>string(found.version),
            "worker_executable"=>found.executable,"manifest_versions"=>Dict(k=>string(v) for (k,v) in requirements),
            "runtime_switched"=>found.version.major!=parent_version.major||found.version.minor!=parent_version.minor)
        return (command=Cmd([found.executable]),metadata=metadata)
    end
    expected=isempty(pairs) ? "a working Julia runtime" : "Julia $(pairs[1][1]).$(pairs[1][2]).x"
    detail=isempty(attempted) ? "No installed Julia executable could be queried." : "Found: "*join(attempted,"; ")
    throw(ArgumentError("Sensitivity needs $expected for the recorded project dependencies. $detail Set WINGFEGEN_JULIA to a compatible installed julia executable, or install the matching runtime. The study has not been changed."))
end
