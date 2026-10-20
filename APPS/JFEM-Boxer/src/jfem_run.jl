# ===========================================================================
#  jfem_run.jl - run the generated deck in the JFEM solver and read it back
#
#  The solver is the JFEM/OpenJFEM repository that lives in this workspace.
#  FE requests share a directly owned Julia worker with the canonical project
#  and verified shared image. Each request retains the CLI output contract:
#
#      jfem -jrs <model.bdf> <output_dir>
#
#  and writes, into the output folder,
#
#      <stem>.REPORT.md        human readable report
#      <stem>.JU.JSON          results, SOL 101
#      <stem>.BUCKLING.JSON    results, SOL 103
#      <stem>.jfem             the native JFEM viewer file
#
#  Requests run sequentially in the persistent process; console output streams
#  into a line buffer, so the web app can poll for progress rather than
#  holding a request open. Later cases reuse loaded packages and compiled
#  methods. Cancellation stops that worker; the next request starts a fresh one.
#
#  Results are read from the JSON and re-indexed onto this model's node
#  ordering, so the browser can apply a mode shape straight to its vertex
#  buffers with no lookup.
# ===========================================================================

# --- locating the solver ---------------------------------------------------

"""
    jfem_launcher(repo) -> Union{String,Nothing}

Path of the launcher script inside a JFEM repository, or `nothing` when this
does not look like one.
"""
function jfem_launcher(repo::AbstractString)
    isdir(repo) || return nothing
    isfile(joinpath(repo, "src", "OpenJFEM.jl")) || return nothing
    names = Sys.iswindows() ? ("jfem.cmd", "jfem.bat", "jfem") : ("jfem",)
    for n in names
        p = joinpath(repo, n)
        isfile(p) && return p
    end
    return nothing
end

"""
    find_jfem(root; hint = "") -> (repo, launcher)

Locate the enclosing JFEM repository shared by all applications. An explicit
`hint` may identify this repository or its launcher. Foreign legacy environment
hints are ignored; explicit foreign repository selections are rejected.
"""
function find_jfem(root::AbstractString; hint::AbstractString = "",environment=ENV)
    canonical=WingFEGenBootstrap.locate_solver(root;hint=get(environment,"WINGFEGEN_JFEM",""))
    canonical===nothing&&return (nothing,nothing)
    canonical_launcher=jfem_launcher(canonical)
    canonical_launcher===nothing&&return (nothing,nothing)
    if !isempty(strip(hint))
        expanded=expanduser(strip(hint))
        h = abspath(isabspath(expanded) ? expanded : joinpath(root,expanded))
        if isfile(h)                       # pointed straight at the launcher
            l=jfem_launcher(dirname(h))
            if l!==nothing&&basename(h) in ("jfem","jfem.cmd","jfem.bat")
                realpath(dirname(h))==realpath(canonical)||throw(ArgumentError("All applications use the enclosing JFEM repository: $canonical. Clear the foreign jfem.repo / jfem.path setting."))
                return (canonical,h)
            end
            throw(ArgumentError("jfem.repo / jfem.path must identify the JFEM repository or its launcher: $h"))
        end
        l = jfem_launcher(h)
        if l!==nothing
            realpath(h)==realpath(canonical)||throw(ArgumentError("All applications use the enclosing JFEM repository: $canonical. Clear the foreign jfem.repo / jfem.path setting."))
            return (canonical,l)
        end
        throw(ArgumentError("jfem.repo does not look like a JFEM repository: $h"))
    end
    return (canonical,canonical_launcher)
end

# --- a run -----------------------------------------------------------------

"""
    JfemJob

One solver run. `lines` is a bounded live console tail, guarded by `lk`.
`logpath` retains the complete output independently of browser polling.
"""
mutable struct JfemJob
    id::String
    cmdline::String
    bdf::String
    outdir::String
    logpath::String
    repo::String
    model::Model
    proc::Union{Nothing,Base.Process}
    lines::Vector{String}
    lk::ReentrantLock
    started::Float64
    finished::Union{Nothing,Float64}
    state::Symbol          # :queued, :running, :done, :partial, :failed, :cancelled
    exitcode::Int
    message::String
    runs::Vector{JfemJob}  # isolated physical cases or paired comparison runs
    case_id::Int          # original physical case ID (native child SID is 1)
    case_label::String
    cancel_requested::Bool
    log_offset::Int         # absolute count preceding the retained live tail
    log_bytes::Int
    progress::Dict{String,Any}
    log_done::Bool          # pipe reader has closed/flushed the full disk log
end

# Preserve the existing constructor used by archived-result readers and tests.
JfemJob(id,cmdline,bdf,outdir,logpath,repo,model,proc,lines,lk,started,finished,state,exitcode,message) =
    JfemJob(id,cmdline,bdf,outdir,logpath,repo,model,proc,lines,lk,started,finished,state,exitcode,message,
        JfemJob[],1,String(get(model.params,"loads.label","Load case 1")),false)

function JfemJob(id,cmdline,bdf,outdir,logpath,repo,model,proc,lines,lk,started,finished,state,exitcode,message,
                 runs,case_id,case_label,cancel_requested)
    retained=String[bounded_log_line(line) for line in lines]
    job=JfemJob(id,cmdline,bdf,outdir,logpath,repo,model,proc,retained,lk,started,finished,state,exitcode,message,
        runs,case_id,case_label,cancel_requested,0,sum(ncodeunits,retained;init=0),Dict{String,Any}(),false)
    trim_job_log!(job)
    return job
end

const JOB_LOG_MAX_LINES=4000
const JOB_LOG_MAX_BYTES=1024*1024
const JOB_LOG_LINE_BYTES=8192
const JOB_LOG_BATCH_LINES=200
const JOB_LOG_BATCH_BYTES=64*1024
const JOB_LOG_TRUNCATED=" … [live line shortened; complete text in downloaded log]"

function bounded_log_line(line::AbstractString)
    text=String(line)
    ncodeunits(text)<=JOB_LOG_LINE_BYTES && return text
    budget=JOB_LOG_LINE_BYTES-ncodeunits(JOB_LOG_TRUNCATED)
    stop=prevind(text,budget+1)
    while stop>0 && nextind(text,stop)-1>budget
        stop=prevind(text,stop)
    end
    return String(SubString(text,1,stop))*JOB_LOG_TRUNCATED
end

function trim_job_log!(job::JfemJob)
    remove=max(0,length(job.lines)-JOB_LOG_MAX_LINES)
    # Drop a block when full, avoiding an O(capacity) array shift per line.
    remove>0 && (remove=max(remove,min(length(job.lines),JOB_LOG_MAX_LINES÷4)))
    bytes=job.log_bytes-sum(ncodeunits,view(job.lines,1:remove);init=0)
    target=bytes>JOB_LOG_MAX_BYTES ? 3JOB_LOG_MAX_BYTES÷4 : JOB_LOG_MAX_BYTES
    while bytes>target && remove<length(job.lines)
        remove+=1; bytes-=ncodeunits(job.lines[remove])
    end
    if remove>0
        deleteat!(job.lines,1:remove)
        job.log_offset+=remove
    end
    job.log_bytes=bytes
    return job
end

function retain_job_line!(job::JfemJob,line::AbstractString)
    text=bounded_log_line(line)
    push!(job.lines,text); job.log_bytes+=ncodeunits(text)
end

job_seconds(j::JfemJob) = j.started <= 0 ? 0.0 :
    (j.finished === nothing ? time() : j.finished) - j.started

"""Measured numerical execution, separately from process wall time and Julia JIT.

Old/partial logs without timing evidence never substitute wall time for solve time.
"""
function job_timings(job::JfemJob)
    children = isempty(job.runs) ? [job] : job.runs
    measurements = Any[]; stages=Any[]
    for (run_index,child) in enumerate(children)
        entry = lock(child.lk) do
            get(child.progress, "pipeline_timings", nothing)
        end
        if entry !== nothing
            push!(measurements,entry)
            for row in get(entry,"stages",Any[])
                push!(stages,merge(Dict{String,Any}(row),Dict("run_index"=>run_index,
                    "case_id"=>child.case_id,"solution"=>String(child.model.params["output.solution"]))))
            end
        end
    end
    available = length(measurements) == length(children) &&
        all(d -> get(d,"solution_seconds",nothing) isa Real, measurements)
    function phase_sum(keys...)
        total = 0.0
        for d in measurements, key in keys
            phase = get(d["phases"], key, nothing)
            phase === nothing && continue # Optional stage was not run.
            execution = get(phase, "execution_seconds", nothing)
            execution isa Real || return nothing # Measured, but not separable.
            total += execution
        end
        return total
    end
    function category_sum(category,legacy_keys...)
        total=0.
        for d in measurements
            if get(d,"schema_version",1)>=2
                value=get(d,category*"_seconds",nothing)
                value isa Real || return nothing
                total+=value
            else
                for key in legacy_keys
                    phase=get(d["phases"],key,nothing);phase===nothing && continue
                    value=get(phase,"execution_seconds",nothing)
                    value isa Real || return nothing
                    total+=value
                end
            end
        end
        return total
    end
    measured_wall = sum((d["measured_wall_seconds"] for d in measurements); init=0.0)
    Dict{String,Any}(
        "available" => available,
        "solution_seconds" => available ? sum(d["solution_seconds"] for d in measurements) : nothing,
        "compilation_seconds" => sum((d["compilation_seconds"] for d in measurements);init=0.0),
        "preparation_seconds" => category_sum("preparation","parse", "build_model"),
        "export_seconds" => category_sum("export","model_export", "export", "report"),
        "stages" => stages,
        "stage_measurement" => "Inclusive children are included in their parent; totals use exclusive stage time. Compilation includes recompilation.",
        "adjoint_seconds" => phase_sum("adjoint"),
        "startup_overhead_seconds" => available ? max(0.0,job_seconds(job)-measured_wall) : nothing,
        "total_seconds" => job_seconds(job),
        "measured_runs" => length(measurements), "total_runs" => length(children),
        "solution_scope" => "Numerical stage execution, including deferred recovery; excludes measured compilation, deck preparation and file export. Wall time, not CPU time.",
        "startup_scope" => "Worker queue/startup, package loading and other unmeasured request overhead; a reused worker does not repeat process startup")
end

function job_log(j::JfemJob; tail::Int = 400)
    lock(j.lk) do
        n = length(j.lines)
        first_idx = (tail > 0 && n > tail) ? n - tail + 1 : 1
        bytes=0
        for i in n:-1:first_idx
            bytes+=ncodeunits(j.lines[i])+1
            if bytes>JOB_LOG_BATCH_BYTES
                first_idx=i+1
                break
            end
        end
        return join(view(j.lines, first_idx:n), "\n")
    end
end

job_line_count(j::JfemJob) = lock(j.lk) do
    j.log_offset+length(j.lines)
end

"""
    job_log_batch(j, from) -> bounded lines and absolute cursor metadata

Console lines with index greater than `from`, so the web app can append only
what is new. A delayed client gets an explicit omitted-line count rather than
an unbounded response; the downloadable disk log remains complete.
"""
function job_log_batch(j::JfemJob,from::Int; limit::Int=JOB_LOG_BATCH_LINES,max_bytes::Int=JOB_LOG_BATCH_BYTES)
    lock(j.lk) do
        total=j.log_offset+length(j.lines)
        requested=clamp(from,0,total)
        cursor=max(requested,j.log_offset)
        omitted=max(0,j.log_offset-requested)
        lines=String[]; bytes=0
        for i in cursor-j.log_offset+1:length(j.lines)
            line=j.lines[i]; cost=ncodeunits(line)+1
            length(lines)>=clamp(limit,1,JOB_LOG_BATCH_LINES) && break
            !isempty(lines) && bytes+cost>clamp(max_bytes,JOB_LOG_LINE_BYTES,JOB_LOG_BATCH_BYTES) && break
            push!(lines,line);bytes+=cost;cursor+=1
        end
        return (lines=lines,next_line=cursor,total_lines=total,first_line=j.log_offset+1,
            omitted_lines=omitted,has_more=cursor<total)
    end
end

function job_lines_from(j::JfemJob,from::Int)
    batch=job_log_batch(j,from)
    return batch.lines,batch.next_line
end

