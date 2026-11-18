# Server-owned generated-panel workflow. Included by panel_server.jl after the
# light canonical model module; numerical/adjoint code is loaded on first use.
const PANEL_JOBS_LOCK = ReentrantLock()
const PANEL_JOBS = Dict{String,Dict{String,Any}}()
const PANEL_JOB_SEQUENCE = Ref(0)
const PANEL_ANALYSIS_READY = Ref(false)
const PANEL_WORKFLOW_ASSETS = Set(["panel_workflow.js", "panel_workflow.css"])

_panel_utc() = string(now(UTC)) * "Z"

function _panel_public_data(value)
    value === nothing && return nothing
    value isa AbstractFloat && return isfinite(value) ? value : nothing
    value isa Union{Number,AbstractString,Bool} && return value
    value isa Symbol && return String(value)
    value isa AbstractMatrix && return [_panel_public_data(collect(row)) for row in eachrow(value)]
    value isa Union{AbstractVector,Tuple} && return [_panel_public_data(item) for item in value]
    value isa NamedTuple && return Dict(string(key)=>_panel_public_data(item) for (key,item) in pairs(value))
    value isa AbstractDict && return Dict(string(key)=>_panel_public_data(item) for (key,item) in pairs(value)
        if !startswith(string(key), "_") && !(item isa Function))
    throw(ArgumentError("Unexpected public panel result type $(typeof(value))"))
end

function _panel_decode_request(req)
    body = isempty(req.body) ? Dict{String,Any}() : MsgPack.unpack(Vector{UInt8}(req.body))
    body isa AbstractDict || throw(ArgumentError("Request body must be a MessagePack map"))
    body
end

function _panel_model_response(payload)
    params = get(payload, "params", get(payload, "parameters", nothing))
    params isa AbstractDict || throw(ArgumentError("A generated-panel request needs a params map"))
    model = PandeatorModel.build_panel_model(params)
    merge(Dict{String,Any}("ok"=>true), PandeatorModel.panel_mesh_payload(model))
end

function _panel_job_event!(job, packet)
    packet isa AbstractDict || (packet = Dict("detail"=>string(packet)))
    data = Dict{String,Any}(string(key)=>_panel_public_data(value) for (key,value) in pairs(packet)
        if !startswith(string(key), "_") && !(value isa Function))
    lock(PANEL_JOBS_LOCK) do
        job["progress"] = data
        message = string(get(data, "log_message", get(data, "detail", "")))
        phase = string(get(data, "phase", "analysis"))
        events = job["log_events"]
        if !isempty(message) && (isempty(events) || get(last(events),"message","") != message || get(last(events),"phase","") != phase)
            job["log_sequence"] += 1
            push!(events, merge(copy(data), Dict("sequence"=>job["log_sequence"], "utc"=>_panel_utc(),
                "phase"=>phase, "message"=>message)))
            length(events)>500 && deleteat!(events, 1:length(events)-500)
        end
    end
    nothing
end

function _panel_load_analysis!()
    if !PANEL_ANALYSIS_READY[]
        isdefined(@__MODULE__, :PandeatorAnalysis) || Base.include(@__MODULE__, joinpath(APP_DIR,"panel_analysis.jl"))
        PANEL_ANALYSIS_READY[] = true
    end
    nothing
end

# Enter the latest world before looking up a module/function loaded by include.
# Wrapping only the final call leaves the binding lookup itself in an old world.
function _panel_analyze_current(model;kwargs...)
    analysis=getfield(@__MODULE__, :PandeatorAnalysis)
    analysis.panel_analyze(model;kwargs...)
end

function _panel_table_cell(value)
    replace(string(value), '|' => '/', '\n' => ' ')
end

function _panel_assessment_report(result)
    io = IOBuffer()
    println(io, "# PANDEATOR generated-panel buckling and sensitivities\n")
    println(io, "Units: mm, N, MPa; reserve factors are dimensionless.\n")
    println(io, "| Response | Value | Unit | Status | Method |")
    println(io, "|---|---:|---|---|---|")
    for row in get(result,"responses",Any[])
        println(io, "| ", join((_panel_table_cell(get(row,key,"")) for key in ("label","value","unit","status","method")), " | "), " |")
    end
    for row in get(result,"responses",Any[])
        assumptions = get(row,"assumptions",Any[])
        isempty(assumptions) || println(io, "\n", _panel_table_cell(row["label"]), ": ",
            assumptions isa AbstractVector ? join(string.(assumptions), "; ") : string(assumptions), "\n")
    end
    if !isempty(get(result,"sensitivities",Any[]))
        println(io, "\n## Adjoint derivatives\n\n| Response | Variable | Derivative | Unit | Status |\n|---|---|---:|---|---|")
        for row in result["sensitivities"]
            println(io,"| ",join((_panel_table_cell(get(row,key,"")) for key in ("response_id","variable_id","value","unit","status"))," | ")," |")
        end
    end
    if !isempty(get(result,"validation",Any[]))
        println(io,"\n## Independent central finite differences\n\n| Response | Variable | Relative step | Adjoint | Finite difference | Relative error | Status |\n|---|---|---:|---:|---:|---:|---|")
        for row in result["validation"]
            println(io,"| ",join((_panel_table_cell(get(row,key,"")) for key in ("response_id","variable_id","step_relative","adjoint","finite_difference","relative_error","status"))," | ")," |")
        end
    end
    String(take!(io))
