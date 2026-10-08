# ===========================================================================
#  server.jl - local HTTP server backing the Babylon.js web app
#
#  Endpoints
#  ---------
#    GET  /                  the web app
#    GET  /<file>            static assets from web/
#    GET  /api/input         parameter schema and current values, JSON
#    POST /api/generate      parameters in, mesh out as MsgPack
#    POST /api/nastran       parameters in, writes the BDF, JSON summary
#    POST /api/save_input    parameters in, rewrites the TOML input file
#    POST /api/shutdown      stops the server
#
#  Parameters travel to the browser as JSON and come back as JSON. The mesh
#  travels to the browser as MsgPack. The input file on disk stays TOML.
# ===========================================================================

"""
    AppState

Everything a request handler needs: where the application lives, which input
file is loaded, the current parameters and the most recently generated model.
"""
mutable struct AppState
    root::String
    webdir::String
    input_path::String
    params::Dict{String,Any}
    model::Union{Nothing,Model}
    jobs::Dict{String,JfemJob}
    job_counter::Int
    running::Bool
    job_lock::ReentrantLock
    deck_store_dir::String
    latest_deck::Union{Nothing,Dict{String,Any}}
    deck_lock::ReentrantLock
    activities::Dict{String,Tuple{Float64,String}}
    activity_lock::ReentrantLock
    activity_events::Dict{String,Vector{Dict{String,Any}}}
    sensitivity_jobs::Dict{String,SensitivityJob}
end

function AppState(root::AbstractString, input_path::AbstractString;
                  deck_store_dir::AbstractString = joinpath(root, "output", ".wingfegen"))
    params = read_input(input_path)
    st = AppState(abspath(root), joinpath(abspath(root), "web"),
                    abspath(input_path), params, nothing,
                    Dict{String,JfemJob}(), 0, true, ReentrantLock(),
                    abspath(deck_store_dir), nothing, ReentrantLock(),
                    Dict{String,Tuple{Float64,String}}(), ReentrantLock(), Dict{String,Vector{Dict{String,Any}}}(), Dict{String,SensitivityJob}())
    try
        st.latest_deck = read_deck_snapshot(st)
    catch e
        @warn "could not restore the last created deck" exception = (e, catch_backtrace())
    end
    return st
end

"""
    get_job(st, req) -> JfemJob

Look up the job named by the `job` query parameter.
"""
function get_job(st::AppState, req)
    q = HTTP.queryparams(HTTP.URI(req.target))
    id = get(q, "job", "")
    isempty(id) && throw(ArgumentError("no job id given"))
    haskey(st.jobs, id) || throw(ArgumentError("unknown job id: $id"))
    return st.jobs[id]
end

const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".js" => "application/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon",
    ".png" => "image/png",
    ".toml" => "text/plain; charset=utf-8",
    ".txt" => "text/plain; charset=utf-8",
    ".map" => "application/json; charset=utf-8",
)

json_response(obj; status::Int = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8",
                           "Cache-Control" => "no-store"], JSON.json(obj))

msgpack_response(obj) =
    HTTP.Response(200, ["Content-Type" => "application/x-msgpack",
                        "Cache-Control" => "no-store"], MsgPack.pack(obj))

error_response(err; status::Int = 400) =
    json_response(Dict{String,Any}("ok" => false, "error" => err); status = status)

"""
    describe_error(e) -> String

Turn an exception into a single line the browser can show. Argument errors
carry the parameter name, so they are reported verbatim.
"""
function describe_error(e)
    if e isa ArgumentError
        return e.msg
    elseif e isa MethodError
        return "internal type error: " * sprint(showerror, e)
    else
        return sprint(showerror, e)
    end
end

"""
    safe_asset_path(webdir, target) -> Union{String,Nothing}

Resolve a request target to a file inside `webdir`, rejecting anything that
would escape it.
"""
function safe_asset_path(webdir::AbstractString, target::AbstractString)
    path = first(split(target, '?'))
    path = first(split(path, '#'))
    path = HTTP.URIs.unescapeuri(path)
    path = replace(path, '\\' => '/')
    path == "/" && (path = "/index.html")
    parts = filter(!isempty, split(path, '/'))
    any(p -> p == ".." || p == ".", parts) && return nothing
    isempty(parts) && return nothing
    full = joinpath(webdir, parts...)
    # Confirm the resolved file really is under webdir.
    startswith(abspath(full), abspath(webdir)) || return nothing
    return isfile(full) ? full : nothing
end