"""Describe observed solver stages without inventing numerical percentages."""
function update_job_stage!(job::JfemJob,line::AbstractString)
    isempty(job.runs)||return
    if startswith(line,"[JFEM_PROGRESS] ")
        try
            data=JSON.parse(chopprefix(line,"[JFEM_PROGRESS] "))
            valid=get(data,"schema_version",nothing)==1 &&
                get(data,"phase",nothing) isa AbstractString && get(data,"label",nothing) isa AbstractString &&
                get(data,"category",nothing) in ("preparation","numerical","export") &&
                get(data,"state",nothing) in ("started","completed","failed")
            valid || return
            p=job.progress;state=String(data["state"])
            p["stage_source"]="structured";p["stage"]=String(data["phase"])
            p["stage_category"]=String(data["category"]);p["stage_state"]=state
            p["stage_id"]=get(data,"id","");p["stage_parent"]=get(data,"parent",nothing)
            p["stage_depth"]=get(data,"depth",0)
            p["compilation_live"]=state=="started" ? "not_separable" : "measured_retrospectively"
            elapsed=get(data,"elapsed_seconds",0.)
            elapsed=elapsed isa Real && isfinite(elapsed) && elapsed>=0 ? Float64(elapsed) : 0.
            p["stage_started"]=time()-elapsed;p["stage_completed_seconds"]=elapsed
            message=String(data["label"])
            state=="started" && (message*="; Julia compilation may occur (separated after completion)")
            p["stage_message"]=message
            get(p,"phase","") in ("iterating","cutback") || (p["message"]=message)
            timing=get(data,"timing",nothing)
            if timing isa AbstractDict && all(key->get(timing,key,nothing) isa Real && isfinite(timing[key]) && timing[key]>=0,
                    ("wall_seconds","compilation_seconds","recompilation_seconds","gc_seconds")) &&
                    (get(timing,"execution_seconds",nothing)===nothing ||
                    (timing["execution_seconds"] isa Real && isfinite(timing["execution_seconds"]) && timing["execution_seconds"]>=0))
                p["stage_timing"]=timing
                p["last_completed_stage"]=data
            else
                delete!(p,"stage_timing")
            end
        catch
            # Timing telemetry never disrupts the solve or its log stream.
        end
        return
    end
    if startswith(line,"[JFEM_TIMINGS] ")
        try
            data=JSON.parse(chopprefix(line,"[JFEM_TIMINGS] "))
            valid=get(data,"schema_version",nothing) in (1,2) && get(data,"phases",nothing) isa AbstractDict &&
                all(key->get(data,key,nothing) isa Real && isfinite(data[key]) && data[key]>=0,
                    ("measured_wall_seconds","compilation_seconds"))
            solution=get(data,"solution_seconds",nothing)
            valid &= solution===nothing || (solution isa Real && isfinite(solution) && solution>=0)
            valid &= all(value->value isa AbstractDict,values(get(data,"phases",Dict())))
            if valid && data["schema_version"]==2
                seconds(value)=value===nothing || (value isa Real && isfinite(value) && value>=0)
                rows=get(data,"stages",nothing)
                valid=all(key->haskey(data,key) && seconds(data[key]),("preparation_seconds","export_seconds")) &&
                    rows isa AbstractVector && all(rows) do row
                        row isa AbstractDict || return false
                        get(row,"phase",nothing) isa AbstractString || return false
                        get(row,"category",nothing) in ("preparation","numerical","export") || return false
                        all(("inclusive","exclusive")) do kind
                            metrics=get(row,kind,nothing)
                            metrics isa AbstractDict || return false
                            all(key->haskey(metrics,key) && seconds(metrics[key]),
                                ("wall_seconds","compilation_seconds","recompilation_seconds","execution_seconds","gc_seconds"))
                        end
                    end
            end
            valid && (job.progress["pipeline_timings"]=data)
        catch
            # A malformed log marker must not break streaming or stop the solver.
        end
        return
    end
    get(job.progress,"stage_source",nothing)=="structured" && return
    stage,message=if occursin("Reading BDF file",line)
        ("deck","Reading the deck and constructing the native model (first-use compilation may occur)")
    elseif occursin("Computing Element Stiffness",line)
        ("assembly","Assembling element stiffness and constraints (first-use compilation may occur)")
    elseif occursin("Using Direct Solver",line)||occursin("Using Iterative Solver",line)
        ("linear_solve","Solving the constrained system")
    elseif occursin("Post-Processing",line)
        ("recovery","Recovering physical displacements, stresses, forces and reactions")
    elseif occursin("Exporting",line)
        ("export","Writing the solved results for the viewer")
    else
        return
    end
    p=job.progress
    if get(p,"stage",nothing)!=stage
        previous=get(p,"stage",nothing);started=get(p,"stage_started",nothing)
        previous===nothing||started===nothing|| (get!(p,"stage_timings_seconds",Dict{String,Float64}())[previous]=time()-started)
        p["stage"]=stage;p["stage_started"]=time()
    end
    p["stage_message"]=message
    p["stage_category"]=stage=="deck" ? "preparation" : stage=="export" ? "export" : "numerical"
    p["stage_state"]="started";p["compilation_live"]="not_separable"
    get(p,"phase","") in ("iterating","cutback")|| (p["message"]=message)
    nothing
end

"""Parse native load-iteration evidence; attempted load is not acceptance."""
function update_job_progress!(job::JfemJob,line::AbstractString)
    update_job_stage!(job,line)
    job.model.params["output.solution"]=="106" && isempty(job.runs) || return nothing
    occursin("NL ",line) || return nothing
    p=job.progress
    iteration=match(r"NL target=([+\-0-9.eE]+)\s+iter\s+(\d+)",line)
    cutback=match(r"NL cutback:.*target scale\s+([+\-0-9.eE]+)",line)
    iteration===nothing && cutback===nothing && return nothing
    value=tryparse(Float64,(iteration===nothing ? cutback : iteration).captures[1])
    if value===nothing || !isfinite(value) || !(0<=value<=1.0001)
        return nothing
    end
    target=clamp(100value,0.0,100.0)
    previous=get(p,"target_percent",nothing)
    if cutback!==nothing
        p["attempt"]=get(p,"attempt",1)+1
        p["cutbacks"]=get(p,"cutbacks",0)+1
        p["phase"]="cutback";p["iteration"]=0
    else
        if previous===nothing || target>previous+1e-8
            previous===nothing || (p["accepted_percent"]=previous)
            p["attempt"]=1
        end
        p["phase"]="iterating";p["iteration"]=parse(Int,iteration.captures[2])
        residual=match(r"rel_res_after=([+\-0-9.eE]+)",line)
        residual===nothing || (p["relative_residual"]=tryparse(Float64,residual.captures[1]))
    end
    p["target_percent"]=target
    get!(p,"accepted_percent",0.0);get!(p,"cutbacks",0)
    accepted=round(p["accepted_percent"];digits=4)
    detail=cutback===nothing ? "iteration $(p["iteration"]), attempt $(p["attempt"])" : "cutback retry $(p["attempt"])"
    p["message"]="Applied-load target $(round(target;digits=4))% ($detail); last accepted $(accepted)%."
    return "[Progress] "*p["message"]
end

function job_progress(job::JfemJob)
    if !isempty(job.runs)
        active=findfirst(child->child.state===:running,job.runs)
        active===nothing && (active=findlast(child->child.started>0,job.runs))
        active===nothing && return Dict{String,Any}("phase"=>"queued","message"=>"Waiting for the first solver run")
        result=job_progress(job.runs[active])
        result["run_index"]=active;result["run_count"]=length(job.runs)
        return result
    end
    lock(job.lk) do
        result=copy(job.progress)
        stage_started=pop!(result,"stage_started",nothing)
        stage_started===nothing || (result["stage_seconds"]=get(result,"stage_state","") in ("completed","failed") ?
            get(result,"stage_completed_seconds",0.) : max(0.,(job.finished===nothing ? time() : job.finished)-stage_started))
        pop!(result,"stage_completed_seconds",nothing)
        result["case_id"]=job.case_id;result["case_label"]=job.case_label
        result["solution"]=String(job.model.params["output.solution"])
        get!(result,"phase",String(job.state))
        for key in ("target_percent","accepted_percent","iteration","attempt","cutbacks")
            get!(result,key,nothing)
        end
        get!(result,"message",job.state===:running ? "Preparing the solver" : job.message)
        return result
    end
end

function record_job_lines!(job::JfemJob,lines)
    published=String[]
    lock(job.lk) do
        for line in lines
            text=String(line);push!(published,text);retain_job_line!(job,text)
            extra=update_job_progress!(job,text)
            extra===nothing || (push!(published,extra);retain_job_line!(job,extra))
        end
        trim_job_log!(job)
    end
    return published
end

"""
    start_jfem_job(model, params, root, bdf, id) -> JfemJob

Spawn the solver on an already written deck and return at once, without
waiting for it. `model` is kept with the job because the results are indexed
back onto its node ordering, so the deck must be the one written from this
very model.
"""
function prepare_jfem_job(model::Model, params::AbstractDict, root::AbstractString,
                          bdf::AbstractString, id::AbstractString; outdir=nothing)
    repo, launcher = find_jfem(root; hint = String(params["jfem.repo"]))
    repo === nothing && throw(ArgumentError(
        "the JFEM solver was not found. Set jfem.repo to the JFEM repository " *
        "folder (the one holding src/OpenJFEM.jl and the jfem launcher)."))
    isfile(bdf) || throw(ArgumentError("deck not found: $bdf"))

    if outdir === nothing
        base = String(params["jfem.output_dir"])
        base = isabspath(base) ? base : normpath(joinpath(root,base))
        mkpath(base)
        prefix = "run_" * Dates.format(Dates.now(),"yyyymmdd_HHMMSS_sss") * "_" * String(id) * "_"
        outdir = mktempdir(base; prefix, cleanup=false)
    else
        isdir(outdir) && !isempty(readdir(outdir)) && throw(ArgumentError("solver output directory must be empty: $outdir"))
        mkpath(outdir)
    end
    # Each run retains the exact deck it solved. Existing outputs are never
    # deleted and cannot be mistaken for the result of a failed new process.
    snapshot = joinpath(outdir,basename(bdf))
    abspath(snapshot) == abspath(bdf) || cp(bdf,snapshot;force=false)

    formats = "-" * strip(String(params["jfem.output_formats"]), ['-', ' '])
    argv = Sys.iswindows() ?
           ["cmd", "/c", launcher, formats, abspath(snapshot), outdir] :
           [launcher, formats, abspath(snapshot), outdir]
    logpath = joinpath(outdir, "jfem_run.log")

    job = JfemJob(id, join(argv[(Sys.iswindows() ? 3 : 1):end], " "),
                  abspath(snapshot), outdir, logpath, repo, model, nothing,
                  String[], ReentrantLock(), 0.0, nothing, :queued, 0, "")
    return job
end

include("solver_worker_client.jl")

function finish_jfem_process!(job::JfemJob,exitcode::Integer;failure_reason::AbstractString="")
    message=exitcode==0 ? "" : isempty(strip(failure_reason)) ?
        "the solver exited with code $exitcode" : String(failure_reason)
    if exitcode==0 && !job.cancel_requested
        try
            path,data=find_results_json(job.outdir)
            solution=String(job.model.params["output.solution"])
            path===nothing && error("no solver results JSON was written")
            startswith(String(get(data,"analysis_type","")),"SOL"*solution) ||
                error("the result analysis type does not match SOL$solution")
            if solution=="106"
                for spec in load_case_specs(job.model.params)
                    convergence=nonlinear_case_convergence(data,spec.id)
                    lock(job.lk) do
                        accepted=get(convergence,"final_load_scale",nothing)
                        accepted isa Real && isfinite(accepted) &&
                            (job.progress["accepted_percent"]=clamp(100accepted,0.0,100.0))
                        job.progress["results_available"]=get(convergence,"available",false)===true
                        job.progress["phase"]=get(convergence,"available",false)===true && get(convergence,"full_load",false)===true &&
                            get(convergence,"converged",false)===true ? "completed" : "incomplete"
                        job.progress["message"]=String(get(convergence,"message",""))
                    end
                    accepted=get(convergence,"final_load_scale",nothing)
                    percent=accepted isa Real && isfinite(accepted) ? "$(round(100accepted;digits=4))%" : "unknown"
                    append_job_lines!(job,["[Progress] Accepted applied load $percent. "*
                        get(convergence,"message","SOL106 diagnostic check completed")])
                    if get(convergence,"available",false) !== true ||
                       get(convergence,"full_load",false) !== true || get(convergence,"converged",false) !== true
                        message="SOL106 did not converge at the full requested load: " *
                            String(get(convergence,"message","missing convergence evidence"))
                        break
                    end
                end
            end
        catch e
            message="solver results could not be verified: "*sprint(showerror,e)
        end
    end
    lock(job.lk) do
        job.exitcode=Int(exitcode)
        if !job.cancel_requested
            job.finished=time(); job.state=isempty(message) ? :done : :failed
            job.message=message
            if job.state===:failed
                job.progress["phase"]=get(job.progress,"results_available",false)===true ? "incomplete" : "failed"
                job.progress["message"]=message
            elseif !haskey(job.progress,"phase") || job.progress["phase"] in ("iterating","cutback")
                job.progress["phase"]=job.state===:done ? "completed" : "failed"
                job.progress["message"]=isempty(message) ? "Solver completed" : message
            end
        end
    end
    !isempty(message) && !job.cancel_requested && append_job_lines!(job,["[Failure] "*message])
    return job
end

job_results_available(job::JfemJob) = isempty(job.runs) ?
    job.state===:done || get(job.progress,"results_available",false)===true :
    any(job_results_available,job.runs)