end

function _panel_export_forward!(result, raw, directory, progress;include_binary=true)
    raw === nothing && return result
    progress(Dict("phase"=>"export", "detail"=>include_binary ? "Exporting the baseline already solved: viewer, numerical results and report" : "Writing the baseline report; no unrequested viewer or full-field exports"))
    OpenJFEM.export_results(raw,"panel.bdf",directory; export_json=include_binary,
        export_jfem_binary=include_binary, export_report=true)
    artifacts = include_binary ? _panel_binary_artifacts(directory,"panel") : Dict{String,Any}[]
    bytes = isempty(artifacts) ? UInt8[] : first(artifacts)["bytes"]
    result["sol"] = Int(raw["sol_type"])
    result["analysis_type"] = _analysis_type(result["sol"])
    result["jfem_bytes"] = bytes
    result["jfem_files"] = [merge(artifact,Dict("bytes"=>index==1 ? UInt8[] : artifact["bytes"])) for (index,artifact) in enumerate(artifacts)]
    result["jfem_path"] = isempty(artifacts) ? "" : first(artifacts)["path"]
    result["eigenvalues"] = isempty(artifacts) ? get(result,"eigenvalues",Float64[]) : first(artifacts)["eigenvalues"]
    result["frequencies"] = Float64.(get(raw,"frequencies",Float64[]))
    report_path = joinpath(directory,"panel.REPORT.md")
    result["report_path"] = isfile(report_path) ? report_path : ""
    text=isfile(report_path) ? read(report_path,String) : ""
    result["report"] = length(text)>20000 ? first(text,20000) : text
    result
end

function _panel_without_binary(value)
    value isa AbstractDict && return Dict(string(key)=>_panel_without_binary(item) for (key,item) in pairs(value)
        if !(string(key) in ("jfem_bytes","bytes")))
    value isa AbstractVector && return [_panel_without_binary(item) for item in value]
    value
end

function _panel_execute_job!(job, payload)
    started = time_ns()
    cancel_flag,directory,operation=lock(PANEL_JOBS_LOCK) do
        (job["cancel_requested"],job["output_dir"],job["operation"])
    end
    try
        lock(SOLVE_LOCK) do
            cancelled = () -> cancel_flag[]
            cancelled() && throw(InterruptException())
            lock(PANEL_JOBS_LOCK) do
                job["status"]="running"; job["started_at"]=_panel_utc()
            end
            progress = packet -> _panel_job_event!(job,packet)
            progress(Dict("phase"=>"model", "detail"=>"Building the canonical conforming skin, merged flange and stringer web"))
            model = PandeatorModel.build_panel_model(payload["params"])
            cancelled() && throw(InterruptException())
            write(joinpath(directory,"request.json"),JSON.json(_panel_public_data(payload)))
            progress(Dict("phase"=>"prepare", "detail"=>"Loading the shared JFEM and Boxer buckling/adjoint kernels; first use may compile"))
            _panel_load_analysis!()
            cancelled() && throw(InterruptException())
            options=get(payload,"options",Dict{String,Any}())
            derivatives=operation in ("sensitivities","validate")
            raw_result=Base.invokelatest(_panel_analyze_current,model;
                directory, variables=get(payload,"variables",nothing), derivatives,
                sol105=Bool(get(options,"sol105",operation!="analytical")),
                analytical=Bool(get(options,"analytical",true)),
                validate_fd=operation=="validate" || Bool(get(options,"validate_fd",false)),
                fd_steps=Float64.(get(options,"fd_steps",[1e-3,5e-4])),
                mode_count=Int(get(options,"mode_count",3)),
                fd_tolerance=Float64(get(options,"fd_tolerance",.005)), progress,cancelled)
            cancelled() && throw(InterruptException())
            result = _panel_public_data(raw_result)
            _panel_export_forward!(result,get(raw_result,"_forward",nothing),directory,progress;
                include_binary=Bool(get(options,"include_binary",operation=="analyze")))
            result["ok"]=true;result["operation"]=operation;result["output_dir"]=directory
            result["parameters"]=model.params
            result["model_report"]=_panel_public_data(model.report)
            result["assessment_report"]=_panel_assessment_report(result)
            write(joinpath(directory,"panel.ASSESSMENT.md"),result["assessment_report"])
            result["report"]=get(result,"report","")*"\n\n"*result["assessment_report"]
            result["elapsed_s"]=(time_ns()-started)*1e-9
            write(joinpath(directory,"panel.ANALYSIS.json"),JSON.json(_panel_without_binary(result)))
            cancelled() && throw(InterruptException())
            progress(Dict("phase"=>"complete", "detail"=>"Panel calculation complete; results and reproducible validation artifacts are ready"))
            lock(PANEL_JOBS_LOCK) do
                job["result"]=result;job["status"]="complete";job["finished_at"]=_panel_utc()
            end
        end
    catch error
        was_cancelled = error isa InterruptException || cancel_flag[]
        message=was_cancelled ? "Panel calculation cancelled; completed diagnostic files were retained" : sprint(showerror,error)
        _panel_job_event!(job,Dict("phase"=>was_cancelled ? "cancelled" : "error", "detail"=>message))
        lock(PANEL_JOBS_LOCK) do
            job["status"]=was_cancelled ? "cancelled" : "error"
            job["error"]=message;job["finished_at"]=_panel_utc()
            was_cancelled || (job["traceback"]=sprint(showerror,error,catch_backtrace()))
        end
        write(joinpath(directory,"job_error.json"),JSON.json(Dict("cancelled"=>was_cancelled,"error"=>message)))
    end
    nothing
