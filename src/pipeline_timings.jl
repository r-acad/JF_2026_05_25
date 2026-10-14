# Timing is wall time, not CPU time. Julia compilation includes recompilation.
# Only completed measurements separate JIT from execution; no live warm guess.
const _PIPELINE_CONTEXT_KEY = :jfem_pipeline_timing_context
const _PIPELINE_METRICS = ("wall_seconds","compilation_seconds","recompilation_seconds","execution_seconds","gc_seconds")
const _PIPELINE_LABELS = Dict(
    "parse"=>"Read and parse deck", "build_model"=>"Construct native model",
    "solve"=>"Numerical solver", "export"=>"Write results", "report"=>"Write report",
    "model_export"=>"Write model JSON", "card_inventory"=>"Write card inventory",
    "adjoint"=>"Adjoint sensitivity")
_pipeline_category(name) = name in ("solve","adjoint") ? "numerical" :
    name in ("export","report","model_export","card_inventory") ? "export" : "preparation"

function _pipeline_metrics(wall,compilation,recompilation,gc)
    Dict{String,Any}("wall_seconds"=>wall,"compilation_seconds"=>compilation,
        "recompilation_seconds"=>recompilation,
        "execution_seconds"=>0<=compilation<=wall ? wall-compilation : nothing,"gc_seconds"=>gc)
end

function _pipeline_emit(record,state;timing=nothing,resumed=false)
    event=Dict{String,Any}("schema_version"=>1,"id"=>record["id"],"phase"=>record["phase"],
        "label"=>record["label"],"category"=>record["category"],"parent"=>record["parent"],
        "depth"=>record["depth"],"state"=>state,"resumed"=>resumed,
        "elapsed_seconds"=>max(0.,(time_ns()-record["started_ns"])*1e-9),
        "compilation_live"=>state=="started" ? "not_separable" : "measured_retrospectively")
    timing===nothing || (event["timing"]=timing)
    println("[JFEM_PROGRESS] "*JSON.json(event));flush(stdout)
    return nothing
end

function _pipeline_enter!(context,name,category,label)
    context["sequence"]+=1
    stack=context["stack"]
    parent=isempty(stack) ? nothing : last(stack)["path"]
    path=parent===nothing ? name : parent*"/"*name
    record=Dict{String,Any}("id"=>context["root"]*":"*string(context["sequence"]),
        "phase"=>name,"label"=>label,"category"=>category,"parent"=>parent,"path"=>path,
        "depth"=>length(stack),"started_ns"=>time_ns(),
        "children"=>Dict(key=>0. for key in _PIPELINE_METRICS if key!="execution_seconds"))
    push!(stack,record);_pipeline_emit(record,"started")
    return record
end

function _pipeline_exit!(context,record,inclusive;failed=false)
    pop!(context["stack"])
    if inclusive!==nothing
        child=record["children"]
        # Child intervals are nested, not extra time. Preserve invalid compile
        # separation as null rather than hiding overlap with a zero clamp.
        ew=max(0.,inclusive["wall_seconds"]-child["wall_seconds"])
        ec=inclusive["compilation_seconds"]-child["compilation_seconds"]
        abs(ec)<1e-9 && (ec=0.)
        exclusive=_pipeline_metrics(ew,ec,max(0.,inclusive["recompilation_seconds"]-child["recompilation_seconds"]),
            max(0.,inclusive["gc_seconds"]-child["gc_seconds"]))
        aggregate=get!(context["rows"],record["path"]) do
            Dict{String,Any}("phase"=>record["phase"],"label"=>record["label"],"category"=>record["category"],
                "parent"=>record["parent"],"path"=>record["path"],"depth"=>record["depth"],"calls"=>0,
                "inclusive"=>Dict{String,Any}(key=>0. for key in _PIPELINE_METRICS),
                "exclusive"=>Dict{String,Any}(key=>0. for key in _PIPELINE_METRICS))
        end
        aggregate["calls"]+=1
        for (kind,metrics) in (("inclusive",inclusive),("exclusive",exclusive)), key in _PIPELINE_METRICS
            old=aggregate[kind][key];value=metrics[key]
            aggregate[kind][key]=old===nothing || value===nothing ? nothing : old+value
        end
        if !isempty(context["stack"])
            parent=last(context["stack"])
            for key in keys(parent["children"]);parent["children"][key]+=inclusive[key];end
        end
    end
    _pipeline_emit(record,failed ? "failed" : "completed";timing=inclusive)
    isempty(context["stack"]) || _pipeline_emit(last(context["stack"]),"started";resumed=true)