function enforce_job_timeout!(job::JfemJob; now=time())
    isempty(job.runs) || return job # a pair has one independent timeout per child
    limit=solver_timeout_seconds(job.model.params)
    if limit>0 && job.state===:running && now-job.started>limit
        kill_job!(job;message="the run passed the $(round(Int,limit/60)) minute timeout and was stopped",state=:failed)
    end
    return job
end

function start_jfem_job(model::Model,params::AbstractDict,root::AbstractString,
                        bdf::AbstractString,id::AbstractString)
    is_imported_model(model)&&return launch_jfem_process!(prepare_jfem_job(model,params,root,bdf,id))
    if params["output.solution"] == "106" || fuel_states_differ(model)
        return start_jfem_comparison(model,params,root,bdf,id)
    end
    return launch_jfem_process!(prepare_jfem_job(model,params,root,bdf,id))
end

"""
    kill_job!(j)

Stop a running solver process.
"""
function kill_job!(j::JfemJob; message="the run was stopped", state=:cancelled)
    j.state in (:queued,:running) || return nothing
    changed=lock(j.lk) do
        j.state in (:queued,:running) || return false
        j.cancel_requested=true; j.state=state; j.message=message
        j.progress["phase"]=String(state);j.progress["message"]=message
        j.finished === nothing && (j.finished=time())
        true
    end
    changed || return nothing
    for child in j.runs
        kill_job!(child;message,state)
    end
    cancel_persistent_solver_job!(j) && return nothing
    j.proc === nothing && return nothing
    try
        if process_running(j.proc)
            if Sys.iswindows()
                # The launcher is cmd.exe; stop only this launched process tree,
                # including its Julia child, rather than leaving an orphan.
                run(pipeline(Cmd(["taskkill","/PID",string(getpid(j.proc)),"/T","/F"]);
                    stdout=devnull,stderr=devnull))
            else
                kill(j.proc)
            end
        end
    catch
        try process_running(j.proc) && kill(j.proc) catch end
    end
    return nothing
end

function append_job_lines!(job::JfemJob,lines)
    isempty(lines) && return
    published=record_job_lines!(job,lines)
    lock(job.lk) do
        open(job.logpath,"a") do io
            for line in published
                println(io,line)
            end
        end
    end
end

"""Bounded streaming cursor: the full parent log does not depend on a live tail."""
mutable struct JobDiskCursor
    offset::Int
    line_start::Bool
    preview::Vector{UInt8}
    shortened::Bool
end
JobDiskCursor()=JobDiskCursor(0,true,UInt8[],false)

function disk_preview(cursor::JobDiskCursor)
    bytes=copy(cursor.preview)
    # A bounded UTF-8 preview can stop in the middle of a multibyte character.
    while !isempty(bytes) && !isvalid(String(copy(bytes)))
        pop!(bytes)
    end
    !isempty(bytes) && last(bytes)==0x0d && pop!(bytes)
    return String(bytes)*(cursor.shortened ? JOB_LOG_TRUNCATED : "")
end

function drain_child_log!(parent::JfemJob,child::JfemJob,cursor::JobDiskCursor;final=false)
    isfile(child.logpath) || return 0
    data=open(child.logpath,"r") do io
        seek(io,cursor.offset)
        read(io,JOB_LOG_BATCH_BYTES)
    end
    cursor.offset+=length(data)
    isempty(data) && !final && return 0
    prefix="[Case $(child.case_id), SOL$(child.model.params["output.solution"])] "
    lock(parent.lk) do
        open(parent.logpath,"a") do io
            start=1
            while start<=length(data)
                ending=findnext(==(0x0a),data,start)
                stop=ending===nothing ? length(data) : ending
                if cursor.line_start
                    print(io,prefix);cursor.line_start=false
                end
                write(io,view(data,start:stop))
                preview_stop=ending===nothing ? stop : stop-1
                room=max(0,JOB_LOG_LINE_BYTES-length(cursor.preview))
                taken=min(room,max(0,preview_stop-start+1))
                taken>0 && append!(cursor.preview,view(data,start:start+taken-1))
                taken<preview_stop-start+1 && (cursor.shortened=true)
                if ending!==nothing
                    retain_job_line!(parent,prefix*disk_preview(cursor))
                    empty!(cursor.preview);cursor.shortened=false;cursor.line_start=true
                end
                start=stop+1
            end
            if final && isempty(data) && !cursor.line_start
                println(io)
                retain_job_line!(parent,prefix*disk_preview(cursor))
                empty!(cursor.preview);cursor.shortened=false;cursor.line_start=true
            end
        end
        trim_job_log!(parent)
    end
    return length(data)
end

"""Freeze each physical case in a separate deck when mass varies between cases.

CONM2 is a bulk property and cannot vary by SUBCASE. SOL106 additionally pairs
each case with a matching SOL101 baseline, using the same fuel mass in both.
"""
function prepare_jfem_case_jobs(model::Model,params::AbstractDict,root::AbstractString,
                                 bdf::AbstractString,id::AbstractString)
    parent=prepare_jfem_job(model,params,root,bdf,id)
    comparison=String(params["output.solution"])=="106"
    solutions=comparison ? ("101","106") : (String(params["output.solution"]),)
    description=comparison ? "Paired SOL101 / SOL106" : "SOL$(params["output.solution"]) with separate fuel mass states"
    parent.cmdline="$description: $(length(load_case_specs(params))) physical load cases"
    parent.started=time(); parent.state=:running
    for spec in case_loads(model), solution in solutions
        child_params=copy(spec.params)
        child_params["output.solution"]=solution
        child_params["loads.label"]=spec.label
        child_params["loads.cases"]=Any[]
        child_model=Model((field===:params ? child_params : getfield(model,field) for field in fieldnames(Model))...)
        directory=joinpath(parent.outdir,"case_$(spec.id)","SOL$solution")
        # Keep generated source decks beside the parent's manifest, then the
        # prepared child owns its immutable snapshot inside its result folder.
        source=joinpath(parent.outdir,"case_$(spec.id)_SOL$solution.bdf")
        frozen=[(id=1,label=spec.label,params=child_params,loads=spec.loads)]
        write_reference(child_model,source;frozen_load_cases=frozen,comparison)
        child=prepare_jfem_job(child_model,child_params,root,source,"$(id)_$(spec.id)_$solution";outdir=directory)
        child.case_id=spec.id; child.case_label=spec.label
        push!(parent.runs,child)
    end
    write_job_manifest(parent)
    return parent
end

# Retain the existing entry point for callers and archived regression tools.
prepare_jfem_comparison(args...)=prepare_jfem_case_jobs(args...)

function job_run_summary(job::JfemJob)
    Dict{String,Any}("id"=>job.id,"case_id"=>job.case_id,"case_label"=>job.case_label,
        "solution"=>String(job.model.params["output.solution"]),"state"=>String(job.state),
        "fuel_percent"=>fuel_case_percent(job.model.params),
        "message"=>job.message,"seconds"=>round(job_seconds(job);digits=2),"exit_code"=>job.exitcode,
        "deck"=>job.bdf,"out_dir"=>job.outdir,"log_path"=>job.logpath,
        "progress"=>job_progress(job),"timings"=>job_timings(job))
end

function write_job_manifest(job::JfemJob)
    isempty(job.runs) && return
    comparison=String(job.model.params["output.solution"])=="106"
    data=Dict("job"=>job.id,"state"=>String(job.state),"message"=>job.message,
        "comparison"=>comparison,"per_case_fuel_mass"=>fuel_states_differ(job.model),
        "shared_numerical_parameters"=>comparison ? Dict("K6ROT"=>COMPARISON_K6ROT) : Dict(),
        "runs"=>[job_run_summary(child) for child in job.runs])
    open(joinpath(job.outdir,comparison ? "comparison_manifest.json" : "case_manifest.json"),"w") do io
        JSON.print(io,data,2)
    end
end

"""A follower SOL101 baseline must be solved again at a partial accepted load.

Its load stiffness changes with load magnitude, so scaling the full-load
solution would not satisfy the first-order equilibrium equations.
"""
function prepare_partial_follower_baseline!(parent::JfemJob, nonlinear::JfemJob)
    nonlinear.model.params["output.solution"]=="106" || return nothing
    get(nonlinear.model.params,"loads.follower_forces",false)===true || return nothing
    nonlinear.state===:failed && !nonlinear.cancel_requested || return nothing
    parent.cancel_requested && return nothing
    any(run->run.case_id==nonlinear.case_id && get(run.progress,"comparison_role","")=="accepted_load_linear_baseline",parent.runs) && return nothing
    path,data=find_results_json(nonlinear.outdir)
    path===nothing && return nothing
    convergence=nonlinear_case_convergence(data,1)
    get(convergence,"available",false)===true && get(convergence,"partial",false)===true || return nothing
    selected=static_case_result(data,1,[1])
    validate_static_result_coverage(nonlinear.model,selected)
    scale=Float64(convergence["exported_load_scale"])
    params=copy(nonlinear.model.params)
    params["output.solution"]="101"
    params["loads.load_factor"]=Float64(params["loads.load_factor"])*scale
    model=Model((field===:params ? params : getfield(nonlinear.model,field) for field in fieldnames(Model))...)
    source=joinpath(parent.outdir,"case_$(nonlinear.case_id)_lin_part.bdf")
    write_reference(model,source;comparison=true)
    child=prepare_jfem_job(model,params,parent.repo,source,"$(parent.id)_$(nonlinear.case_id)_101_partial";
        outdir=joinpath(parent.outdir,"case_$(nonlinear.case_id)","S101_L"))
    child.case_id=nonlinear.case_id;child.case_label=nonlinear.case_label
    child.progress["comparison_role"]="accepted_load_linear_baseline"
    child.progress["comparison_load_scale"]=scale
    child.progress["nonlinear_source_job"]=nonlinear.id
    push!(parent.runs,child)
    append_job_lines!(parent,["[Comparison] Case $(child.case_id): solving a new SOL101 follower baseline at $(round(100scale;digits=4))% load; the full-load deck and result are retained."])
    return child
end

"""Sequential isolated runs; an individual failure never discards other cases."""
function run_jfem_comparison!(parent::JfemJob; runner=launch_jfem_process!)
    try
        for child in parent.runs
            parent.cancel_requested && break
            prefix="[Case $(child.case_id), SOL$(child.model.params["output.solution"])] "
            append_job_lines!(parent,[prefix*"Starting $(child.case_label); output $(child.outdir)"])
            try
                runner(child)
            catch e
                child.state=:failed; child.message=sprint(showerror,e); child.finished=time()
            end
            cursor=JobDiskCursor()
            while child.state === :running || (child.proc!==nothing && !child.log_done)
                drain_child_log!(parent,child,cursor)
                sleep(0.1)
            end
            if isfile(child.logpath)
                while drain_child_log!(parent,child,cursor;final=true)>0
                    yield()
                end
            else
                # Compatibility with injected in-memory runners and archived
                # fixtures. Actual processes always stream their disk log.
                seen=0
                while true
                    batch=job_log_batch(child,seen)
                    append_job_lines!(parent,[prefix*line for line in batch.lines])
                    seen=batch.next_line
                    batch.has_more || break
                end
            end
            append_job_lines!(parent,[prefix*String(child.state)*": "*child.message])
            try
                prepare_partial_follower_baseline!(parent,child)
            catch error
                append_job_lines!(parent,[prefix*"Matching-load linear baseline could not be prepared: "*sprint(showerror,error)])
            end
            write_job_manifest(parent)
        end
        if !parent.cancel_requested
            done=count(child->child.state===:done,parent.runs)
            parent.state=done==length(parent.runs) ? :done : done>0 ? :partial : :failed
            parent.message="$done of $(length(parent.runs)) solver runs completed successfully"
            failures=[child for child in parent.runs if child.state!==:done]
            if !isempty(failures)
                details=["Case $(child.case_id), SOL$(child.model.params["output.solution"]): "*
                    (isempty(child.message) ? String(child.state) : child.message) for child in failures]
                parent.message*=". "*join(details,"; ")
            end
            parent.exitcode=parent.state===:done ? 0 : 1
        end
    catch e
        kill_job!(parent;message=sprint(showerror,e),state=:failed)
        parent.exitcode=1
    finally
        parent.finished=time()
        try
            write_job_manifest(parent)
        finally
            parent.log_done=true
        end
    end
    return parent
end

function start_jfem_comparison(model,params,root,bdf,id)
    parent=prepare_jfem_comparison(model,params,root,bdf,id)
    Threads.@spawn run_jfem_comparison!(parent)
    return parent
end

# --- reading the results ---------------------------------------------------