function serve_asset(st::AppState, req)
    full = safe_asset_path(st.webdir, req.target)
    full === nothing && return HTTP.Response(404, ["Content-Type" => "text/plain"],
                                             "not found: " * req.target)
    ctype = get(MIME_TYPES, lowercase(splitext(full)[2]), "application/octet-stream")
    # Vendored libraries never change, the app files should not be cached.
    cache = occursin("/vendor/", replace(full, '\\' => '/')) ?
            "public, max-age=86400" : "no-store"
    return HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => cache],
                         read(full))
end

"""
    params_from_request(st, req) -> Dict{String,Any}

Read the parameter set posted by the browser. The body is a flat JSON object
of dotted keys; an empty body means use the parameters already loaded.
"""
function params_from_request(st::AppState, req)
    body = String(req.body)
    isempty(strip(body)) && return copy(st.params)
    raw = JSON.parse(body)
    raw isa AbstractDict || throw(ArgumentError("expected a JSON object of parameters"))
    flat = raw
    # Accept either a flat dotted object or the nested section form.
    if any(v -> v isa AbstractDict, values(raw))
        flat = flatten_toml(raw)
    end
    params, unknown = normalize_params(flat)
    isempty(unknown) || @warn "ignoring unknown parameter keys" keys = unknown
    return params
end

"""
    resolve_output(st, rel) -> String

Resolve an output path from the input file against the application folder, so
that a relative `output/wing_box.bdf` always lands in a predictable place.
"""
function resolve_output(st::AppState, rel::AbstractString)
    isabspath(rel) && return rel
    return normpath(joinpath(st.root, rel))
end

# --- handlers --------------------------------------------------------------

const ACTIVITY_STAGES = Dict(
    "geometry" => "Evaluating wing geometry…", "mesh" => "Meshing skins, spars, ribs and stringers…",
    "leading_edge" => "Meshing the selected leading-edge rib range…",
    "stiffened_panels" => "Assigning stiffened skin panels and inherited shell/stringer properties…",
    "aero" => "Building aerodynamic geometry…", "fuel" => "Calculating exact fuel capacity…",
    "weights" => "Calculating component and fuel weights…", "checks" => "Checking mesh connectivity…",
    "element_axes" => "Preparing element frames…", "aerodynamic_loads" => "Calculating aerodynamic load cases…",
    "fuel_display" => "Building fuel tank display…", "annotations" => "Preparing entity labels…",
    "fuel_masses" => "Integrating fuel-bay volume, centre of gravity and inertia…",
    "case_preparation" => "Preparing independent load-case masses and loads…",
    "payload" => "Packing mesh data…", "deck" => "Writing NASTRAN deck…",
    "done" => "Sending results to the viewer…")

function request_progress(st::AppState, req)
    id = HTTP.header(req, "X-Wing-Activity", "")
    # The bounded store is diagnostic only; clients cannot start work through it.
    isempty(id) && return _ -> nothing
    length(id) <= 96 || return _ -> nothing
    started=time()
    function report(stage)
        lock(st.activity_lock) do
            if !haskey(st.activities, id) && length(st.activities) >= 64
                oldest = first(sort!(collect(keys(st.activities)); by = k -> st.activities[k][1]))
                delete!(st.activities, oldest)
                delete!(st.activity_events, oldest)
            end
            label=get(ACTIVITY_STAGES,String(stage),String(stage))
            st.activities[id] = (time(),label)
            events=get!(st.activity_events,id,Dict{String,Any}[])
            if isempty(events)||events[end]["stage"]!=label
                push!(events,Dict("sequence"=>(isempty(events) ? 1 : events[end]["sequence"]+1),
                    "stage"=>label,"elapsed_seconds"=>round(time()-started;digits=3)))
                length(events)>256&&popfirst!(events)
            end
        end
        yield() # allow progress requests between CPU-intensive stages on one-thread Julia
        nothing
    end
    report("geometry")
    return report
end

function handle_activity(st::AppState, req)
    id = get(HTTP.queryparams(HTTP.URI(req.target)), "id", "")
    lock(st.activity_lock) do
        record = get(st.activities, id, nothing)
        return json_response(Dict("ok" => true, "stage" => record === nothing ? "" : record[2],
            "events"=>get(st.activity_events,id,Dict{String,Any}[])))
    end
end

function handle_input(st::AppState, req)
    try
        # Re-read the file so the button really does reload from disk.
        if isfile(st.input_path)
            st.params = read_input(st.input_path)
        end
        payload=schema_payload(st.params, st.input_path)
        payload["defaults"]=default_params()
        return json_response(payload)
    catch e
        @error "reading the input file failed" exception = (e, catch_backtrace())
        return error_response("input file: " * describe_error(e))
    end
end