end

# Numerical helpers call this only when a top-level measurement is active.
# Child snapshots use the compilation counters enabled by the outer @timed;
# they do not enable/disable nested compiler accounting themselves.
function _pipeline_detail_measure!(f,name::String,label::String;category="numerical")
    context=get(task_local_storage(),_PIPELINE_CONTEXT_KEY,nothing)
    context===nothing && return f()
    record=_pipeline_enter!(context,name,category,label)
    gc=Base.gc_num();compilation=Base.cumulative_compile_time_ns();started=time_ns()
    value=try
        Base.invokelatest(f)
    catch
        _pipeline_exit!(context,record,nothing;failed=true)
        rethrow()
    end
    wall=(time_ns()-started)*1e-9
    compiled=Base.cumulative_compile_time_ns().-compilation
    metrics=_pipeline_metrics(wall,compiled[1]*1e-9,compiled[2]*1e-9,Base.GC_Diff(Base.gc_num(),gc).total_time*1e-9)
    _pipeline_exit!(context,record,metrics)
    return value
end

function _pipeline_measure!(f,phases::AbstractDict,name::String)
    context=Dict{String,Any}("root"=>name,"sequence"=>0,"stack"=>Any[],"rows"=>Dict{String,Any}())
    record=_pipeline_enter!(context,name,_pipeline_category(name),get(_PIPELINE_LABELS,name,name))
    stats=try
        task_local_storage(_PIPELINE_CONTEXT_KEY,context) do
            @timed Base.invokelatest(f)
        end
    catch
        _pipeline_exit!(context,record,nothing;failed=true)
        rethrow()
    end
    metrics=_pipeline_metrics(Float64(stats.time),Float64(stats.compile_time),Float64(stats.recompile_time),Float64(stats.gctime))
    _pipeline_exit!(context,record,metrics)
    phases[name]=merge(metrics,Dict("category"=>record["category"],"label"=>record["label"],
        "stages"=>sort!(collect(values(context["rows"]));by=r->r["path"])))
    return stats.value
end

function _pipeline_timing_payload(phases)
    stages=Any[]
    for (name,phase) in phases
        if haskey(phase,"stages")
            append!(stages,phase["stages"])
        else
            metrics=Dict(key=>get(phase,key,nothing) for key in _PIPELINE_METRICS)
            push!(stages,Dict("phase"=>name,"label"=>get(_PIPELINE_LABELS,name,name),
                "category"=>_pipeline_category(name),"parent"=>nothing,"path"=>name,"depth"=>0,"calls"=>1,
                "inclusive"=>metrics,"exclusive"=>copy(metrics)))
        end
    end
    sort!(stages;by=r->r["path"])
    category_sum(category)=begin
        entries=[r["exclusive"]["execution_seconds"] for r in stages if r["category"]==category]
        any(isnothing,entries) ? nothing : sum(entries;init=0.)
    end
    Dict{String,Any}("schema_version"=>2,"solution_seconds"=>category_sum("numerical"),
        "preparation_seconds"=>category_sum("preparation"),"export_seconds"=>category_sum("export"),
        "compilation_seconds"=>sum(p["compilation_seconds"] for p in values(phases)),
        "measured_wall_seconds"=>sum(p["wall_seconds"] for p in values(phases)),
        "phases"=>phases,"stages"=>stages,
        "solution_scope"=>"Numerical stage execution including assembly, constraints, equilibrium/eigenvalue solution, sensitivity and deferred recovery; excludes measured compilation, deck preparation and file export. Includes numerical orchestration, GC and scheduling waits; not CPU time.",
        "compilation_scope"=>"Measured Julia compilation includes recompilation. Package loading/precompilation before main is unmeasured process startup; live compiler activity cannot be separated reliably.",
        "measurement"=>"Inclusive children are already contained in parent stage times; category totals sum exclusive execution only. Execution is unavailable if measured compilation overlaps/exceeds its wall interval.")
end
