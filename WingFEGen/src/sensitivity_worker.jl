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
worker_stage_category(phase)=phase in ("forward","baseline_analysis","adjoint","operators","analytic_derivatives") ?
    "numerical" : phase in ("baseline_export","result_export") ? "export" : "preparation"
function progress(data)
    state=Dict{String,Any}(data);state["worker_seconds"]=time()-WORKER_STARTED
    state["worker_timings"]=copy(WORKER_TIMINGS)
    phase=String(get(state,"phase","bootstrap"))
    state["stage_category"]=worker_stage_category(phase)
    state["stage_state"]=phase=="complete" ? "completed" : phase=="failed" ? "failed" : "started"
    state["compilation_live"]="not_separable"
    state["timing_scope"]="worker_timings separates completed measured compilation; timings_seconds is inclusive wall time and may include compilation. Native baseline stages are nested within baseline_analysis, not additional time."
    LAST_PROGRESS[]=state;bootstrap_write("progress.json",state)
end
function store_worker_stage(name,metrics)
    wall=metrics["wall_seconds"];compiled=metrics["compilation_seconds"]
    WORKER_TIMINGS[name]=merge(Dict{String,Any}(metrics),Dict(
        "seconds"=>wall,"compile_seconds"=>compiled,
        "recompile_seconds"=>metrics["recompilation_seconds"],
        "category"=>worker_stage_category(name),"label"=>replace(name,'_'=>' ')))
    bootstrap_write("worker_timings.json",WORKER_TIMINGS)
    println("[Timing] ",name,": ",round(wall;digits=3),
        " s (measured compilation ",round(compiled;digits=3)," s)");flush(stdout)
end
function measured_worker_stage(action,name)
    measurement=@timed Base.invokelatest(action)
    wall=measurement.time;compiled=get(measurement,:compile_time,0.)
    store_worker_stage(name,Dict("wall_seconds"=>wall,"compilation_seconds"=>compiled,
        "recompilation_seconds"=>get(measurement,:recompile_time,0.),
        "execution_seconds"=>0<=compiled<=wall ? wall-compiled : nothing,
        "gc_seconds"=>measurement.gctime))
    measurement.value
end
function measured_native_baseline(action,native)
    phases=Dict{String,Any}()
    forward=Base.invokelatest(native._pipeline_measure!,action,phases,"solve")
    payload=Base.invokelatest(native._pipeline_timing_payload,phases)
    WORKER_TIMINGS["native_analysis"]=merge(Dict{String,Any}(get(forward,"timings",Dict())),payload)
    store_worker_stage("baseline_analysis",Dict(key=>value for (key,value) in phases["solve"] if key!="stages"))
    forward
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
        progress(merge(LAST_PROGRESS[],Dict("phase"=>"baseline_parse","detail"=>"Reading the baseline deck and building its native model; first-use compilation is measured separately")))
        parsed=measured_worker_stage("baseline_parse") do
            Base.invokelatest(SensitivityNative.bdf_to_model,path)
        end
        progress(merge(LAST_PROGRESS[],Dict("phase"=>"forward","detail"=>"Assembling and solving the baseline; timings include any first-use compilation and physical result recovery")))
        forward=measured_native_baseline(SensitivityNative) do
            Base.invokelatest(SensitivityNative.solve_model,parsed)
        end
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