"""
    find_results_json(outdir) -> (path, dict)

The results JSON written by the solver. The file is named after the solution
sequence (`.JU.JSON` for SOL 101, `.BUCKLING.JSON` for SOL 103), so it is
found by content: a JSON carrying `analysis_type` and actual result arrays.
SOL106's separate NONLINEAR.JSON contains diagnostics, not nodal results.
"""
function find_results_json(outdir::AbstractString)
    isdir(outdir) || return (nothing, nothing)
    # The buckling-files manifest has analysis_type too, but no result arrays.
    files = filter(f -> endswith(uppercase(f), ".JSON") &&
                        !endswith(uppercase(f), ".BUCKLING_FILES.JSON"), readdir(outdir))
    for f in sort(files)
        endswith(uppercase(f), ".JSON") || continue
        path = joinpath(outdir, f)
        d = try
            JSON.parse(read(path, String))
        catch
            continue
        end
        d isa AbstractDict && haskey(d, "analysis_type") || continue
        (any(key -> haskey(d, key), ("displacements", "modes", "static_displacements")) ||
            startswith(string(d["analysis_type"]),"SOL105")&&compact_buckling_output(d)&&haskey(d,"eigenvalues")) || continue
        return (path, d)
    end
    return (nothing, nothing)
end

"""Verify full convergence or an explicitly identified last accepted checkpoint.

Legacy files may contain a failed iterate despite a positive final_load_scale.
Partial recovery therefore requires the new accepted-checkpoint marker and its
matching accepted history record and residual. Full-run status remains separate.
"""
function nonlinear_case_convergence(d::AbstractDict, sid::Int)
    finite(value) = value isa Real && !(value isa Bool) && isfinite(value) ? Float64(value) : nothing
    rows = get(d, "nonlinear_diagnostics", nothing)
    matched = rows isa AbstractVector ?
        [row for row in rows if row isa AbstractDict && get(row, "sid", nothing) isa Integer &&
            !(row["sid"] isa Bool) && row["sid"] == sid] : Any[]
    details = length(matched) == 1 ? get(only(matched), "details", nothing) : nothing
    result = Dict{String,Any}("available" => false, "partial" => false, "converged" => false, "full_load" => false,
        "final_load_scale" => nothing, "exported_load_scale" => nothing,
        "termination_reason" => "missing_or_ambiguous_diagnostics", "requested_steps" => nothing,
        "accepted_steps" => 0, "final_relative_residual" => nothing, "steps" => Any[],
        "message" => "SOL106 has no unique convergence record for native subcase $sid; its shape is unavailable.")
    details isa AbstractDict || return result
    history = get(details, "load_steps", nothing)
    steps = history isa AbstractVector ? [row for row in history if row isa AbstractDict] : Any[]
    last_step = isempty(steps) ? Dict{String,Any}() : last(steps)
    scale = finite(get(details, "final_load_scale", nothing))
    marked=haskey(details,"exported_state_kind")
    exported_scale = finite(get(marked ? details : last_step,marked ? "exported_load_scale" : "load_scale",nothing))
    reason = get(details, "termination_reason", "unknown")
    reason = reason isa AbstractString ? String(reason) : "unknown"
    converged = get(details, "converged", false) === true
    valid_history = history isa AbstractVector && !isempty(history) && length(steps) == length(history)
    scales = [finite(get(row,"load_scale",nothing)) for row in steps]
    valid_history &= all(value -> value !== nothing && 0 < value <= 1 + 1e-10,scales)
    valid_history && (valid_history = all(i -> scales[i] > scales[i-1],2:length(scales)))
    full = scale !== nothing && abs(scale - 1.0) <= 1e-10
    accepted = valid_history && all(row -> get(row, "accepted", false) === true &&
        get(row, "converged", false) === true, steps)
    final_accepted = accepted && exported_scale !== nothing && abs(exported_scale - 1.0) <= 1e-10
    residual = finite(get(details,"final_relative_residual",nothing))
    residual_tolerance = finite(get(details,"residual_tolerance",nothing))
    residual_ok = residual !== nothing && residual_tolerance !== nothing &&
        0 <= residual < residual_tolerance
    full_available = converged && full && final_accepted && residual_ok && reason == "full_load_converged"
    accepted_index=findlast(row->get(row,"accepted",false)===true && get(row,"converged",false)===true,steps)
    exported_index=get(details,"exported_step",nothing)
    exported_residual=finite(get(details,"exported_relative_residual",nothing))
    checkpoint=false
    if marked && valid_history && accepted_index!==nothing && exported_index isa Integer &&
       !(exported_index isa Bool) && exported_index==accepted_index &&
       get(details,"exported_state_kind",nothing)=="accepted_checkpoint" &&
       get(details,"exported_state_accepted",false)===true &&
       scale!==nothing && exported_scale!==nothing && 0<scale<=1 &&
       isapprox(scale,exported_scale;rtol=0,atol=1e-12) &&
       isapprox(scale,scales[accepted_index];rtol=0,atol=1e-12)
        saved_residual=finite(get(steps[accepted_index],"final_relative_residual",nothing))
        change_tolerance=finite(get(details,"tolerance",nothing))
        increment_ok=false
        for (exported_key,history_key) in (("exported_relative_change","final_relative_change"),
                ("exported_relative_incremental_work","final_relative_incremental_work"))
            exported_value=finite(get(details,exported_key,nothing))
            saved_value=finite(get(steps[accepted_index],history_key,nothing))
            increment_ok |= change_tolerance!==nothing && exported_value!==nothing && saved_value!==nothing &&
                0<=exported_value<change_tolerance && isapprox(exported_value,saved_value;rtol=1e-9,atol=1e-15)
        end
        checkpoint=all(row->get(row,"accepted",false)===true && get(row,"converged",false)===true,
            steps[1:accepted_index]) && exported_residual!==nothing && saved_residual!==nothing &&
            residual_tolerance!==nothing && 0<=exported_residual<residual_tolerance &&
            isapprox(exported_residual,saved_residual;rtol=1e-9,atol=1e-15) && increment_ok
    end
    # A marker that disagrees with the history also invalidates a new full file.
    marked && (full_available &= checkpoint)
    partial=checkpoint && !converged && !full && reason=="cutback_exhausted" &&
        accepted_index==length(steps)-1 && get(last_step,"accepted",true)===false &&
        get(last_step,"converged",true)===false
    available=full_available || partial
    result["partial"]=partial
    result["available"], result["converged"], result["full_load"] = available, converged, full
    result["final_load_scale"], result["exported_load_scale"] = scale, exported_scale
    result["exported_state_kind"]=get(details,"exported_state_kind",full_available ? "full_load" : "unverified_iterate")
    result["exported_relative_residual"]=marked ? exported_residual : residual
    result["termination_reason"] = reason
    result["accepted_steps"] = count(row -> get(row, "accepted", false) === true, steps)
    requested = get(details, "requested_load_step_count", nothing)
    result["requested_steps"] = requested isa Integer && !(requested isa Bool) && requested > 0 ? requested : nothing
    for key in ("final_relative_residual", "final_relative_change", "residual_tolerance", "tolerance")
        result[key] = finite(get(details, key, nothing))
    end
    for key in ("scheme", "nonlinear_method", "residual_model", "correction_tangent_model")
        value = get(details, key, nothing)
        result[key] = value isa AbstractString ? String(value) : nothing
    end
    result["steps"] = [Dict{String,Any}("step" => get(row, "step", i),
        "load_scale" => finite(get(row, "load_scale", nothing)),
        "accepted" => get(row, "accepted", false) === true,
        "converged" => get(row, "converged", false) === true,
        "relative_residual" => finite(get(row, "final_relative_residual", nothing))) for (i,row) in enumerate(steps)]
    verification = !valid_history ? "invalid or missing increment history" :
        marked && !checkpoint ? "exported checkpoint metadata does not verify an accepted converged state" :
        !full ? "prescribed full load was not reached" :
        !final_accepted ? "last exported increment was not accepted and converged at full load" :
        !residual_ok ? "final residual does not verify the requested tolerance" :
        !converged || reason != "full_load_converged" ? "solver did not report full-load convergence" : "verified"
    result["verification"] = partial ? "verified last accepted checkpoint" : verification
    result["message"] = partial ?
        "SOL106 did not reach full load ($reason). Showing the verified last accepted state at $(eng(100exported_scale))% of prescribed load." : full_available ? "Full prescribed load converged." :
        "SOL106 is incomplete: $verification ($reason). Last accepted load fraction: $(scale === nothing ? "unknown" : eng(scale)); the exported attempted iterate is not shown."
    return result
end

"""Explicit model support reactions in BASIC coordinates; omit AUTOSPC elsewhere."""
function support_reactions_payload(m::Model,d::AbstractDict;native_sid=nothing)
    rows=get(d,"spc_forces",nothing)
    idx=grid_index_map(m);supports=Set(m.spc)
    # Reactions belong to the solved static subcase, including a SOL105
    # STATSUB preload. The importer facade contains a union of all SPC sets;
    # it must not admit AUTOSPC reactions at another case's explicit supports.
    sid=get(d,"static_subcase_id",native_sid)
    if sid!==nothing&&is_imported_model(m)
        cases=get(m.params,"imported.cases",Any[])
        mapping=get(m.params,"imported.analysis_cases",Dict{Int,Int}())
        selected=findfirst(row->Int(row["id"])==Int(sid),cases)
        selected===nothing&&(selected=findfirst(row->get(mapping,Int(row["id"]),Int(row["id"]))==Int(sid),cases))
        if selected!==nothing&&haskey(cases[selected],"spc")
            supports=Set(Int(entry["node"])+1 for entry in get(cases[selected]["spc"],"assignments",Any[]))
        end
    end
    nodes=Int[];ids=Int[];forces=Float64[];moments=Float64[]
    seen=Set{Int}()
    for row in (rows isa AbstractVector ? rows : Any[])
        row isa AbstractDict || continue
        gid=get(row,"grid_id",nothing)
        gid isa Integer && !(gid isa Bool) || continue
        node=get(idx,Int(gid),0)
        node in supports || continue
        node in seen && throw(ArgumentError("duplicate SPC reaction at GRID $gid"))
        values=[get(row,key,nothing) for key in ("t1","t2","t3","r1","r2","r3")]
        all(x->x isa Real && !(x isa Bool) && isfinite(x) && isfinite(Float32(x)),values) ||
            throw(ArgumentError("missing or nonfinite SPC reaction at GRID $gid"))
        push!(seen,node);push!(nodes,node);push!(ids,Int(gid))
        append!(forces,values[1:3]);append!(moments,values[4:6])
    end
    requested=get(get(d,"result_requests",Dict()),"SPCFORCES",true)===true
    available=requested&&!isempty(nodes)
    reason=!requested ? "SPCFORCES was suppressed for this static subcase. Request SPCFORCES and rerun to display reactions." :
        !(rows isa AbstractVector) ? "This result did not export SPC reaction forces." :
        isempty(nodes) ? "No exported reactions belong to explicit modeled constrained nodes." : ""
    return Dict{String,Any}("available"=>available,"reason"=>reason,"frame"=>"BASIC",
        "count"=>length(nodes),"nodes"=>blob_i32(nodes;offset=-1),"node_ids"=>blob_i32(ids),
        "forces"=>blob_f32(forces),"moments"=>blob_f32(moments),
        "units"=>Dict("force"=>"N","moment"=>"N m"),
        "note"=>"Constraint reaction on structure, BASIC XYZ. Explicit modeled constrained nodes only; AUTOSPC reactions at other nodes are excluded.")
end

"""Scale this generator's linear zero-SPC response, preserving IDs and fibers."""
function scaled_linear_result(d::AbstractDict,scale::Real)
    isfinite(scale) && 0<scale<=1 || throw(ArgumentError("linear comparison load scale must be in (0,1]"))
    result=deepcopy(d)
    mechanical=Set(["t1","t2","t3","r1","r2","r3","normal_x","normal_y","shear_xy",
        "von_mises","major","minor","axial","axial_end_a","axial_end_b","torsional",
        "fx","fy","fxy","mx","my","mxy","qx","qy","shear_1","shear_2","torque",
        "moment_a1","moment_a2","moment_b1","moment_b2","p1","p2","p3","p4","p5","p6","p7","p8",
        "e1","e2","g12","s1","s2","t12"])
    function scale_values!(value)
        if value isa AbstractDict
            for (key,item) in value
                if key in mechanical && item isa Real && !(item isa Bool)
                    value[key]=Float64(item)*scale
                else
                    scale_values!(item)
                end
            end
        elseif value isa AbstractVector
            foreach(scale_values!,value)
        end
    end
    for key in ("displacements","spc_forces","stresses","strains","forces","forces_bilin")
        haskey(result,key) && scale_values!(result[key])
    end
    return result
end

"""Require every model GRID exactly once before publishing a static comparison."""
function validate_static_result_coverage(m::Model, d::AbstractDict)
    rows = get(d, "displacements", nothing)
    rows isa AbstractVector || throw(ArgumentError("static nodal displacements are unavailable"))
    length(rows) == length(m.node_ids) || throw(ArgumentError("static displacement node coverage is incomplete"))
    ids = Int[]
    for row in rows
        row isa AbstractDict || throw(ArgumentError("invalid static displacement record"))
        gid = get(row, "grid_id", nothing)
        gid isa Integer && !(gid isa Bool) || throw(ArgumentError("invalid static displacement GRID ID"))
        push!(ids, gid)
        for key in ("t1", "t2", "t3", "r1", "r2", "r3")
            value = get(row, key, startswith(key, "r") ? 0.0 : nothing)
            value isa Real && !(value isa Bool) && isfinite(value) && isfinite(Float32(value)) ||
                throw(ArgumentError("missing or nonfinite static $key at GRID $gid"))
        end
    end
    length(unique(ids)) == length(ids) && Set(ids) == Set(m.node_ids) ||
        throw(ArgumentError("static displacement GRID IDs do not match this model"))
    return nothing