"""Read the configured TOML verbatim without normalizing or changing state."""
function handle_input_text(st::AppState, req)
    try
        isfile(st.input_path) || throw(ArgumentError("Configured server input file does not exist"))
        filesize(st.input_path) <= 128*1024*1024 || throw(ArgumentError("TOML input exceeds the 128 MiB preview limit"))
        return json_response(Dict("ok"=>true,"text"=>read(st.input_path,String),"path"=>st.input_path))
    catch error
        return error_response("TOML preview: "*describe_error(error))
    end
end

function sensitivity_parameters(req)
    raw=JSON.parse(String(req.body))
    raw isa AbstractDict&&get(raw,"parameters",nothing) isa AbstractDict||throw(ArgumentError("Sensitivity needs the current model parameters"))
    params,unknown=normalize_params(raw["parameters"])
    isempty(unknown)||throw(ArgumentError("Unsupported sensitivity model parameters: "*join(unknown,", ")))
    return params,raw
end

function handle_sensitivity_catalog(st::AppState,req)
    try
        params,_=sensitivity_parameters(req)
        model=build_model(params;progress=request_progress(st,req))
        return json_response(Dict("ok"=>true,"catalog"=>sensitivity_catalog(model)))
    catch error
        return error_response("Sensitivity properties: "*describe_error(error))
    end
end

function handle_sensitivity_run(st::AppState,req;start_job=start_sensitivity_job)
    lock(st.job_lock)
    try
        any(job.state===:running for job in values(st.jobs))&&throw(ArgumentError("Wait for the current JFEM analysis before starting sensitivity"))
        any(job.state===:running for job in values(st.sensitivity_jobs))&&throw(ArgumentError("A sensitivity job is already running; wait or stop it first"))
        params,raw=sensitivity_parameters(req)
        model=build_model(params;progress=request_progress(st,req))
        all_checks_pass(model)||throw(ArgumentError("Correct the FEM connectivity checks before sensitivity analysis"))
        st.job_counter+=1;id="sensitivity"*string(st.job_counter)
        job=start_job(model,get(raw,"settings",Dict()),st.root,id)
        st.sensitivity_jobs[id]=job
        return json_response(Dict("ok"=>true,"job"=>id,"state"=>String(job.state),"outdir"=>job.outdir))
    catch error
        return error_response("Sensitivity analysis: "*describe_error(error))
    finally
        unlock(st.job_lock)
    end
end

function get_sensitivity_job(st,req)
    id=get(HTTP.queryparams(HTTP.URI(req.target)),"job","")
    haskey(st.sensitivity_jobs,id)||throw(ArgumentError("Unknown sensitivity job"))
    return st.sensitivity_jobs[id]
end

function handle_sensitivity_status(st::AppState,req)
    try
        return json_response(merge(Dict("ok"=>true),sensitivity_status(get_sensitivity_job(st,req))))
    catch error
        return error_response(describe_error(error))
    end
end

function handle_sensitivity_stop(st::AppState,req)
    try
        job=get_sensitivity_job(st,req);cancel_sensitivity_job!(job)
        return json_response(merge(Dict("ok"=>true),sensitivity_status(job)))
    catch error
        return error_response(describe_error(error))
    end
end

function handle_sensitivity_saved_list(st::AppState,req)
    try
        params,_=sensitivity_parameters(req)
        return json_response(merge(Dict("ok"=>true),sensitivity_saved_list(params,st.root)))
    catch error
        return error_response("Saved sensitivity studies: "*describe_error(error))
    end
end

function handle_sensitivity_saved_load(st::AppState,req)
    try
        params,raw=sensitivity_parameters(req)
        # Reading history must not regenerate a mesh. Only an already generated
        # model whose definition agrees with the submitted controls can map it.
        current=st.model
        current!==nothing&&sensitivity_definition(current.params)!=sensitivity_definition(params)&&(current=nothing)
        data=sensitivity_saved_load(params,st.root,get(raw,"run_id",nothing);model=current)
        return json_response(merge(Dict("ok"=>true),data))
    catch error
        return error_response("Open sensitivity study: "*describe_error(error))
    end
end

function sensitivity_baseline_request(st,req)
    params,raw=sensitivity_parameters(req)
    directory=if haskey(raw,"job")
        id=raw["job"];id isa AbstractString&&haskey(st.sensitivity_jobs,id)||throw(ArgumentError("Unknown sensitivity job"))
        st.sensitivity_jobs[id].outdir
    else
        sensitivity_saved_run(sensitivity_saved_directory(params,st.root),get(raw,"run_id",nothing))
    end
    current=st.model
    current!==nothing&&sensitivity_definition(current.params)!=sensitivity_definition(params)&&(current=nothing)
    return directory,current,raw
end

function handle_sensitivity_baseline(st::AppState,req)
    try
        directory,current,_=sensitivity_baseline_request(st,req)
        result=isfile(joinpath(directory,"result.json")) ? sensitivity_read_result(directory) : nothing
        return msgpack_response(sensitivity_baseline_load(directory,current;result))
    catch error
        return error_response("Sensitivity baseline: "*describe_error(error))
    end
