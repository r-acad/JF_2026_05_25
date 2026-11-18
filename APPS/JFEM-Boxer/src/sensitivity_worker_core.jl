module JFEMSensitivityWorker
using LinearAlgebra
# Package-owned callbacks must resolve during shared-image signature replay.
# Requests are serialized by the shared FE worker; reset replaces request data.
const GENERATOR_MODULE=parentmodule(@__MODULE__)
nameof(GENERATOR_MODULE)===:WingFEGen||error("Load the sensitivity worker through WingFEGen.JFEMSensitivityWorker")
const NATIVE_MODULE=Ref{Union{Nothing,Module}}(nothing)
const DIRECTORY=Ref("")
const REPOSITORY=Ref("")
include(joinpath(@__DIR__,"sensitivity_io.jl"))

"""Resolve the root solver lazily without a cyclic package dependency.

The persistent service already loaded OpenJFEM. Explicit PkgId resolution also
supports standalone/prepared-image entry. No environment or LOAD_PATH changes;
every call verifies that the cached package belongs to the selected repository.
"""
function worker_native_module(repository::AbstractString)
    native=NATIVE_MODULE[]
    if native===nothing
        project=GENERATOR_MODULE.TOML.parsefile(joinpath(repository,"Project.toml"))
        get(project,"name","")=="OpenJFEM"||error("The selected shared project does not define OpenJFEM")
        native=Base.require(Base.PkgId(Base.UUID(project["uuid"]),"OpenJFEM"))
        NATIVE_MODULE[]=native
    end
    actual=realpath(pathof(native));expected=realpath(joinpath(repository,"src","OpenJFEM.jl"))
    (Sys.iswindows() ? lowercase(actual)==lowercase(expected) : actual==expected)||
        error("Loaded JFEM package does not match the selected repository: $actual (expected $expected)")
    native
end
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
function bootstrap_write(file,data;progress=false)
    SensitivityFileIO.write_text(joinpath(DIRECTORY[],file),bootstrap_json(data);progress)
end
const WORKER_STARTED=Ref(0.)
const LAST_PROGRESS=Ref{Any}(Dict{String,Any}())
const WORKER_TIMINGS=Dict{String,Any}()
const WORKER_LOG_EVENTS=Dict{String,Any}[]
const WORKER_LOG_SEQUENCE=Ref(0)
worker_stage_category(phase)=phase in ("forward","baseline_analysis","gradient","adjoint","operators","analytic_derivatives",
    "rf_assessment","rf_derivatives","optimization","final_verification") ?
    "numerical" : phase in ("baseline_export","result_export") ? "export" : "preparation"
function record_worker_log_event!(state,phase,message)
    WORKER_LOG_SEQUENCE[]+=1
    event=Dict{String,Any}("sequence"=>WORKER_LOG_SEQUENCE[],"message"=>string(message),"phase"=>phase)
    for key in ("event","iteration","evaluation","case_id","case_label","case_ids","mass","minimum_rf",
                "maximum_utilization","critical_case_id","critical_case_label","critical_failure_mode",
                "critical_property_ids","step","rejected_trials","evaluations","design_variable_count",
                "physical_dimension_count","constraint_count","case_count","active_constraint_count","adjoint_rhs")
        haskey(state,key)&&(event[key]=state[key])
    end
    push!(WORKER_LOG_EVENTS,event)
    length(WORKER_LOG_EVENTS)>250&&popfirst!(WORKER_LOG_EVENTS)
    event
end
function progress(data)
    state=Dict{String,Any}(data);state["worker_seconds"]=time()-WORKER_STARTED[]
    state["worker_timings"]=copy(WORKER_TIMINGS)
    phase=String(get(state,"phase","bootstrap"))
    message=pop!(state,"log_message",nothing)
    if message!==nothing
        record_worker_log_event!(state,phase,message)
        println("[RF] ",message);flush(stdout)
    end
    isempty(WORKER_LOG_EVENTS)||(state["log_events"]=copy(WORKER_LOG_EVENTS))
    state["stage_category"]=worker_stage_category(phase)
    state["stage_state"]=phase=="complete" ? "completed" : phase=="failed" ? "failed" : "started"
    state["compilation_live"]="not_separable"
    state["timing_scope"]="worker_timings separates completed measured compilation; timings_seconds is inclusive wall time and may include compilation. sensitivity_compute includes preparation, baseline, adjoint, derivatives and exports; native baseline stages are nested within baseline_analysis. Do not sum nested timings. Compilation counters can overlap across Julia threads and exceed elapsed wall time; execution_seconds is then unavailable."
    LAST_PROGRESS[]=state
    if !bootstrap_write("progress.json",state;progress=true)
        println(stderr,"Progress update deferred: progress.json is temporarily unavailable for replacement; the analysis continues.")
        flush(stderr)
    end
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
    if compiled>wall
        println("[Timing] Compilation counters overlap across Julia threads; they exceed elapsed wall time. Execution time cannot be separated for this stage.")
        flush(stdout)
    end
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
function reset_worker!(directory,repository)
    DIRECTORY[]=abspath(directory);REPOSITORY[]=abspath(repository)
    WORKER_STARTED[]=time();LAST_PROGRESS[]=Dict{String,Any}()
    empty!(WORKER_TIMINGS);empty!(WORKER_LOG_EVENTS);WORKER_LOG_SEQUENCE[]=0;WORKER_STAGE[]="bootstrap"
    nothing