end

"""
    find_report_md(outdir) -> Union{String,Nothing}

The markdown report written by the solver.
"""
function find_report_md(outdir::AbstractString)
    isdir(outdir) || return nothing
    for f in sort(readdir(outdir))
        endswith(uppercase(f), "REPORT.MD") && return joinpath(outdir, f)
    end
    return nothing
end

"""
    grid_index_map(model) -> Dict{Int,Int}

Map from REFERENCE grid id to the index of that node in the model arrays, which
is the index the browser uses in its vertex buffers.
"""
grid_index_map(m::Model) = Dict{Int,Int}(id => i for (i, id) in enumerate(m.node_ids))

fnum(x, default = 0.0) = x === nothing ? default : Float64(x)

"""
    gather_translations(entries, idx, n) -> (Vector{Float32}, Float64)

Scatter a list of `{grid_id, t1, t2, t3}` records into a flat 3N translation
vector ordered like the model nodes, returning the vector and the largest
magnitude found.
"""
function gather_translations(entries, idx::Dict{Int,Int}, n::Int)
    v = zeros(Float32, 3n)
    mx = 0.0
    for e in entries
        gid = get(e, "grid_id", nothing)
        gid === nothing && continue
        i = get(idx, Int(gid), 0)
        i == 0 && continue
        t1 = fnum(get(e, "t1", 0.0))
        t2 = fnum(get(e, "t2", 0.0))
        t3 = fnum(get(e, "t3", 0.0))
        v[3i-2] = t1
        v[3i-1] = t2
        v[3i] = t3
        mx = max(mx, sqrt(t1^2 + t2^2 + t3^2))
    end
    return v, mx
end

"""Basic-coordinate nodal rotation vectors, in radians, for section displays."""
function gather_rotations(entries, idx::Dict{Int,Int}, n::Int)
    v = zeros(Float32, 3n)
    for row in entries
        gid = get(row, "grid_id", nothing)
        gid isa Integer || continue
        i = get(idx, Int(gid), 0)
        i == 0 && continue
        for a in 1:3
            v[3i-3+a] = fnum(get(row, "r$a", 0.0))
        end
    end
    return v
end

"""
    nodal_von_mises(model, stresses) -> (Vector{Float32}, Float64)

Nodal von Mises stress contour, averaged from the shell element values. Each
CQUAD4 or CTRIA3 contributes the larger of its two fibre values to its corners.
"""
function nodal_von_mises(m::Model, stresses)
    n = length(m.node_ids)
    acc = zeros(Float64, n)
    cnt = zeros(Int, n)
    by_eid = Dict{Int,Float64}()
    for key in ("quad4", "tria3")
        for q in get(stresses, key, Any[])
            eid = get(q, "eid", nothing)
            eid === nothing && continue
            best = 0.0
            for z in ("z1", "z2")
                zz = get(q, z, nothing)
                zz === nothing && continue
                best = max(best, abs(fnum(get(zz, "von_mises", 0.0))))
            end
            by_eid[Int(eid)] = best
        end
    end
    isempty(by_eid) && return (zeros(Float32, n), 0.0)
    for gr in m.groups
        gr.kind in (:quad, :tria) || continue
        corners = gr.kind === :quad ? 4 : 3
        for (k, eid) in enumerate(gr.eids)
            v = get(by_eid, eid, nothing)
            v === nothing && continue
            for t in 1:corners
                i = gr.conn[corners*(k-1)+t]
                acc[i] += v
                cnt[i] += 1
            end
        end
    end
    out = Vector{Float32}(undef, n)
    mx = 0.0
    for i in 1:n
        val = cnt[i] > 0 ? acc[i] / cnt[i] : 0.0
        out[i] = val
        mx = max(mx, val)
    end
    return out, mx
end

"""
    bar_axial_range(stresses) -> (min, max)

Range of CBAR axial stress, reported alongside the shell contour.
"""
function bar_axial_range(stresses)
    lo = Inf
    hi = -Inf
    for b in get(stresses, "cbar", Any[])
        a = fnum(get(b, "axial", 0.0))
        lo = min(lo, a)
        hi = max(hi, a)
    end
    return isfinite(lo) ? (lo, hi) : (0.0, 0.0)
end

# Native JFEM FORCE output contains section resultants in geometric element
# axes. The generator rotates these to the explicit skin/spar/rib MCID.
# The solver's fx/fy/fxy are membrane forces per unit length, mx/my/mxy
# are moments per unit length, and qx/qy are transverse shears per unit length.
# These are distinct from the nodal applied forces and SPC reactions.
const SHELL_FORCE_FIELDS = (
    ("fx", "Shell Nx", "N/m"), ("fy", "Shell Ny", "N/m"),
    ("fxy", "Shell Nxy", "N/m"), ("mx", "Shell Mx", "N m/m"),
    ("my", "Shell My", "N m/m"), ("mxy", "Shell Mxy", "N m/m"),
    ("qx", "Shell Qx", "N/m"), ("qy", "Shell Qy", "N/m"),
)
const SHELL_STRESS_FIELDS = (
    ("normal_x", "Shell stress x"), ("normal_y", "Shell stress y"),
    ("shear_xy", "Shell stress xy"),
)
const BAR_FORCE_FIELDS = (
    ("axial", "Bar axial force", "N"),
    ("shear_1", "Bar shear 1", "N"), ("shear_2", "Bar shear 2", "N"),
    ("torque", "Bar torque", "N m"),
    ("moment_a1", "Bar moment A1", "N m"),
    ("moment_a2", "Bar moment A2", "N m"),
    ("moment_b1", "Bar moment B1", "N m"),
    ("moment_b2", "Bar moment B2", "N m"),
)

"""Populate missing plane-stress principals from physical tensor components."""
function complete_shell_principals!(stress::AbstractDict)
    for face in ("z1", "z2")
        s = get(stress, face, nothing)
        s isa AbstractDict || continue
        all(k -> get(s, k, nothing) isa Real,
            ("normal_x", "normal_y", "shear_xy")) || continue
        xx, yy, xy = Float64.((s["normal_x"], s["normal_y"], s["shear_xy"]))
        all(isfinite, (xx, yy, xy)) || continue
        center = xx / 2 + yy / 2
        radius = hypot(xx / 2 - yy / 2, xy)
        get(s, "major", nothing) isa Real || (s["major"] = center + radius)
        get(s, "minor", nothing) isa Real || (s["minor"] = center - radius)
    end
    return stress
end

"""Recover T-section bending stress at its actual polygon vertices.

JFEM's PBARL T parser supplies stiffness but no C/D/E/F recovery points, so
its native end-point bending stresses are zero placeholders. Use its recovered
end moments with the same signed CBAR convention instead. Axial stays separate.
"""
function complete_stringer_stresses!(m::Model, records::AbstractDict)
    for gr in m.groups
        if is_imported_model(m)
            gr.kind===:bar||continue
            section=imported_properties(imported_native(m),gr)["section"]
            get(section,"shape","")=="T"&&haskey(section,"polygon_yz_m")||continue
        else
            component_base_pid(gr.pid) in (PID_STRINGER,PID_RIB_STIFFENER) || continue
            section = section_definition(m.params, gr.pid)
        end
        points = section["polygon_yz_m"]
        for eid in gr.eids
            record = get(records, string(eid), nothing)
            record === nothing && continue
            stress = get(record, "stress", nothing)
            stress isa AbstractDict || continue
            forces = get(record, "forces", Dict())
            for ending in ("a", "b")
                name = "end_" * ending
                m1, m2 = get(forces, "moment_$(ending)1", nothing), get(forces, "moment_$(ending)2", nothing)
                if m1 isa Real && m2 isa Real && isfinite(m1) && isfinite(m2)
                    stress[name] = Dict("p$i" => -(m1*yz[1]/section["I1_m4"] +
                        m2*yz[2]/section["I2_m4"]) for (i,yz) in enumerate(points))
                else
                    pop!(stress, name, nothing)
                end
            end
            record["section_recovery_points_yz_m"] = points
            record["stress_units"] = "Pa; end_a/end_b are bending stresses at T polygon vertices p1-p8; add axial for total normal stress"
        end
    end
    return records
end

"""Total beam normal-stress extreme at one end, requiring complete recovery.

JFEM stores axial stress separately from its end-point bending stresses. The
eight T polygon vertices or four square-cap corners contain the extrema of
their linear normal-stress fields; incomplete recovery remains unavailable.
"""
function bar_normal_extreme(record::AbstractDict, ending::AbstractString, extreme)
    stress = get(record, "stress", nothing)
    stress isa AbstractDict || return nothing
    axial = get(stress, "axial", nothing)
    axial isa Real && isfinite(axial) || return nothing
    bending = get(stress, "end_" * ending, nothing)
    bending isa AbstractDict || return nothing
    count = haskey(record, "section_recovery_points_yz_m") ?
        length(record["section_recovery_points_yz_m"]) : 4
    points = [get(bending, "p$i", nothing) for i in 1:count]
    all(v -> v isa Real && isfinite(v), points) || return nothing
    return axial + extreme(points)
end

"""Attach native centroidal solid stresses using original volume element IDs."""
function append_solid_results_payload!(contours, records, m::Model, results::AbstractDict)
    is_imported_model(m) || return
    solids = get(imported_native(m), "CSOLIDs", Dict())
    isempty(solids) && return
    supported = Dict(Int(element["ID"]) => String(element["TYPE"]) for element in values(solids))
    source = get(results, "stresses", nothing)
    source isa AbstractDict || return
    values_by_eid = Dict{Int,Float64}()
    for (family, card) in (("ctetra", "CTETRA"), ("chexa", "CHEXA"), ("cpenta", "CPENTA"))
        for row in get(source, family, Any[])
            row isa AbstractDict || continue
            eid = get(row, "eid", nothing)
            eid isa Integer && !(eid isa Bool) || continue
            get(supported, Int(eid), nothing) == card || continue
            value = get(row, "von_mises", nothing)
            value isa Real && !(value isa Bool) && isfinite(value) && value >= 0 && isfinite(Float32(value)) || continue
            haskey(values_by_eid, Int(eid)) && throw(ArgumentError("Duplicate centroidal solid stress for element $eid"))
            haskey(records, string(eid)) && throw(ArgumentError("Solid stress element $eid conflicts with another element family"))
            records[string(eid)] = Dict{String,Any}(
                "type" => card, "coordinate_system" => "Native solid centroid recovery axes",
                "stress" => Dict{String,Any}(string(key) => deepcopy(item) for (key, item) in row if key != "eid"),
                "stress_location" => "element centroid", "stress_units" => "Pa")
            values_by_eid[Int(eid)] = Float64(value)
        end
    end
    isempty(values_by_eid) && return
    ids = sort!(collect(keys(values_by_eid)))
    contour_values = [values_by_eid[eid] for eid in ids]
    push!(contours, Dict{String,Any}("name" => "Solid von Mises stress", "unit" => "Pa",
        "location" => "element", "domain" => "solid", "ids" => blob_i32(ids),
        "values" => blob_f32(contour_values), "min" => minimum(contour_values), "max" => maximum(contour_values),
        "note" => "Centroidal von Mises stress of each original volume element, constant on its displayed exterior faces. No averaging between elements; missing recovery stays unavailable."))
    return
end