end

function handle_sensitivity_baseline_download(st::AppState,req)
    try
        directory,_,raw=sensitivity_baseline_request(st,req)
        kind=get(raw,"file",nothing);kind isa AbstractString||throw(ArgumentError("Choose a baseline download"))
        path=sensitivity_baseline_file(directory,kind)
        mime=kind=="results" ? "application/x-msgpack" : kind=="native" ? "application/json; charset=utf-8" : "text/plain; charset=utf-8"
        return HTTP.Response(200,["Content-Type"=>mime,"Cache-Control"=>"no-store",
            "Content-Disposition"=>"attachment; filename=\""*basename(path)*"\""],read(path))
    catch error
        return error_response("Download sensitivity baseline: "*describe_error(error))
    end
end

function handle_generate(st::AppState, req)
    progress = request_progress(st, req)
    try
        params = params_from_request(st, req)
        t0 = time()
        model = build_model(params; progress)
        dt = time() - t0
        payload = mesh_payload(model; progress)
        st.params = params
        st.model = model
        payload["generate_seconds"] = round(dt; digits = 4)
        @info "mesh generated" nodes = length(model.node_ids) seconds = round(dt; digits = 3)
        progress("done")
        return msgpack_response(payload)
    catch e
        @error "mesh generation failed" exception = (e, catch_backtrace())
        return error_response(describe_error(e))
    end
end

# Portable workspace preparation is read-only: malformed imports, aerodynamic
# failures and cancelled browser operations cannot replace the active model,
# solver snapshot, input file or reference metadata on the server.
function handle_workspace(st::AppState, req; generate::Bool = false)
    progress = request_progress(st, req)
    try
        raw = JSON.parse(String(req.body))
        raw isa AbstractDict || throw(ArgumentError("workspace parameters must be a JSON object"))
        params, unknown = normalize_params(raw)
        isempty(unknown) || throw(ArgumentError("unsupported workspace parameters: " * join(sort!(unknown), ", ")))
        if generate
            model = build_model(params; progress)
            payload = mesh_payload(model; progress)
            st.model=model;st.params=params
            progress("done")
            return msgpack_response(payload)
        end
        return json_response(Dict("ok" => true, "parameters" => params))
    catch e
        return error_response(describe_error(e))
    end
end

"""Validate a selected TOML's text without changing the server input or model."""
function handle_import_toml(st::AppState, req)
    try
        raw=JSON.parse(String(req.body))
        raw isa AbstractDict && get(raw,"text",nothing) isa AbstractString ||
            throw(ArgumentError("TOML import needs a text string"))
        text=String(raw["text"])
        sizeof(text)<=128*1024*1024 || throw(ArgumentError("TOML input exceeds the 128 MiB limit"))
        params,unknown=normalize_params(flatten_toml(TOML.parse(text)))
        isempty(unknown) || throw(ArgumentError("unsupported TOML parameters: "*join(sort!(unknown),", ")))
        return json_response(Dict("ok"=>true,"parameters"=>params,
            "reference_base"=>dirname(abspath(st.input_path))))
    catch error
        return error_response("TOML import: "*describe_error(error))
    end
end

"""Export current browser parameters as text; never overwrite server files."""
function handle_export_toml(st::AppState, req)
    try
        raw=JSON.parse(String(req.body))
        raw isa AbstractDict || throw(ArgumentError("TOML export needs a parameter object"))
        params,unknown=normalize_params(raw)
        isempty(unknown) || throw(ArgumentError("unsupported TOML parameters: "*join(sort!(unknown),", ")))
        return json_response(Dict("ok"=>true,"text"=>params_to_toml(params)))
    catch error
        return error_response("TOML export: "*describe_error(error))
    end
end

"""Checksum the association of preserved deck texts with their physical cases."""
function case_decks_digest(cases)
    # Fixed field order makes the association checksum stable across processes.
    rows=[[row[key] for key in ("case_id","label","fuel_percent","path","lines","bytes","sha256")] for row in cases]
    return bytes2hex(SHA.sha256(JSON.json(rows)))
end

