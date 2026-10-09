# Dedicated, directly owned worker: compile the native solver once for the study.
# Bootstrap reporting deliberately uses Base only. Dependency/import failures
# must produce the same structured progress/error files as numerical failures.
length(ARGS)==2||error("Expected a sensitivity job directory and JFEM repository")
const DIRECTORY,REPOSITORY=abspath.(ARGS)
function bootstrap_json(value)
    if value isa AbstractString
        io=IOBuffer();write(io,'"')
        for char in value
            if char=='"';write(io,"\\\"")
            elseif char=='\\';write(io,"\\\\")
            elseif char=='\n';write(io,"\\n")
            elseif char=='\r';write(io,"\\r")
            elseif char=='\t';write(io,"\\t")
            elseif Int(char)<32;write(io,"\\u"*lpad(string(Int(char);base=16),4,'0'))
            else;write(io,char)
            end
        end
        write(io,'"');return String(take!(io))
    elseif value isa AbstractDict
        return "{"*join((bootstrap_json(string(k))*":"*bootstrap_json(v) for (k,v) in value),",")*"}"
    elseif value isa AbstractVector
        return "["*join(bootstrap_json.(value),",")*"]"
    elseif value===nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Real&&isfinite(value)
        return string(value)
    end
    bootstrap_json(string(value))
end
function bootstrap_write(file,data)
    path=joinpath(DIRECTORY,file);temporary=path*".tmp"
    write(temporary,bootstrap_json(data));mv(temporary,path;force=true)
end
const WORKER_STARTED=time()
const LAST_PROGRESS=Ref{Any}(Dict{String,Any}())
const WORKER_TIMINGS=Dict{String,Any}()
function progress(data)
    state=Dict{String,Any}(data);state["worker_seconds"]=time()-WORKER_STARTED
    state["worker_timings"]=copy(WORKER_TIMINGS)
    LAST_PROGRESS[]=state;bootstrap_write("progress.json",state)
end
function measured_worker_stage(action,name)
    measurement=@timed action()
    WORKER_TIMINGS[name]=Dict("seconds"=>measurement.time,
        "compile_seconds"=>get(measurement,:compile_time,0.),
        "recompile_seconds"=>get(measurement,:recompile_time,0.),
        "gc_seconds"=>measurement.gctime)
    bootstrap_write("worker_timings.json",WORKER_TIMINGS)
    println("[Timing] ",name,": ",round(measurement.time;digits=3),
        " s (compilation ",round(get(measurement,:compile_time,0.);digits=3)," s)");flush(stdout)
    measurement.value
end
const WORKER_STAGE=Ref("bootstrap")
try
    mkpath(DIRECTORY)
    bootstrap_write("worker_runtime.json",Dict("julia_version"=>string(VERSION),"executable_directory"=>Sys.BINDIR,
        "project"=>Base.active_project()))
    println("Sensitivity worker: Julia ",VERSION,"; project ",Base.active_project());flush(stdout)
    progress(Dict("completed"=>0,"total"=>0,"phase"=>"bootstrap","detail"=>"Starting sensitivity worker with Julia $VERSION; loading WingFEGen dependencies"))
    if Sys.iswindows()
        try
            handle=ccall((:GetCurrentProcess,"kernel32"),Ptr{Cvoid},())
            ccall((:SetPriorityClass,"kernel32"),Int32,(Ptr{Cvoid},UInt32),handle,0x4000)
        catch
        end
    end
    @eval using LinearAlgebra
    LinearAlgebra.BLAS.set_num_threads(1)
    push!(LOAD_PATH,dirname(@__DIR__))
    WORKER_STAGE[]="generator dependencies"
    measured_worker_stage("generator_load") do
        include(joinpath(@__DIR__,"WingFEGen.jl"))
    end
    @eval const W=WingFEGen
    WORKER_STAGE[]="native solver"
    include(joinpath(@__DIR__,"native_solver_loader.jl"))
    progress(Dict("completed"=>0,"total"=>0,"phase"=>"bootstrap",
        "detail"=>"Loading the cached JFEM solver package; an installation or source change may require precompilation"))
    measured_worker_stage("native_package_load") do
        # The ordinary launcher uses this package too. Including the same source
        # in a new module bypasses its precompile cache on every sensitivity run.
        @eval const SensitivityNative=load_cached_jfem(REPOSITORY)
    end
    WORKER_STAGE[]="saved model"
    model=try Base.invokelatest(W.Serialization.deserialize,joinpath(DIRECTORY,"model.jls")) catch failure
        throw(ArgumentError("The saved sensitivity mesh cannot be read by Julia $VERSION. Recreate the FEM and start the study again. Details: "*sprint(showerror,failure)))
    end
    request=Base.invokelatest(W.JSON.parsefile,joinpath(DIRECTORY,"request.json"))
    WORKER_STAGE[]="adjoint analysis"
    function solve_baseline(path)
        progress(merge(LAST_PROGRESS[],Dict("detail"=>"Reading the baseline deck and building its native model; first-use compilation is measured separately")))
        parsed=measured_worker_stage("baseline_parse") do
            Base.invokelatest(SensitivityNative.bdf_to_model,path)
        end
        progress(merge(LAST_PROGRESS[],Dict("detail"=>"Assembling and solving the baseline; timings include any first-use compilation and physical result recovery")))
        forward=measured_worker_stage("baseline_analysis") do
            Base.invokelatest(SensitivityNative.solve_model,parsed)
        end
        WORKER_TIMINGS["native_analysis"]=get(forward,"timings",Dict())
        bootstrap_write("worker_timings.json",WORKER_TIMINGS)
        forward
    end
    result=Base.invokelatest(W.compute_sensitivity,model,request,DIRECTORY;native=SensitivityNative,solve=solve_baseline,progress)
    result["worker_timings"]=copy(WORKER_TIMINGS)
    result["worker_seconds"]=time()-WORKER_STARTED
    Base.invokelatest(W.sensitivity_json_write,joinpath(DIRECTORY,"result.json"),result)
catch failure
    detail=sprint(showerror,failure,catch_backtrace())
    stage=WORKER_STAGE[]
    message="Sensitivity worker failed while loading $stage (Julia $VERSION): "*sprint(showerror,failure)
    stage=="adjoint analysis"&&(message=sprint(showerror,failure))
    bootstrap_write("error.json",Dict("message"=>message,"detail"=>detail,"stage"=>stage,"julia_version"=>string(VERSION)))
    # Keep completed baseline/adjoint/operator counts visible if a later stage
    # fails. Resetting everything to zero misrepresents work already completed.
    progress(merge(Dict{String,Any}("completed"=>0,"total"=>0),LAST_PROGRESS[],
        Dict("phase"=>"failed","detail"=>message)))
    println(stderr,detail)
    exit(1)
end