"""
    element_results_payload(model, results) -> (contours, element_results)

Keep each shell/bar/solid's recovered values on its own EID. No values are shared
or averaged between adjacent elements; missing results stay absent, never zero.
"""
function element_results_payload(m::Model, results::AbstractDict)
    supported = Dict{Int,Symbol}(eid => gr.kind for gr in m.groups for eid in gr.eids)
    coordinate_systems = Dict(eid => (gr.kind === :bar ? "CBAR local section axes" : is_imported_model(m) ? "Native geometric shell element axes" :
        shell_material_description(gr)) for gr in m.groups for eid in gr.eids)
    frame_path = stringer_path(m.grid.wing, m.params)
    rotations = Dict(gr.eids[e] => shell_result_rotation(m, gr, e; path=frame_path)
                     for gr in m.groups if gr.kind !== :bar for e in 1:n_elements(gr))
    records = Dict{String,Any}()
    for (source_key, target_key) in (("stresses", "stress"), ("strains", "strain"), ("forces", "forces"))
        source = get(results, source_key, nothing)
        source isa AbstractDict || continue
        for (family, kind, card) in (("quad4", :quad, "CQUAD4"),
                                     ("tria3", :tria, "CTRIA3"),
                                     ("cbar", :bar, "CBAR"))
            for row in get(source, family, Any[])
                row isa AbstractDict || continue
                eid = get(row, "eid", nothing)
                eid isa Integer || continue
                get(supported, Int(eid), :unknown) === kind || continue
                data = Dict{String,Any}(string(k) => deepcopy(v)
                                       for (k, v) in row if k != "eid")
                if kind !== :bar
                    target_key == "stress" && complete_shell_principals!(data)
                    c, s = rotations[Int(eid)]
                    rotate_shell_results!(data, target_key, c, s)
                end
                record = get!(records, string(eid)) do
                    Dict{String,Any}("type" => card, "coordinate_system" => coordinate_systems[Int(eid)])
                end
                record[target_key] = data
                if target_key == "forces"
                    fields = kind === :bar ? BAR_FORCE_FIELDS : SHELL_FORCE_FIELDS
                    record["force_units"] = Dict(k => unit for (k, _, unit) in fields if haskey(data, k))
                elseif target_key == "stress"
                    record["stress_units"] = "Pa; fiber_dist in m"
                else
                    record["strain_units"] = kind === :bar ? "Engineering strain (dimensionless)" :
                        "Engineering strain (dimensionless); legacy z1 is membrane strain, z2 is negative curvature (1/m). ply_faces are explicit bottom/top strains in each ply's material axes."
                end
            end
        end
    end

    complete_stringer_stresses!(m, records)
    contours = Any[]
    # Iterate model order, which is also the group/picking order. EIDs travel
    # explicitly because some families may have no output or non-contiguous IDs.
    function add_contour(name, unit, kinds, getter; pids=nothing, note=nothing)
        ids = Int[]
        values = Float64[]
        for gr in m.groups
            gr.kind in kinds || continue
            pids === nothing || is_imported_model(m) || component_base_pid(gr.pid) in pids || continue
            for eid in gr.eids
                record = get(records, string(eid), nothing)
                record === nothing && continue
                value = getter(record)
                value isa Real && isfinite(value) && isfinite(Float32(value)) || continue
                push!(ids, eid)
                push!(values, Float64(value))
            end
        end
        isempty(values) && return
        contour = Dict{String,Any}("name" => name, "unit" => unit,
            "location" => "element", "domain" => (kinds == (:bar,) ? "bar" : "shell"),
            "ids" => blob_i32(ids), "values" => blob_f32(values),
            "min" => minimum(values), "max" => maximum(values))
        note === nothing || (contour["note"] = note)
        push!(contours, contour)
    end
    nested(record, path...) = foldl((d, key) -> d isa AbstractDict ? get(d, key, nothing) : nothing,
                                   path; init = record)
    add_contour("Von Mises stress", "Pa", (:quad, :tria), record -> begin
        values = [nested(record, "stress", face, "von_mises") for face in ("z1", "z2")]
        finite = [v for v in values if v isa Real && isfinite(v)]
        isempty(finite) ? nothing : maximum(abs, finite)
    end)
    for (component, label) in (("major", "Major principal stress"), ("minor", "Minor principal stress")),
        face in ("z1", "z2")
        add_contour("$label ($face)", "Pa", (:quad, :tria),
                    record -> nested(record, "stress", face, component))
    end
    for (component,label) in SHELL_STRESS_FIELDS, face in ("z1","z2")
        side = face == "z1" ? "negative" : "positive"
        add_contour("$label (local, $face)", "Pa", (:quad,:tria),
            record -> nested(record,"stress",face,component);
            note="Signed stress in the element material axes shown by the shell-axis arrows. $face is the $side local-z thickness face, not the lifting surface's lower/upper skin. Each element retains its own value; no nodal averaging.")
    end
    add_contour("Bar axial stress", "Pa", (:bar,), record -> nested(record, "stress", "axial"))
    for ending in ("a", "b"), (label, extreme) in (("max", maximum), ("min", minimum))
        add_contour("Bar normal stress $label ($(uppercase(ending)))", "Pa", (:bar,),
            record -> bar_normal_extreme(record, ending, extreme);
            pids=(PID_STRINGER, PID_SPAR_CAP, PID_RIB_STIFFENER),
            note="Axial plus bending normal stress at section vertices, positive in tension. T stringers, rib stiffeners and square spar caps; runout connectors have no specified bending recovery points.")
    end
    for (fields, kinds) in ((SHELL_FORCE_FIELDS, (:quad, :tria)), (BAR_FORCE_FIELDS, (:bar,)))
        for (key, name, unit) in fields
            add_contour(name, unit, kinds, record -> nested(record, "forces", key))
        end
    end
    append_solid_results_payload!(contours, records, m, results)
    return contours, records
end

function eng(x::Real; digits::Int=4)
    precision=abs(x)>=100 ? min(digits,2) : digits
    return abs(x)>=1.0e5 || (x!=0 && abs(x)<1.0e-3) ?
        Printf.format(Printf.Format("%.$(precision)e"),Float64(x)) :
        string(round(Float64(x);digits=precision))
end

"""
    jfem_results_payload(job) -> Dict

Read the solver output and build the MsgPack payload for the viewer. Mode
shapes and contours are re-indexed onto the model node ordering and carried as
little-endian Float32 blobs, the same convention as the mesh payload.
"""
function jfem_case_results_payload(job::JfemJob, path::AbstractString, d::AbstractDict; native_sid::Int=1)
    m = job.model
    idx = grid_index_map(m)
    n = length(m.node_ids)
    atype = String(get(d, "analysis_type", "UNKNOWN"))
    summary = Any[]
    push!(summary, Any["Analysis", atype])
    push!(summary, Any["Solver", string(get(d, "backend", "jfem"), " ",
                                        get(d, "backend_version", ""))])
    push!(summary, Any["Wall time", eng(job_seconds(job); digits = 1) * " s"])
    timing=job_timings(job)
    if timing["available"]
        for (label,key) in (("Run solution time (compilation excluded)","solution_seconds"),
                            ("Julia compilation in analysis stages","compilation_seconds"),
                            ("Deck and model preparation","preparation_seconds"),
                            ("Result export","export_seconds"),
                            ("Startup, package loading/precompilation and overhead","startup_overhead_seconds"))
            push!(summary,Any[label,eng(timing[key];digits=3)*" s"])
        end
    end
    push!(summary, Any["Nodes in results", string(n)])

    modes = Any[]
    buckling_roots = Any[]
    contours = Any[]
    element_results = Dict{String,Any}()
    static = nothing
    reactions = nothing
    available, status, message = true, "complete", ""
    convergence = startswith(atype, "SOL106") ? nonlinear_case_convergence(d, native_sid) : nothing
    # How the eigenvalues of this run should be read and labelled.
    mode_kind = startswith(atype, "SOL103") ? "frequency" :
                startswith(atype, "SOL105") ? "buckling" : "none"
    compact=mode_kind=="buckling"&&compact_buckling_output(d)
    if compact
        message="Compact SOL105 output: eigenvalues and peak-translation GRID/property IDs are available. Mode vectors, preload fields and energy contours were intentionally omitted. Disable compact output and rerun to display shapes."
        push!(summary,Any["Output",message])
    end

    if mode_kind != "none"
        meff = Dict{Int,Any}()
        for e in get(d, "modal_effective_mass", Any[])
            mno = get(e, "mode", nothing)
            mno === nothing || (meff[Int(mno)] = e)
        end
        eigs = get(d, "eigenvalues", Any[])
        for md in get(d, "modes", Any[])
            mno = Int(get(md, "mode_number", length(buckling_roots) + length(modes) + 1))
            e = get(meff, mno, nothing)
            # SOL 105 eigenvalues are load factors on the static subcase; they
            # are not always repeated on the mode entry, so fall back to the
            # top level list.
            eig = fnum(get(md, "eigenvalue",
                           mno <= length(eigs) ? eigs[mno] : 0.0))
            if compact
                push!(buckling_roots,Dict{String,Any}("mode"=>mno,"eigenvalue"=>eig,"load_factor"=>eig,
                    "static_subcase_id"=>get(md,"static_subcase_id",nothing),"buckling_subcase_id"=>get(md,"buckling_subcase_id",nothing),
                    "peak_translation"=>get(md,"peak_translation",nothing)))
                continue
            end
            shape, mx = gather_translations(get(md, "mode_shape", Any[]), idx, n)
            push!(modes, Dict{String,Any}(
                "mode" => mno,
                "freq_hz" => fnum(get(md, "frequency_hz", 0.0)),
                "eigenvalue" => eig,
                "load_factor" => mode_kind == "buckling" ? eig : 0.0,
                "max_disp" => mx,
                "meff_x" => e === nothing ? 0.0 : fnum(get(e, "meff_x", 0.0)),
                "meff_y" => e === nothing ? 0.0 : fnum(get(e, "meff_y", 0.0)),
                "meff_z" => e === nothing ? 0.0 : fnum(get(e, "meff_z", 0.0)),
                "shape" => blob_f32(shape),
                "rotation" => blob_f32(gather_rotations(get(md, "mode_shape", Any[]), idx, n)),
                "peak_translation"=>get(md,"peak_translation",nothing),
                "element_energy"=>get(md,"element_energy",nothing),
                "energy_contours"=>element_energy_contours(m,get(md,"element_energy",nothing)),
            ))
        end
        if mode_kind == "frequency"
            freqs = [md["freq_hz"] for md in modes]
            if !isempty(freqs)
                push!(summary, Any["Modes computed", string(length(freqs))])
                push!(summary, Any["First frequency", eng(freqs[1]) * " Hz"])
                push!(summary, Any["Highest frequency", eng(freqs[end]) * " Hz"])
            end
        else
            lf = [md["load_factor"] for md in (compact ? buckling_roots : modes)]
            if !isempty(lf)
                push!(summary, Any["Buckling roots", string(length(lf))])
                push!(summary, Any["Critical load factor", eng(lf[1])])
                push!(summary, Any["Applied load", "Selected case's static preload"])
            end
        end
        ms = get(d, "mass_summary", nothing)
        if ms !== nothing
            push!(summary, Any["Total mass",
                               eng(fnum(get(ms, "total_mass_z", 0.0))) * " kg"])
        end
        # A buckling run also carries the prebuckling static shape.
        sd = get(d, "static_displacements", nothing)
        if sd !== nothing
            recs = sd isa AbstractDict ?
                   get(sd, "displacements", collect(values(sd))) : sd
            if recs isa AbstractVector && !isempty(recs) && first(recs) isa AbstractDict
                disp, mxs = gather_translations(recs, idx, n)
                if mxs > 0
                    static = Dict{String,Any}("disp" => blob_f32(disp),
                                              "rotation" => blob_f32(gather_rotations(recs, idx, n)),
                                              "max_disp" => mxs)
                    push!(summary, Any["Prebuckling max displacement",
                                       eng(mxs) * " m"])
                end
            end
        end

    elseif startswith(atype, "SOL101") || startswith(atype, "SOL106")
        if convergence !== nothing
            available = convergence["available"]
            message = convergence["message"]
            if available
                try
                    validate_static_result_coverage(m, d)
                catch error
                    available = false
                    message = sprint(showerror, error)
                end
            end
            status = available ? (convergence["partial"] ? "partial" : "complete") : "incomplete"
            push!(summary, Any["Nonlinear convergence", message])
            push!(summary, Any["Last accepted load fraction", string(convergence["final_load_scale"])])
            push!(summary, Any["Accepted increments", string(convergence["accepted_steps"])])
            convergence["partial"] && push!(summary,Any["Shown-state relative residual",string(convergence["exported_relative_residual"])])
            push!(summary, Any["Final relative residual", string(convergence["final_relative_residual"])])
        end
        if available
        reactions=support_reactions_payload(m,d;native_sid)
        disp, mx = gather_translations(get(d, "displacements", Any[]), idx, n)
        static = Dict{String,Any}(
            "disp" => blob_f32(disp),
            "rotation" => blob_f32(gather_rotations(get(d, "displacements", Any[]), idx, n)),
            "max_disp" => mx,
        )
        push!(summary, Any["Max displacement", eng(mx) * " m"])
        stresses = get(d, "stresses", Dict{String,Any}())
        contours, element_results = element_results_payload(m, d)
        append!(contours,element_energy_contours(m,get(d,"element_energy",nothing)))
        vm = [c["max"] for c in contours if c["name"] in ("Von Mises stress", "Solid von Mises stress")]
        if !isempty(vm)
            push!(summary, Any["Max von Mises", eng(maximum(vm)) * " Pa"])
        end
        nforces = count(r -> haskey(r, "forces"), values(element_results))
        push!(summary, Any["Elements with recovered forces", string(nforces)])
        push!(summary, Any["Stress/force contours", "Element values, no averaging"])
        blo, bhi = bar_axial_range(stresses)
        (blo != 0.0 || bhi != 0.0) &&
            push!(summary, Any["Bar axial range",
                               eng(blo) * " to " * eng(bhi) * " Pa"])
        end
    else
        push!(summary, Any["Note", "this solution type is reported but not " *
                                   "drawn as a deformed shape"])
    end

    report_path = find_report_md(job.outdir)
    report = report_path === nothing ? "" : read(report_path, String)

    return Dict{String,Any}(
        "ok" => true,
        "format" => "wingfegen-results-1",
        "analysis_type" => atype,
        "available" => available,
        "partial" => available && convergence!==nothing && convergence["partial"],
        "status" => status,
        "message" => message,
        "convergence" => convergence,
        "job" => job.id,
        "state" => String(job.state),
        "seconds" => job_seconds(job),
        "out_dir" => job.outdir,
        "results_json" => path,
        "report_path" => report_path === nothing ? "" : report_path,
        "report_md" => report,
        "node_count" => n,
        "model_params" => copy(m.params),
        "load_application_version" => is_imported_model(m) ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION,
        "mode_kind" => mode_kind,
        "compact_buckling"=>compact,
        "buckling_roots"=>buckling_roots,
        "output_options"=>get(d,"output_options",nothing),
        "element_energy"=>get(d,"element_energy",nothing),
        "preload_energy_contours"=>element_energy_contours(m,get(get(d,"static_result",Dict()),"element_energy",nothing)),
        "modes" => modes,
        "static" => static,
        "reactions" => reactions,
        "follower_loading" => follower_loading_payload(d),
        "load_scale" => convergence===nothing ? 1.0 : convergence["exported_load_scale"],
        "contours" => contours,
        "element_results" => element_results,
        "summary" => summary,
        "log" => job_log(job; tail = 400),
    )