function validate_case_decks(snapshot)
    cases=get(snapshot,"case_decks",Any[])
    cases isa AbstractVector && length(cases)<=65 ||
        throw(ArgumentError("the saved case-deck collection is invalid"))
    if !isempty(cases) || haskey(snapshot,"case_decks_sha256")
        used=Set{Int}()
        for row in cases
            row isa AbstractDict || throw(ArgumentError("the saved case-deck metadata is invalid"))
            id=get(row,"case_id",nothing);label=get(row,"label",nothing);percent=get(row,"fuel_percent",nothing)
            id isa Integer && !(id isa Bool) && id>0 && !(id in used) && label isa String &&
                percent isa Real && !(percent isa Bool) && isfinite(percent) && 0<=percent<=100 &&
                get(row,"path",nothing) isa String || throw(ArgumentError("the saved case-deck metadata is invalid"))
            push!(used,id)
            text=get(row,"deck_text",nothing)
            text isa String && get(row,"sha256","")==bytes2hex(SHA.sha256(text)) &&
                get(row,"bytes",nothing)==sizeof(text) && get(row,"lines",nothing)==count(==('\n'),text) ||
                throw(ArgumentError("saved deck for case $id failed its integrity check"))
        end
        get(snapshot,"case_decks_sha256","")==case_decks_digest(cases) ||
            throw(ArgumentError("the saved case-deck metadata failed its integrity check"))
        if !isempty(cases)
            first(cases)["case_id"]==1 && first(cases)["path"]==snapshot["path"] &&
                first(cases)["sha256"]==snapshot["sha256"] ||
                throw(ArgumentError("the saved primary deck does not match case 1"))
        end
    end
    return cases
end

"""Read the saved bytes, never the current output path or an arbitrary client path."""
function read_deck_snapshot(st::AppState)
    file = joinpath(st.deck_store_dir, "last_deck.json")
    isfile(file) || return nothing
    snapshot = JSON.parsefile(file)
    snapshot isa AbstractDict && get(snapshot, "version", 0) == 1 ||
        throw(ArgumentError("unsupported saved deck snapshot"))
    text = get(snapshot, "deck_text", nothing)
    text isa String && get(snapshot, "sha256", "") == bytes2hex(SHA.sha256(text)) ||
        throw(ArgumentError("the saved deck snapshot failed its integrity check"))
    validate_case_decks(snapshot)
    return Dict{String,Any}(snapshot)
end

deck_metadata(snapshot) = Dict{String,Any}(k => v for (k, v) in snapshot if k != "deck_text")

"""Atomically preserve a completed deck independently of its original filename."""
function preserve_deck!(st::AppState, path::AbstractString, params; source::String, case_files=Any[])
    text = read(path, String)
    cases=Any[]
    for file in case_files
        case_text=abspath(file["path"])==abspath(path) ? text : read(file["path"],String)
        push!(cases,Dict{String,Any}("case_id"=>file["case_id"],"label"=>String(file["label"]),
            "fuel_percent"=>file["fuel_percent"],"path"=>abspath(file["path"]),"deck_text"=>case_text,
            "lines"=>count(==('\n'),case_text),"bytes"=>sizeof(case_text),
            "sha256"=>bytes2hex(SHA.sha256(case_text))))
    end
    lock(st.deck_lock)
    try
        snapshot = Dict{String,Any}(
            "version" => 1, "deck_text" => text, "path" => abspath(path),
            "input_path" => st.input_path, "created_at" => string(Dates.now(Dates.UTC)) * "Z",
            "solution" => "SOL " * String(params["output.solution"]), "source" => source,
            "lines" => count(==('\n'), text), "bytes" => sizeof(text),
            "sha256" => bytes2hex(SHA.sha256(text)), "model_params" => deepcopy(params),
            "case_decks"=>cases,"case_decks_sha256"=>case_decks_digest(cases))
        validate_case_decks(snapshot)
        mkpath(st.deck_store_dir)
        temporary, io = mktemp(st.deck_store_dir)
        try
            write(io, JSON.json(snapshot)); flush(io); close(io)
            # rename replaces the previous file atomically, including on Windows.
            # Do not use mv(force=true), which first deletes the destination.
            Base.Filesystem.rename(temporary, joinpath(st.deck_store_dir, "last_deck.json"))
        finally
            isopen(io) && close(io)
            isfile(temporary) && rm(temporary)
        end
        st.latest_deck = snapshot
        return snapshot
    finally
        unlock(st.deck_lock)
    end
end

function write_and_preserve_deck!(st::AppState, model, path, params; source::String)
    # Serialize the write and read-back too: two browser windows targeting
    # the same BDF must not pair one request's text with another's parameters.
    lock(st.deck_lock)
    try
        written = write_nastran(model, path)
        return written, preserve_deck!(st, path, params; source,case_files=get(written,"files",Any[]))
    finally
        unlock(st.deck_lock)
    end
end

