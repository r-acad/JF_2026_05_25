# Persistent FE execution service. One JSONL request at a time; stdout carries
# protocol replies only, while every analysis owns its complete on-disk log.
length(ARGS)==1 || error("Expected the enclosing JFEM repository")
const WORKER_REPO=realpath(ARGS[1])
redirect_stdout(stderr) do
    include(joinpath(WORKER_REPO,"utils","julia_tools","run_manifest.jl"))
    include(joinpath(WORKER_REPO,"utils","julia_tools","jfem_output_formats.jl"))
    @eval using OpenJFEM, LinearAlgebra
end
realpath(Base.active_project())==realpath(joinpath(WORKER_REPO,"Project.toml")) || error("Incorrect solver worker project")
realpath(pathof(OpenJFEM))==realpath(joinpath(WORKER_REPO,"src","OpenJFEM.jl")) || error("Incorrect solver package")

function worker_physical_cores()
    try
        if Sys.iswindows()
            command=`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum"`
            n=tryparse(Int,strip(read(Cmd(command;windows_hide=true),String)))
            n!==nothing && n>0 && return n
        elseif Sys.isapple()
            n=tryparse(Int,strip(read(`sysctl -n hw.physicalcpu`,String)))
            n!==nothing && n>0 && return n
        elseif Sys.islinux()
            pairs=Set{Tuple{String,String}}();physical="";core=""
            for line in eachline("/proc/cpuinfo")
                startswith(line,"physical id") && (physical=strip(split(line,':')[end]))
                startswith(line,"core id") && (core=strip(split(line,':')[end]))
                if isempty(strip(line)) && !isempty(physical) && !isempty(core)
                    push!(pairs,(physical,core));physical="";core=""
                end
            end
            isempty(pairs) || return length(pairs)
        end
    catch
    end
    Sys.CPU_THREADS
end
LinearAlgebra.BLAS.set_num_threads(clamp(worker_physical_cores(),1,Sys.CPU_THREADS))
if Sys.iswindows()
    # Match the old per-run launcher: GUI work can preempt the solver.
    handle=ccall((:GetCurrentProcess,"kernel32"),Ptr{Cvoid},())
    ccall((:SetPriorityClass,"kernel32"),Cint,(Ptr{Cvoid},UInt32),handle,0x00004000)
end
const WORKER_SESSION=string(Dates.format(Dates.now(Dates.UTC),dateformat"yyyymmddTHHMMSS"),"-pid",getpid())
const WORKER_RUNTIME=Dict{String,Any}(
    "pid"=>getpid(),"session_id"=>WORKER_SESSION,"project"=>Base.active_project(),
    "manifest_sha256"=>bytes2hex(SHA.sha256(read(joinpath(WORKER_REPO,"Manifest.toml")))),
    "image"=>unsafe_string(Base.JLOptions().image_file),"julia_version"=>string(VERSION),
    "threads"=>Threads.nthreads(),"blas_threads"=>LinearAlgebra.BLAS.get_num_threads())

function worker_reply(data)
    println(stdout,"[JFEM_WORKER] ",JSON.json(data));flush(stdout)
end

function worker_run(request,index)
    bdf=abspath(String(request["bdf"]));outdir=abspath(String(request["outdir"]))
    logpath=joinpath(outdir,"solver_stdout.log")
    isfile(bdf) || error("Deck not found: $bdf")
    isdir(outdir) || error("Prepared output directory not found: $outdir")
    formats=_parse_format_letters(String(request["formats"]))
    requested=get(request,"environment",Dict())
    requested isa AbstractDict || error("Worker environment must be an object")
    all(key->startswith(String(key),"JFEM_"),keys(requested)) || error("Only JFEM run flags may be supplied")
    previous=Dict(key=>value for (key,value) in ENV if startswith(key,"JFEM_"))
    runtime=merge(WORKER_RUNTIME,Dict("request_id"=>request["id"],"request_index"=>index,
        "bdf"=>bdf,"output_dir"=>outdir,"started_unix"=>time()))
    code=0;message=""
    try
        # Fresh per-request flags reproduce a new CLI process. Restore all JFEM
        # keys afterward, including keys changed internally by a failed solve.
        for key in collect(keys(ENV));startswith(key,"JFEM_") && delete!(ENV,key);end
        for (key,value) in requested;ENV[String(key)]=String(value);end
        ENV["JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES"]="true"
        ENV["JFEM_SUPPRESS_THREAD_HINT"]="1"
        ENV["JFEM_EXPORT_BINARY"]=formats[:export_jfem_binary] ? "true" : "false"
        open(joinpath(outdir,"solver_worker.json"),"w") do io;JSON.print(io,runtime,2);end
        open(logpath,"w") do log
            redirect_stdout(log) do
                redirect_stderr(log) do
                    try
                        println("[Worker] Session $WORKER_SESSION, request $index; independent deck and output directory")
                        write_run_manifest(outdir;repo_root=WORKER_REPO,bdf_path=bdf,
                            script_path=@__FILE__,args=[JSON.json(request)],
                            applied_flags=_manifest_jfem_environment(),
                            extra=Dict{String,Any}("persistent_worker"=>true,"worker_pid"=>getpid(),
                                "worker_session_id"=>WORKER_SESSION,"worker_request_index"=>index,
                                "output_formats"=>request["formats"]))
                        OpenJFEM.main(bdf;output_dir=outdir,formats...)
                    catch error
                        code=1;message=sprint(showerror,error)
                        showerror(stderr,error,catch_backtrace());println(stderr)
                    finally
                        flush(stdout);flush(stderr)
                    end
                end
            end
        end
    finally
        for key in collect(keys(ENV));startswith(key,"JFEM_") && delete!(ENV,key);end
        merge!(ENV,previous)
    end
    runtime["finished_unix"]=time();runtime["exit_code"]=code
    open(joinpath(outdir,"solver_worker.json"),"w") do io;JSON.print(io,runtime,2);end
    Dict("id"=>request["id"],"status"=>code==0 ? "done" : "failed",
        "exit_code"=>code,"message"=>message,"runtime"=>runtime)
end

worker_reply(Dict("status"=>"ready","runtime"=>WORKER_RUNTIME))
request_index=0
for line in eachline(stdin)
    isempty(strip(line)) && continue
    id=nothing
    try
        request=JSON.parse(line);request isa AbstractDict || error("Expected a JSON object")
        id=get(request,"id",nothing)
        command=get(request,"command","")
        command=="quit" && break
        command=="run" || error("Unknown solver worker command: $command")
        global request_index+=1
        reply=worker_run(request,request_index)
        # Drop per-case model/result storage while retaining compiled methods.
        GC.gc(false)
        worker_reply(reply)
    catch error
        worker_reply(Dict("id"=>id,"status"=>"failed","exit_code"=>1,
            "message"=>sprint(showerror,error),"runtime"=>WORKER_RUNTIME))
    end
end