end

"""Applied follower FORCE vectors from this exported native state, in BASIC."""
function follower_loading_payload(d::AbstractDict)
    rows=get(d,"solver_diagnostics",Any[])
    length(rows)==1 || return nothing
    row=only(rows)
    row isa AbstractDict || return nothing
    details=get(row,"details",row)
    details isa AbstractDict || return nothing
    loading=get(details,"follower_loading",nothing)
    loading isa AbstractDict || return nothing
    result=deepcopy(loading)
    result["physical_load_scale"]=get(result,"load_scale",1.0)
    return result
end

"""Split untagged JFEM aggregates using exporter order, checked repeated IDs.

The native exporter appends one complete result block per diagnostic SID.
Never select by EID alone: that would silently take the final case's values.
If block coverage differs between cases, refuse the ambiguous file.
"""
function static_case_result(d::AbstractDict, sid::Int, expected_sids::Vector{Int})
    solution = startswith(String(get(d, "analysis_type", "")), "SOL106") ? "SOL106" : "SOL101"
    diagnostics = get(d, "solver_diagnostics", Any[])
    order = Int[Int(row["sid"]) for row in diagnostics if row isa AbstractDict && haskey(row, "sid")]
    if length(expected_sids) == 1 && isempty(order)
        return d # backward compatibility with a single-case fixture/exporter
    end
    length(order) == length(unique(order)) && Set(order) == Set(expected_sids) ||
        throw(ArgumentError("$solution result subcase IDs do not match this model; cannot safely separate the results"))
    index = findfirst(==(sid), order)
    index === nothing && throw(ArgumentError("$solution has no results for subcase $sid"))
    count = length(order)
    function block(rows, idkey, field; corner_rows::Bool = false)
        rows isa AbstractVector || throw(ArgumentError("invalid $solution $field array"))
        isempty(rows) && return Any[]
        length(rows) % count == 0 || throw(ArgumentError("unequal $solution $field coverage between subcases"))
        width = length(rows) ÷ count
        ids(r) = [corner_rows ? (get(row, idkey, nothing), get(row, "grid_id", nothing)) :
                  get(row, idkey, nothing) for row in r]
        first_ids = ids(view(rows, 1:width))
        valid(x) = corner_rows ? x[1] isa Integer && x[2] !== nothing : x isa Integer
        all(valid, first_ids) && length(unique(first_ids)) == width ||
            throw(ArgumentError("ambiguous $solution $field IDs; refusing to mix subcases"))
        for i in 2:count
            Set(ids(view(rows, (i-1)*width+1:i*width))) == Set(first_ids) ||
                throw(ArgumentError("different $solution $field coverage between subcases"))
        end
        return rows[(index-1)*width+1:index*width]
    end
    selected = copy(d)
    for field in ("displacements", "spc_forces")
        haskey(d, field) && (selected[field] = block(d[field], "grid_id", field))
    end
    for field in ("forces", "forces_bilin", "stresses", "strains")
        source = get(d, field, nothing)
        source isa AbstractDict || continue
        selected[field] = Dict(k => block(rows, "eid", "$field.$k"; corner_rows = field == "forces_bilin")
                               for (k, rows) in source)
    end
    selected["solver_diagnostics"] = [row for row in diagnostics if get(row, "sid", nothing) == sid]
    nonlinear = get(d, "nonlinear_diagnostics", nothing)
    nonlinear isa AbstractVector && (selected["nonlinear_diagnostics"] =
        [row for row in nonlinear if row isa AbstractDict && get(row, "sid", nothing) == sid])
    return selected
end

"""Select only modes and the preload carrying this SOL105 case's explicit IDs."""
function buckling_case_result(d::AbstractDict, case_id::Int, case_count::Int)
    sid, bid = static_subcase_id(case_id, "105"), buckling_subcase_id(case_id)
    selected = copy(d)
    modes = get(d, "modes", Any[])
    tagged = all(md -> haskey(md, "static_subcase_id") && haskey(md, "buckling_subcase_id"), modes)
    case_count > 1 && !tagged && throw(ArgumentError("SOL105 modes lack subcase ownership; cannot safely separate the results"))
    selected["modes"] = tagged ? [md for md in modes if md["static_subcase_id"] == sid && md["buckling_subcase_id"] == bid] : modes
    selected["eigenvalues"] = [get(md, "eigenvalue", 0.0) for md in selected["modes"]]
    states = get(d, "static_subcases", Any[])
    if !isempty(states)
        delete!(selected, "static_displacements")
        delete!(selected, "static_result")
        matching = filter(row -> get(row, "static_subcase_id", nothing) == sid, states)
        length(matching) == 1 || throw(ArgumentError("SOL105 has no unique static preload for subcase $sid"))
        select_buckling_preload!(selected,only(matching))
    elseif case_count > 1 && !compact_buckling_output(d)
        throw(ArgumentError("SOL105 does not identify the per-case static preloads"))
    end
    return selected
end

"""Expose the actual SOL105 preload as a separate static result, without a second solve."""
function attach_buckling_preload!(job, path, item, selected, static_sid)
    compact_buckling_output(selected)&&return item
    buckling = copy(item)
    buckling["id"], buckling["variant_id"], buckling["label"] = "sol105", "sol105", "SOL105 buckling"
    buckling["native_subcase_id"] = get(item, "buckling_subcase_id", get(item, "native_subcase_id", 2))
    source = get(selected, "static_result", nothing)
    complete_recovery = source isa AbstractDict
    rows = get(selected, "static_displacements", nothing)
    rows isa AbstractDict && (rows = get(rows, "displacements", collect(values(rows))))
    if !complete_recovery
        rows isa AbstractVector && !isempty(rows) || return item
        source = Dict{String,Any}("displacements" => rows)
    else
        source = copy(source)
        get(source, "static_subcase_id", static_sid) == static_sid ||
            throw(ArgumentError("Static preload result does not belong to subcase $static_sid"))
        # Static DISPLACEMENT=NONE suppresses ordinary output, but SOL105
        # still retains the true preload vector needed for its reference
        # shape. Reuse that vector rather than displaying a false zero field.
        if isempty(get(source, "displacements", Any[])) && rows isa AbstractVector && !isempty(rows)
            source["displacements"] = rows
            source["displacement_source"] = "SOL105_PRELOAD_STATE"
        end
    end
    source["analysis_type"] = "SOL101_STATIC"
    for key in ("backend", "backend_version")
        haskey(selected, key) && (source[key] = selected[key])
    end
    validate_static_result_coverage(job.model, source)
    preload = copy(item)
    merge!(preload, jfem_case_results_payload(job, path, source; native_sid=Int(static_sid)))
    haskey(item, "model_params") && (preload["model_params"] = copy(item["model_params"]))
    preload["id"], preload["variant_id"], preload["label"] = "sol101", "sol101", "SOL101 preload"
    preload["static_subcase_id"] = Int(static_sid)
    preload["native_subcase_id"] = Int(static_sid)
    preload["source"] = "buckling_preload"
    preload["message"] = "Static preload used by this SOL105 calculation (subcase $static_sid)."
    push!(preload["summary"], Any["Result source", preload["message"]])
    complete_recovery || push!(preload["summary"], Any["Legacy results", "Displacements only; rerun SOL105 to export stresses, forces and reactions."])
    if haskey(source, "result_requests")
        preload["result_requests"] = source["result_requests"]
        suppressed = [key for key in ("SPCFORCES", "FORCE", "STRESS", "STRAIN")
            if get(source["result_requests"], key, true) !== true]
        isempty(suppressed) || push!(preload["summary"], Any["Unrequested fields", join(suppressed, ", ")])
    end
    if haskey(source, "recovery_diagnostics")
        preload["recovery_diagnostics"] = source["recovery_diagnostics"]
        recovery = source["recovery_diagnostics"]
        get(recovery, "status", "") == "partial" && push!(preload["summary"], Any["Partial field recovery",
            get(recovery, "reason", get(recovery, "corner_force_reason", "Some element fields are unavailable; no missing values were filled."))])
    end
    get(source, "stress_recovery_skipped", false) === true &&
        push!(preload["summary"], Any["Field recovery", "Element force/stress/strain recovery was disabled for this run."])
    # The optional static-shape row on a buckling variant is this same physical
    # preload. The viewer hides these forces whenever an eigenmode is selected.
    buckling["reactions"] = preload["reactions"]
    item["reactions"] = preload["reactions"]
    for variant in (preload, buckling), key in ("variants", "default_variant", "analysis_variants", "comparison")
        delete!(variant, key)
    end
    item["variants"], item["default_variant"] = Any[preload, buckling], "sol105"
    item["comparison"], item["analysis_variants"] = true, ["sol101", "sol105"]
    return item
end

"""Reject accidental pairing of different FE meshes, properties or applied loads."""
function validate_comparison_model(parent::Model, child::Model, spec; load_scale=1.0)
    parent.node_ids == child.node_ids && parent.xyz == child.xyz ||
        throw(ArgumentError("comparison child GRID ordering or geometry differs from the displayed model"))
    length(parent.groups) == length(child.groups) && all(zip(parent.groups, child.groups)) do pair
        a, b = pair
        a.kind == b.kind && a.pid == b.pid && a.eids == b.eids && a.conn == b.conn
    end || throw(ArgumentError("comparison child element connectivity differs from the displayed model"))
    for (key,value) in spec.params
        # Output paths, run controls and display reference assets may differ;
        # physical inputs must remain identical for a meaningful comparison.
        if startswith(key,"output.") || startswith(key,"jfem.") || key in ("loads.cases", "loads.label", "references.items")
            continue
        end
        expected=key=="loads.load_factor" ? value*load_scale : value
        isequal(get(child.params,key,nothing),expected) ||
            throw(ArgumentError("comparison child physical parameter $key differs from load case $(spec.id)"))
    end
    return nothing
end

function unavailable_analysis_variant(parent::JfemJob, spec, solution::String, child)
    report_path = child === nothing ? nothing : find_report_md(child.outdir)
    state = child === nothing ? "missing" : String(child.state)
    status = state in ("failed", "cancelled") ? state : state == "done" ? "incomplete" : "missing"
    message = child === nothing ? "No SOL$solution run is available for this load case." :
        isempty(child.message) ? "SOL$solution result is unavailable ($state)." : child.message
    label=get(Dict("101"=>"SOL101 linear","103"=>"SOL103 normal modes","105"=>"SOL105 buckling","106"=>"SOL106 nonlinear"),solution,"SOL$solution")
    analysis=get(Dict("101"=>"SOL101_STATIC","103"=>"SOL103_MODES","105"=>"SOL105_BUCKLING","106"=>"SOL106_NONLINEAR_STATIC"),solution,"SOL$solution")
    return Dict{String,Any}("ok" => true, "format" => "wingfegen-results-1",
        "id" => "sol" * solution, "label" => label,
        "physical_case_id" => spec.id, "available" => false, "status" => status, "message" => message,
        "analysis_type" => analysis,
        "job" => child === nothing ? parent.id : child.id, "state" => state,
        "seconds" => child === nothing ? 0.0 : job_seconds(child),
        "out_dir" => child === nothing ? "" : child.outdir, "results_json" => "",
        "report_path" => report_path === nothing ? "" : report_path,
        "report_md" => report_path === nothing ? "" : read(report_path,String),
        "node_count" => length(parent.model.node_ids), "model_params" => copy(spec.params),
        "mode_kind" => "none", "modes" => Any[], "static" => nothing, "reactions"=>nothing, "contours" => Any[],
        "element_results" => Dict{String,Any}(), "convergence" => nothing,
        "summary" => Any[Any["Analysis", "SOL$solution"], Any["Status", message]],
        "log" => child === nothing ? "" : job_log(child; tail=400))