function handle_last_deck(st::AppState, req; download::Bool = false)
    lock(st.deck_lock)
    try
        # Re-read so another window/server using the same application store
        # cannot leave this process serving an older in-memory snapshot.
        snapshot = read_deck_snapshot(st)
        st.latest_deck = snapshot
        snapshot === nothing && return download ? error_response("No deck has been created yet."; status=404) :
            json_response(Dict("ok" => true, "available" => false))
        if download
            selected=snapshot
            query=HTTP.queryparams(HTTP.URI(req.target))
            if haskey(query,"case_id")
                id=tryparse(Int,query["case_id"])
                id!==nothing && id>0 || throw(ArgumentError("case_id must be a positive integer"))
                cases=get(snapshot,"case_decks",Any[])
                found=findfirst(row->row["case_id"]==id,cases)
                if found===nothing
                    isempty(cases) && id==1 || return error_response("No saved deck exists for case $id.";status=404)
                else
                    selected=cases[found]
                end
            end
            name = replace(basename(String(selected["path"])), r"[^A-Za-z0-9_.-]" => "_")
            return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store",
                "Content-Disposition" => "attachment; filename=\"" * name * "\""], selected["deck_text"])
        end
        return json_response(Dict("ok" => true, "available" => true, "deck" => snapshot))
    catch e
        return error_response("Last created deck: " * describe_error(e))
    finally
        unlock(st.deck_lock)
    end
end

function handle_nastran(st::AppState, req)
    progress = request_progress(st, req)
    try
        params = params_from_request(st, req)
        model = build_model(params; progress)
        st.params = params
        st.model = model
        path = resolve_output(st, String(params["output.nastran_file"]))
        progress("deck")
        result, snapshot = write_and_preserve_deck!(st, model, path, params; source = "Write deck")
        result["solution"] = "SOL " * String(params["output.solution"])
        result["checks_pass"] = all_checks_pass(model)
        result["deck_text"] = snapshot["deck_text"]
        result["deck_metadata"] = deck_metadata(snapshot)
        @info "NASTRAN deck written" path = result["path"] lines = result["lines"]
        return json_response(result)
    catch e
        @error "writing the NASTRAN deck failed" exception = (e, catch_backtrace())
        return error_response(describe_error(e))
    end
end

function handle_save_input(st::AppState, req)
    try
        params = params_from_request(st, req)
        for item in get(params, REFERENCE_METADATA_KEY, Any[])
            reference_asset_path(st, item["asset_path"]; must_exist=false)
        end
        text = params_to_toml(params)
        open(st.input_path, "w") do io
            write(io, text)
        end
        st.params = params
        @info "input file saved" path = st.input_path
        return json_response(Dict{String,Any}("ok" => true, "path" => st.input_path,
                                              "bytes" => sizeof(text)))
    catch e
        @error "saving the input file failed" exception = (e, catch_backtrace())
        return error_response(describe_error(e))
    end
end

"""
    handle_run_jfem(st, req)

Regenerate the model from the posted parameters, write the deck, then start
the solver and return the job id at once. The run itself is polled through
`/api/jfem_status`, so the browser is never left waiting on a request.
"""
function handle_run_jfem(st::AppState, req; start_job=start_jfem_job)
    progress = request_progress(st, req)
    lock(st.job_lock)
    try
        any(job.state===:running for job in values(st.sensitivity_jobs))&&throw(ArgumentError("Wait for the current sensitivity job or stop it before running another analysis"))
        # Check before replacing the deck or current model of an active run.
        for (_, j) in st.jobs
            if j.state === :running
                throw(ArgumentError(
                    "a JFEM run is already going (job $(j.id)). " *
                    "Wait for it or stop it first."))
            end
        end
        params = params_from_request(st, req)
        model = build_model(params; progress)
        st.params = params
        st.model = model
        bdf = resolve_output(st, String(params["output.nastran_file"]))
        progress("deck")
        written, snapshot = write_and_preserve_deck!(st, model, bdf, params; source = "Run in JFEM")

        st.job_counter += 1
        id = "job" * string(st.job_counter)
        job = start_job(model, params, st.root, bdf, id)
        st.jobs[id] = job
        return json_response(Dict{String,Any}(
            "ok" => true,
            "job" => id,
            "deck" => written["path"],
            "deck_lines" => written["lines"],
            "deck_text" => snapshot["deck_text"],
            "deck_metadata" => deck_metadata(snapshot),
            "solution" => "SOL " * String(params["output.solution"]),
            "out_dir" => job.outdir,
            "repo" => job.repo,
            "command" => job.cmdline,
            "runs" => [job_run_summary(child) for child in job.runs],
        ))
    catch e
        @error "starting the JFEM run failed" exception = (e, catch_backtrace())
        return error_response(describe_error(e))
    finally
        unlock(st.job_lock)
    end
end