end

function _panel_start_job(payload)
    operation=string(get(payload,"operation","analyze"))
    operation in ("analyze","analytical","sensitivities","validate") || throw(ArgumentError("Unknown panel operation"))
    params=get(payload,"params",nothing)
    params isa AbstractDict || throw(ArgumentError("A generated-panel job needs a params map"))
    normalized=PandeatorModel.normalize_panel_params(params)
    options=get(payload,"options",Dict{String,Any}())
    options isa AbstractDict || throw(ArgumentError("Panel options must be a map"))
    variables=get(payload,"variables",nothing)
    variables===nothing || variables isa AbstractVector || throw(ArgumentError("Variables must be an array of catalog IDs"))
    operation in ("sensitivities","validate") && variables!==nothing && isempty(variables) &&
        throw(ArgumentError("Select at least one panel design variable"))
    mkpath(RUN_ROOT)
    case_id=_panel_case_id(get(payload,"case_id","panel_"*Dates.format(now(UTC),"yyyymmdd_HHMMSS_sss")))
    directory=mktempdir(RUN_ROOT;prefix=case_id*"_",cleanup=false)
    job=lock(PANEL_JOBS_LOCK) do
        PANEL_JOB_SEQUENCE[]+=1;id="panel"*string(PANEL_JOB_SEQUENCE[])
        item=Dict{String,Any}("id"=>id,"operation"=>operation,"status"=>"queued","created_at"=>_panel_utc(),
            "output_dir"=>directory,"progress"=>Dict("phase"=>"queued","detail"=>"Waiting for the shared panel solver"),
            "log_events"=>Any[],"log_sequence"=>0,"cancel_requested"=>Threads.Atomic{Bool}(false))
        PANEL_JOBS[id]=item
        old=sort!([key for (key,value) in PANEL_JOBS if value["status"] in ("complete","cancelled","error")];by=key->get(PANEL_JOBS[key],"finished_at",""))
        while length(PANEL_JOBS)>25 && !isempty(old);delete!(PANEL_JOBS,popfirst!(old));end
        item
    end
    request=Dict{String,Any}(string(key)=>value for (key,value) in pairs(payload));request["params"]=normalized
    id=job["id"]
    task=Threads.@spawn _panel_execute_job!(job,request)
    lock(PANEL_JOBS_LOCK) do
        job["task"]=task
    end
    Dict("ok"=>true,"id"=>id,"status"=>"queued","output_dir"=>directory)
end

function _panel_job_status(id)
    lock(PANEL_JOBS_LOCK) do
        haskey(PANEL_JOBS,id) || throw(KeyError(id))
        job=PANEL_JOBS[id]
        response=Dict{String,Any}("ok"=>true,"id"=>id,"status"=>job["status"],"operation"=>job["operation"],
            "progress"=>copy(job["progress"]),"log_events"=>copy(job["log_events"]),
            "cancel_requested"=>job["cancel_requested"][],"output_dir"=>job["output_dir"])
        for key in ("result","error","created_at","started_at","finished_at")
            haskey(job,key) && (response[key]=job[key])
        end
        response
    end
end

function _panel_cancel_job(id)
    lock(PANEL_JOBS_LOCK) do
        haskey(PANEL_JOBS,id) || throw(KeyError(id))
        job=PANEL_JOBS[id]
        job["status"] in ("queued","running") && (job["cancel_requested"][]=true)
        Dict("ok"=>true,"id"=>id,"status"=>job["status"],"cancel_requested"=>job["cancel_requested"][],
            "detail"=>"Cancellation is cooperative; an active native factorization or compilation finishes before stopping")
    end
end