end

"""Keep original Study provenance separate from effective case/variant inputs.

Call after native case selection and comparison compatibility checks. Case
model_params remain the effective physical inputs used for tables/load labels;
source_model_params identify the original generated Study for stale guards.
"""
function attach_result_source!(payload::AbstractDict,params::AbstractDict)
    source=deepcopy(params)
    function attach!(item)
        item["source_model_params"]=source
        for key in ("load_cases","variants"), child in get(item,key,Any[])
            child isa AbstractDict && attach!(child)
        end
    end
    attach!(payload)
    payload
end

"""Collate mass-dependent runs without confusing their identical native SIDs.

In particular SOL103 modes belong to each physical case's fuel mass, even
though no aerodynamic preload is used. Missing/failed cases remain visible.
"""
function jfem_isolated_results_payload(job::JfemJob)
    solution=String(job.model.params["output.solution"])
    cases=Any[]
    for spec in load_case_specs(job.model.params)
        matches=[child for child in job.runs if child.case_id==spec.id &&
            String(child.model.params["output.solution"])==solution]
        child=length(matches)==1 ? only(matches) : nothing
        item=unavailable_analysis_variant(job,spec,solution,child)
        if length(matches)>1
            item["message"]="Multiple SOL$solution runs claim this load case; results are ambiguous."
        elseif child!==nothing
            try
                validate_comparison_model(job.model,child.model,spec)
                child.state===:done || throw(ArgumentError(isempty(child.message) ?
                    "SOL$solution process is $(child.state); result arrays are not published." : child.message))
                path,source=find_results_json(child.outdir)
                path===nothing && throw(ArgumentError("SOL$solution produced no nodal results JSON; inspect its run log."))
                startswith(String(get(source,"analysis_type","")),"SOL"*solution) ||
                    throw(ArgumentError("result analysis type does not match the requested SOL$solution run"))
                selected=solution=="101" ? static_case_result(source,1,[1]) :
                    solution=="105" ? buckling_case_result(source,1,1) : source
                if solution=="101"
                    validate_static_result_coverage(child.model,selected)
                else
                    modes=get(selected,"modes",Any[])
                    isempty(modes)&&!compact_buckling_output(selected) && throw(ArgumentError("SOL$solution produced no eigenvalue records."))
                    solution=="103" && any(md->haskey(md,"sid") && md["sid"]!=1,modes) &&
                        throw(ArgumentError("SOL103 modes do not belong to this child's native subcase 1"))
                end
                complete=jfem_case_results_payload(child,path,selected)
                fuel=fuel_mass_state(child.model)
                merge!(item,complete)
                solution=="105" && attach_buckling_preload!(child,path,item,selected,1)
                item["fuel_mass"]=fuel
                push!(item["summary"],Any["Fuel mass","$(eng(fuel["mass_kg"])) kg at $(eng(fuel["fuel_percent"]))% fill"])
                solution=="103" && push!(item["summary"],Any["Modal mass state","Unloaded modes for this physical case's fuel mass"])
            catch error
                item["message"]=sprint(showerror,error)
            end
        end
        item["id"],item["label"]=spec.id,spec.label
        item["physical_case_id"],item["native_subcase_id"]=spec.id,1
        item["model_params"]=copy(spec.params)
        solution=="103" ? (item["modal_subcase_id"]=1) : (item["static_subcase_id"]=1)
        solution=="105" && (item["buckling_subcase_id"]=2)
        for variant in get(item,"variants",Any[])
            variant["physical_case_id"]=spec.id
            variant["model_params"]=copy(spec.params)
            variant["static_subcase_id"]=1
            variant["native_subcase_id"]=variant["id"]=="sol101" ? 1 : 2
            variant["buckling_subcase_id"]=2
            haskey(item,"fuel_mass") && (variant["fuel_mass"]=item["fuel_mass"])
            if variant["id"]=="sol101"
                push!(variant["summary"],Any["Load case","$(spec.id): $(spec.label)"])
                haskey(item,"fuel_mass") && push!(variant["summary"],Any["Fuel mass","$(eng(item["fuel_mass"]["mass_kg"])) kg"])
            end
        end
        !item["available"] && (item["summary"]=Any[Any["Analysis","SOL$solution"],Any["Status",item["message"]]])
        push!(item["summary"],Any["Load case","$(spec.id): $(spec.label)"])
        push!(cases,item)
    end
    preferred=findfirst(item->item["available"],cases)
    payload=copy(cases[preferred===nothing ? 1 : preferred])
    payload["model_params"]=copy(job.model.params)
    payload["job"],payload["state"],payload["seconds"]=job.id,String(job.state),job_seconds(job)
    payload["out_dir"],payload["log"]=job.outdir,job_log(job;tail=400)
    payload["load_cases"],payload["load_case_independent"]=cases,false
    payload["comparison"],payload["per_case_fuel_mass"]=false,true
    return attach_result_source!(payload,job.model.params)
end

"""Collate isolated SOL101/SOL106 children by physical load-case identity."""
function jfem_comparison_results_payload(job::JfemJob)
    cases = Any[]
    for spec in load_case_specs(job.model.params)
        variants = Any[]
        comparison_scale=1.0
        # Verify the nonlinear state before choosing the matching linear load.
        for solution in ("106", "101")
            follower_rerun=solution=="101" && comparison_scale<1 && get(spec.params,"loads.follower_forces",false)===true
            matches = [child for child in job.runs if child.case_id == spec.id &&
                string(get(child.model.params,"output.solution","")) == solution &&
                (get(child.progress,"comparison_role","")=="accepted_load_linear_baseline")==follower_rerun]
            child = length(matches) == 1 ? only(matches) : nothing
            variant = unavailable_analysis_variant(job,spec,solution,child)
            if follower_rerun && isempty(matches)
                variant["message"]="No verified matching-load SOL101 follower rerun is available. The retained full-load follower solution cannot be scaled to the accepted nonlinear load."
                variant["summary"]=Any[Any["Analysis","SOL101"],Any["Status",variant["message"]]]
            end
            if length(matches) > 1
                variant["message"] = "Multiple SOL$solution runs claim this load case; comparison is ambiguous."
            elseif child !== nothing
                try
                    if follower_rerun
                        get(child.progress,"comparison_load_scale",nothing)==comparison_scale ||
                            throw(ArgumentError("the rerun linear baseline load does not match the accepted nonlinear load"))
                    end
                    validate_comparison_model(job.model,child.model,spec;load_scale=follower_rerun ? comparison_scale : 1.0)
                    path, source = find_results_json(child.outdir)
                    path === nothing && throw(ArgumentError("SOL$solution produced no nodal results JSON; inspect its run log."))
                    variant["results_json"] = path
                    startswith(String(get(source,"analysis_type","")),"SOL"*solution) ||
                        throw(ArgumentError("result analysis type does not match the requested SOL$solution run"))
                    selected = static_case_result(source,1,[1])
                    if solution == "106"
                        variant["convergence"] = nonlinear_case_convergence(selected,1)
                        if !variant["convergence"]["available"]
                            variant["status"] = "incomplete"
                            throw(ArgumentError(variant["convergence"]["message"]))
                        end
                    end
                    recovered_partial=solution=="106" && variant["convergence"]["partial"] &&
                        child.state===:failed && !child.cancel_requested
                    child.state === :done || recovered_partial || throw(ArgumentError(isempty(child.message) ?
                        "SOL$solution process is $(child.state); result arrays are not published." : child.message))
                    validate_static_result_coverage(child.model,selected)
                    solution=="101" && comparison_scale<1 && !follower_rerun && (selected=scaled_linear_result(selected,comparison_scale))
                    complete = jfem_case_results_payload(child,path,selected)
                    merge!(variant,complete)
                    variant["id"], variant["label"] = "sol"*solution, solution == "101" ? "SOL101 linear" : "SOL106 nonlinear"
                    if solution=="106" && variant["available"]
                        comparison_scale=Float64(variant["convergence"]["exported_load_scale"])
                    end
                    variant["load_scale"]=comparison_scale
                    if variant["follower_loading"]!==nothing
                        variant["follower_loading"]["physical_load_scale"]=comparison_scale
                    end
                    variant["partial"]=solution=="106" && variant["convergence"]["partial"]
                    if solution=="101" && comparison_scale<1
                        variant["label"]="SOL101 linear at $(eng(100comparison_scale))% load"
                        variant["scaled_from_full_load"]=!follower_rerun
                        variant["matched_load_rerun"]=follower_rerun
                        variant["comparison_method"]=follower_rerun ? "matched_load_rerun" : "linear_scaling"
                        variant["source_load_scale"]=follower_rerun ? comparison_scale : 1.0
                        variant["message"]=follower_rerun ?
                            "SOL101 was solved again with follower load stiffness at the accepted SOL106 physical load. The full-load result is retained separately." :
                            "Exact linear scaling of the full-load SOL101 solution to the accepted SOL106 load; native files retain the full-load result."
                        push!(variant["summary"],Any["Comparison load", "$(eng(100comparison_scale))% of prescribed load; "*(follower_rerun ? "new matched-load SOL101 solve" : "exactly scaled linear response")])
                    elseif variant["partial"]
                        variant["label"]="SOL106 accepted at $(eng(100comparison_scale))% load (incomplete run)"
                    end
                    variant["model_params"] = copy(spec.params)
                    variant["physical_case_id"] = spec.id
                    variant["static_subcase_id"] = 1
                    push!(variant["summary"],Any["Load case","$(spec.id): $(spec.label)"])
                catch error
                    variant["message"] = sprint(showerror,error)
                    variant["summary"] = Any[Any["Analysis","SOL$solution"],Any["Status",variant["message"]]]
                end
            end
            push!(variants,variant)
        end
        reverse!(variants) # public ordering remains SOL101, SOL106
        chosen = variants[2]["available"] ? variants[2] : variants[1]["available"] ? variants[1] : variants[2]
        item = copy(chosen)
        item["id"], item["label"] = spec.id, spec.label
        item["variants"], item["default_variant"] = variants, chosen["id"]
        item["comparison_load_scale"]=comparison_scale
        push!(item["summary"],Any["Shared numerical control","SOL101 and SOL106 both use K6ROT=$(COMPARISON_K6ROT)"])
        push!(cases,item)
    end
    preferred = findfirst(case -> case["available"],cases)
    payload = copy(cases[preferred === nothing ? 1 : preferred])
    payload["model_params"] = copy(job.model.params)
    payload["job"],payload["state"],payload["seconds"] = job.id,String(job.state),job_seconds(job)
    payload["out_dir"],payload["log"] = job.outdir,job_log(job;tail=400)
    payload["load_cases"],payload["load_case_independent"] = cases,false
    payload["comparison"],payload["analysis_variants"] = true,["sol101","sol106"]
    payload["shared_numerical_parameters"] = Dict("K6ROT"=>COMPARISON_K6ROT)
    return attach_result_source!(payload,job.model.params)
end

"""Build one result payload per load case, preserving the default top-level view."""
function jfem_results_payload(job::JfemJob)
    is_imported_model(job.model)&&return imported_results_payload(job)
    if !isempty(job.runs)
        return String(job.model.params["output.solution"])=="106" ?
            jfem_comparison_results_payload(job) : jfem_isolated_results_payload(job)
    end
    path, d = find_results_json(job.outdir)
    path === nothing && throw(ArgumentError(
        "the solver produced no results JSON in $(job.outdir). Check the run log for what went wrong."))
    specs = load_case_specs(job.model.params)
    atype = String(get(d, "analysis_type", "UNKNOWN"))
    if startswith(atype, "SOL103")
        payload = jfem_case_results_payload(job, path, d)
        payload["load_cases"] = Any[]
        payload["load_case_independent"] = true
        push!(payload["summary"], Any["Load cases", "Unloaded normal modes are common to all cases"])
        return attach_result_source!(payload,job.model.params)
    end
    cases = Any[]
    for spec in specs
        selected = startswith(atype, "SOL101") || startswith(atype, "SOL106") ? static_case_result(d, spec.id, [s.id for s in specs]) :
                   startswith(atype, "SOL105") ? buckling_case_result(d, spec.id, length(specs)) : d
        item = jfem_case_results_payload(job, path, selected; native_sid=spec.id)
        item["id"], item["label"] = spec.id, spec.label
        item["model_params"] = copy(spec.params)
        item["static_subcase_id"] = static_subcase_id(spec.id, startswith(atype, "SOL105") ? "105" : "101")
        startswith(atype, "SOL105") && (item["buckling_subcase_id"] = buckling_subcase_id(spec.id))
        startswith(atype, "SOL105") && attach_buckling_preload!(job,path,item,selected,item["static_subcase_id"])
        push!(item["summary"], Any["Load case", "$(spec.id): $(spec.label)"])
        push!(cases, item)
    end
    payload = copy(first(cases))
    payload["model_params"] = copy(job.model.params)
    payload["load_cases"] = cases
    payload["load_case_independent"] = false
    return attach_result_source!(payload,job.model.params)
end