end

function solve_baseline(path)
    native=worker_native_module(REPOSITORY[])
    progress(merge(LAST_PROGRESS[],Dict("phase"=>"baseline_parse","detail"=>"Reading the baseline deck and building its native model; first-use compilation is measured separately")))
    parsed=measured_worker_stage("baseline_parse") do
        Base.invokelatest(native.bdf_to_model,path)
    end
    progress(merge(LAST_PROGRESS[],Dict("phase"=>"forward","detail"=>"Assembling and solving the baseline; timings include any first-use compilation and physical result recovery")))
    measured_native_baseline(native) do
        Base.invokelatest(native.solve_model,parsed)
    end
end

"""Execute one isolated sensitivity request; callers serialize access to this worker."""
function run_sensitivity_worker(directory,repository;runtime=Dict{String,Any}())
reset_worker!(directory,repository)
try
    mkpath(DIRECTORY[])
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
    LinearAlgebra.BLAS.set_num_threads(1)
    active_runtime=merge(runtime,Dict("threads"=>Threads.nthreads(),"blas_threads"=>LinearAlgebra.BLAS.get_num_threads()))
    WORKER_STAGE[]="generator dependencies"
    W=measured_worker_stage("generator_load") do
        GENERATOR_MODULE
    end
    WORKER_STAGE[]="native solver"
    progress(Dict("completed"=>0,"total"=>0,"phase"=>"native_package_load",
        "detail"=>"Loading the cached JFEM solver package; an installation or source change may require precompilation"))
    native=measured_worker_stage("native_package_load") do
        worker_native_module(REPOSITORY[])
    end
    Base.invokelatest() do
        bootstrap_write("worker_runtime.json",Dict(
            "julia_version"=>string(VERSION),"executable_directory"=>Sys.BINDIR,
            "project"=>Base.active_project(),"image"=>unsafe_string(Base.JLOptions().image_file),
            "threads"=>Threads.nthreads(),"blas_threads"=>LinearAlgebra.BLAS.get_num_threads(),
            "manifest_sha256"=>bytes2hex(W.SHA.sha256(read(joinpath(REPOSITORY[],"Manifest.toml")))),
            "packages"=>Dict("WingFEGen"=>string(Base.pkgversion(W)),
                "OpenJFEM"=>string(Base.pkgversion(native)),
                "HTTP"=>string(Base.pkgversion(W.HTTP)),"JSON"=>string(Base.pkgversion(W.JSON)),
                "ForwardDiff"=>string(Base.pkgversion(native.ForwardDiff)))))
    end
    WORKER_STAGE[]="saved model"
    model=try Base.invokelatest(W.Serialization.deserialize,joinpath(DIRECTORY[],"model.jls")) catch failure
        throw(ArgumentError("The saved sensitivity mesh cannot be read by Julia $VERSION. Recreate the FEM and start the study again. Details: "*sprint(showerror,failure)))
    end
    request=Base.invokelatest(W.JSON.parsefile,joinpath(DIRECTORY[],"request.json"))
    WORKER_STAGE[]="adjoint analysis"
    if get(request,"rf_analysis",false)===true
        progress(Dict("completed"=>0,"total"=>0,"phase"=>"rf_preparation",
            "detail"=>"Preparing native RF and derivative kernels; first-use Julia compilation may take time"))
    end
    result=measured_worker_stage("sensitivity_compute") do
        rf=get(request,"rf_analysis",false)===true
        compute=rf ? W.compute_rf_sensitivity : W.compute_sensitivity
        Base.invokelatest(compute,model,request,DIRECTORY[];native,solve=solve_baseline,progress,
            cancelled=()->isfile(joinpath(DIRECTORY[],"cancel.requested")))
    end
    result["worker_runtime"]=active_runtime
    result["worker_timings"]=copy(WORKER_TIMINGS)
    result["worker_seconds"]=time()-WORKER_STARTED[]
    measured_worker_stage("result_export") do
        Base.invokelatest(W.sensitivity_json_write,joinpath(DIRECTORY[],"result.json"),result)
    end
    # Publish the final aggregate timing in progress as well as the result.
    progress(merge(LAST_PROGRESS[],Dict("phase"=>"complete")))
    return true
catch failure
    detail=sprint(showerror,failure,catch_backtrace())
    stage=WORKER_STAGE[]
    message="Sensitivity worker failed while loading $stage (Julia $VERSION): "*sprint(showerror,failure)
    stage=="adjoint analysis"&&(message=sprint(showerror,failure))
    try
        bootstrap_write("error.json",Dict("message"=>message,"detail"=>detail,"stage"=>stage,"julia_version"=>string(VERSION)))
    catch reporting_failure
        println(stderr,"Could not write structured sensitivity error: ",sprint(showerror,reporting_failure))
    end
    # Keep completed baseline/adjoint/operator counts visible if a later stage
    # fails. Resetting everything to zero misrepresents work already completed.
    try
        progress(merge(Dict{String,Any}("completed"=>0,"total"=>0),LAST_PROGRESS[],
            Dict("phase"=>"failed","detail"=>message)))
    catch reporting_failure
        println(stderr,"Could not publish failed sensitivity progress: ",sprint(showerror,reporting_failure))
    end
    println(stderr,detail)
    return false
end

end # run_sensitivity_worker
end # module