"""
    handle_jfem_status(st, req)

Progress of a run: its state and any console lines the browser has not seen,
identified by the `from` query parameter.
"""
function handle_jfem_status(st::AppState, req)
    try
        job = get_job(st, req)
        q = HTTP.queryparams(HTTP.URI(req.target))
        from = something(tryparse(Int, get(q, "from", "0")), 0)

        batch=job_log_batch(job,from)
        return json_response(Dict{String,Any}(
            "ok" => true,
            "job" => job.id,
            "state" => String(job.state),
            "seconds" => round(job_seconds(job); digits = 2),
            "exit_code" => job.exitcode,
            "message" => job.message,
            "lines" => batch.lines,
            "next_line" => batch.next_line,
            "total_lines" => batch.total_lines,
            "first_line" => batch.first_line,
            "omitted_lines" => batch.omitted_lines,
            "has_more" => batch.has_more,
            "progress" => job_progress(job),
            "log_path" => job.logpath,
            "runs" => [job_run_summary(child) for child in job.runs],
            "results_available" => job_results_available(job),
        ))
    catch e
        return error_response(describe_error(e))
    end
end

"""Download the full known job log without buffering the file in server RAM.

For a running job the response is a snapshot ending at its current byte count.
Only registered jobs and their own child IDs are accepted, never file paths.
"""
function handle_jfem_log(st::AppState,req)
    try
        job=get_job(st,req)
        q=HTTP.queryparams(HTTP.URI(req.target))
        run_id=get(q,"run","")
        if !isempty(run_id)
            index=findfirst(child->child.id==run_id,job.runs)
            index===nothing && throw(ArgumentError("unknown child run for this job"))
            job=job.runs[index]
        end
        isfile(job.logpath) || throw(ArgumentError("the run has not written a log yet"))
        io=open(job.logpath,"r")
        try
            count=filesize(io); remaining=Ref(count)
            body=HTTP.CallbackBody(dst->begin
                n=readbytes!(io,dst,min(length(dst),remaining[]))
                remaining[]-=n
                n
            end,()->close(io))
            name=replace(job.id,r"[^A-Za-z0-9_.-]"=>"_")*"_jfem.log"
            return HTTP.Response(200,body;content_length=count,headers=[
                "Content-Type"=>"text/plain; charset=utf-8",
                "Content-Disposition"=>"attachment; filename=\"$name\"",
                "Cache-Control"=>"no-store"])
        catch
            close(io)
            rethrow()
        end
    catch e
        return error_response(describe_error(e))
    end
end

"""
    handle_jfem_results(st, req)

Read the finished run and send the results to the viewer as MsgPack.
"""
function handle_jfem_results(st::AppState, req)
    try
        job = get_job(st, req)
        job.state === :running &&
            throw(ArgumentError("the run is still going"))
        payload = jfem_results_payload(job)
        @info "JFEM results read" analysis = payload["analysis_type"] job = job.id
        return msgpack_response(payload)
    catch e
        @error "reading the JFEM results failed" exception = (e, catch_backtrace())
        return error_response(describe_error(e))
    end
end

"""
    handle_jfem_stop(st, req)

Stop a running solver process.
"""
function handle_jfem_stop(st::AppState, req)
    try
        job = get_job(st, req)
        kill_job!(job)
        return json_response(Dict{String,Any}("ok" => true, "job" => job.id,
                                              "state" => String(job.state)))
    catch e
        return error_response(describe_error(e))
    end
end

"""
    handle_jfem_probe(st, req)

Report whether the solver can be found, so the web app can enable or explain
the Run button before anything is submitted.
"""
function handle_jfem_probe(st::AppState, req)
    try
        hint = String(get(st.params, "jfem.repo", ""))
        repo, launcher = find_jfem(st.root; hint = hint)
        return json_response(Dict{String,Any}(
            "ok" => true,
            "found" => repo !== nothing,
            "repo" => repo === nothing ? "" : repo,
            "launcher" => launcher === nothing ? "" : launcher,
        ))
    catch e
        return json_response(Dict{String,Any}("ok" => true, "found" => false,
                                              "repo" => "", "launcher" => "",
                                              "error" => describe_error(e)))
    end
end

function handle_shutdown(st::AppState, req)
    st.running = false
    @info "shutdown requested by the web app"
    return json_response(Dict{String,Any}("ok" => true, "message" => "server stopping"))
end

"""
    make_router(st) -> HTTP.Router

Wire the endpoints and the static file handler.
"""
function make_router(st::AppState)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/api/input", req -> handle_input(st, req))
    HTTP.register!(router, "GET", "/api/input_text", req -> handle_input_text(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/catalog", req -> handle_sensitivity_catalog(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/run", req -> handle_sensitivity_run(st, req))
    HTTP.register!(router, "GET", "/api/sensitivity/status", req -> handle_sensitivity_status(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/stop", req -> handle_sensitivity_stop(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/saved/list", req -> handle_sensitivity_saved_list(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/saved/load", req -> handle_sensitivity_saved_load(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/baseline", req -> handle_sensitivity_baseline(st, req))
    HTTP.register!(router, "POST", "/api/sensitivity/baseline/download", req -> handle_sensitivity_baseline_download(st, req))
    HTTP.register!(router, "GET", "/api/activity", req -> handle_activity(st, req))
    HTTP.register!(router, "GET", "/api/airfoils", req -> handle_airfoils(st, req))
    HTTP.register!(router, "GET", "/api/airfoils/profile", req -> handle_airfoils(st, req;profile=true))
    HTTP.register!(router, "POST", "/api/generate", req -> handle_generate(st, req))
    HTTP.register!(router, "POST", "/api/validate_workspace", req -> handle_workspace(st, req))
    HTTP.register!(router, "POST", "/api/prepare_workspace", req -> handle_workspace(st, req; generate = true))
    HTTP.register!(router, "POST", "/api/import_toml", req -> handle_import_toml(st, req))
    HTTP.register!(router, "POST", "/api/export_toml", req -> handle_export_toml(st, req))
    HTTP.register!(router, "POST", "/api/nastran", req -> handle_nastran(st, req))
    HTTP.register!(router, "GET", "/api/last_deck", req -> handle_last_deck(st, req))
    HTTP.register!(router, "GET", "/api/last_deck/download", req -> handle_last_deck(st, req; download=true))
    HTTP.register!(router, "POST", "/api/save_input", req -> handle_save_input(st, req))
    HTTP.register!(router, "POST", "/api/reference_upload", req -> handle_upload_reference(st, req))
    HTTP.register!(router, "GET", "/api/reference_asset", req -> handle_reference_asset(st, req))
    HTTP.register!(router, "POST", "/api/save_references", req -> handle_save_references(st, req))
    HTTP.register!(router, "GET", "/api/jfem_probe", req -> handle_jfem_probe(st, req))
    HTTP.register!(router, "POST", "/api/run_jfem", req -> handle_run_jfem(st, req))
    HTTP.register!(router, "GET", "/api/jfem_status", req -> handle_jfem_status(st, req))
    HTTP.register!(router, "GET", "/api/jfem_log", req -> handle_jfem_log(st, req))
    HTTP.register!(router, "GET", "/api/jfem_results", req -> handle_jfem_results(st, req))
    HTTP.register!(router, "POST", "/api/jfem_stop", req -> handle_jfem_stop(st, req))
    HTTP.register!(router, "POST", "/api/shutdown", req -> handle_shutdown(st, req))
    HTTP.register!(router, "GET", "/", req -> serve_asset(st, req))
    HTTP.register!(router, "GET", "/**", req -> serve_asset(st, req))
    return router
end

"""
    open_browser(url)

Open the default browser on `url`, ignoring failures so a headless machine
still leaves the server running.
"""
function open_browser(url::AbstractString)
    try
        if Sys.iswindows()
            run(Cmd(["cmd", "/c", "start", "", url]); wait = false)
        elseif Sys.isapple()
            run(Cmd(["open", url]); wait = false)
        else
            run(Cmd(["xdg-open", url]); wait = false)
        end
    catch e
        @warn "could not open a browser automatically; open the URL by hand" url
    end
    return nothing
end

"""
    run_app(input_path; port = 8080, root = ..., launch_browser = true)

Start the web application: serve the Babylon.js front end, wait for requests
and return when the browser asks the server to shut down or the user
interrupts with Ctrl-C.
"""
function run_app(input_path::AbstractString;
                 port::Int = 8080,
                 root::AbstractString = dirname(@__DIR__),
                 launch_browser::Bool = true,
                 on_ready::Function = () -> nothing)
    st = AppState(root, input_path)
    isdir(st.webdir) || error("web assets not found at $(st.webdir)")
    router = make_router(st)

    server = nothing
    actual = port
    for p in port:port+20
        try
            server = HTTP.serve!(router, "127.0.0.1", p)
            actual = p
            break
        catch e
            e isa Base.IOError || rethrow()
            @info "port busy, trying the next one" port = p
        end
    end
    server === nothing && error("no free port in the range $port to $(port+20)")

    url = "http://127.0.0.1:$actual/"
    on_ready()
    println()
    println("  WingFEGen is running")
    println("  input file : ", st.input_path)
    println("  web app    : ", url)
    println("  press Ctrl-C in this window to stop")
    println()
    launch_browser && open_browser(url)

    try
        while st.running
            sleep(0.2)
        end
    catch e
        e isa InterruptException || rethrow()
        println("\ninterrupted")
    finally
        close(server)
    end
    println("WingFEGen stopped")
    return nothing
end
