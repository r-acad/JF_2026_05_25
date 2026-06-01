# =============================================================================
# panel_server.jl - pure-Julia msgpack-over-HTTP bridge for panel_app.html
#
# Serves the stiffened-panel web app AND runs SOL 105 buckling through OpenJFEM.
# No Python anywhere. Uses HTTP.jl + MsgPack.jl (added to the OpenJFEM project).
#
#   browser  --(GET /)------------------>  serves panel_app.html
#   browser  --(POST /analyze, msgpack)->  writes <case>.bdf, runs JFEM,
#                                           returns eigenvalues + .jfem bytes
#
# The solver runs in THIS process: OpenJFEM is loaded once, so only the first
# analysis pays Julia's compile cost; later runs are warm.
#
# Usage:
#   julia --project=. --threads=auto JFEM/POST/panel_server.jl [--port 8088] [--no-open]
#
# Normally you launch it via panel_launch.jl, which also opens the browser.
# =============================================================================

using HTTP
using MsgPack
using JSON
using Dates
using Sockets

using OpenJFEM   # provided by --project=. ; loads the solver once

# --- repo / path layout ------------------------------------------------------
const POST_DIR  = @__DIR__                                   # <repo>/JFEM/POST
const REPO_ROOT = normpath(joinpath(POST_DIR, ".."))         # <repo>/JFEM
const APP_HTML  = joinpath(POST_DIR, "panel_app.html")
const RUN_ROOT  = joinpath(POST_DIR, "panel_runs")

# Pull in the manifest batch runner so we reuse the exact production path
# (export options, flags, .jfem + .BUCKLING.JSON + .REPORT.md writing).
include(joinpath(REPO_ROOT, "tools", "testing", "run_manifest.jl"))
include(joinpath(REPO_ROOT, "tools", "manifest_batch_core.jl"))

# Serialize solver work: one run at a time through the single process.
const SOLVE_LOCK = ReentrantLock()

_log(msg) = (println(stderr, "[", Dates.format(now(), "HH:MM:SS"), "] ", msg); flush(stderr))

# --- CORS / response helpers -------------------------------------------------
const CORS_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type",
]

_msgpack_response(obj; status=200) = HTTP.Response(
    status,
    ["Content-Type" => "application/msgpack"; CORS_HEADERS...],
    MsgPack.pack(obj),
)

# --- read the trailing 'EVAL' Float64 footer from a v4 .jfem (fallback) ------
function _eigenvalues_from_jfem(buf::Vector{UInt8})
    marker = UInt8['E', 'V', 'A', 'L']
    # scan backwards for the last EVAL whose count consumes exactly to EOF
    n = length(buf)
    i = n - 7
    while i >= 1
        if buf[i] == marker[1] && buf[i+1] == marker[2] &&
           buf[i+2] == marker[3] && buf[i+3] == marker[4]
            pos = i + 4
            if pos + 3 <= n
                cnt = reinterpret(UInt32, buf[pos:pos+3])[1]
                payload = pos + 4
                if cnt > 0 && payload + 8 * cnt - 1 == n
                    out = Vector{Float64}(undef, cnt)
                    for k in 1:cnt
                        b = payload + 8 * (k - 1)
                        out[k] = reinterpret(Float64, buf[b:b+7])[1]
                    end
                    return out
                end
            end
        end
        i -= 1
    end
    return Float64[]
end

_first_existing(dir, names) = begin
    hit = nothing
    for nm in names
        p = joinpath(dir, nm)
        if isfile(p); hit = p; break; end
    end
    hit
end

# --- the core: write deck, run a one-case manifest, collect artifacts --------
function run_analysis(payload::AbstractDict)
    case_id = string(get(payload, "case_id", "panel_" *
                Dates.format(now(UTC), "yyyymmdd_HHMMSS_sss")))
    out_dir = joinpath(RUN_ROOT, case_id)
    mkpath(out_dir)

    # resolve the deck
    bdf_path = ""
    if haskey(payload, "bdf_path") && !isempty(string(payload["bdf_path"]))
        bdf_path = abspath(string(payload["bdf_path"]))
        isfile(bdf_path) || error("bdf_path not found: $bdf_path")
    else
        bdf_text = string(get(payload, "bdf", ""))
        isempty(strip(bdf_text)) && error("payload needs a non-empty 'bdf' string or 'bdf_path'")
        bdf_path = joinpath(out_dir, case_id * ".bdf")
        write(bdf_path, bdf_text)
        _log("wrote deck: $bdf_path")
    end
    stem = replace(basename(bdf_path), r"(?i)\.bdf$" => "")

    # one-case manifest, mode shapes enabled for the viewer
    manifest = Dict{String,Any}(
        "output_root" => RUN_ROOT,
        "defaults" => Dict{String,Any}(
            "options" => Dict{String,Any}(
                "binary" => true,        # write <stem>.jfem (v4)
                "json" => true,          # write <stem>.BUCKLING.JSON
                "eigenvectors" => true,  # mode shapes into .jfem / JSON
                "report" => true,        # <stem>.REPORT.md
            ),
            "flags" => Dict{String,Any}(
                "JFEM_EXPORT_BINARY" => "true",
                "JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES" => "true",
                "JFEM_SUPPRESS_THREAD_HINT" => "1",
            ),
        ),
        "cases" => Any[Dict{String,Any}(
            "case_id" => case_id,
            "input" => bdf_path,
            "output_dir" => out_dir,
        )],
    )

    t0 = time_ns()
    summary = lock(SOLVE_LOCK) do
        default_flags = manifest_default_flags(manifest)
        manifest_apply_flags!(default_flags)
        run_batch_manifest!(manifest;
            manifest_path=nothing,
            repo_root=REPO_ROOT,
            script_path=@__FILE__,
            args=String[],
            quiet=true)
    end
    elapsed = (time_ns() - t0) * 1e-9
    _log("solve finished in $(round(elapsed; digits=1))s")

    # collect artifacts
    jfem_path = _first_existing(out_dir, [stem * ".jfem"])
    buckling_path = _first_existing(out_dir, [stem * ".BUCKLING.JSON"])
    report_path = _first_existing(out_dir, [stem * ".REPORT.md"])
    log_path = _first_existing(out_dir, ["jfem_case_stdout.log"])

    jfem_bytes = jfem_path === nothing ? UInt8[] : read(jfem_path)
    eigenvalues = Float64[]
    buckling = nothing
    if buckling_path !== nothing
        try
            buckling = JSON.parsefile(buckling_path)
            if buckling isa AbstractDict && haskey(buckling, "eigenvalues")
                eigenvalues = Float64.(buckling["eigenvalues"])
            end
        catch err
            _log("WARN: could not parse buckling JSON: $err")
        end
    end
    if isempty(eigenvalues) && !isempty(jfem_bytes)
        eigenvalues = _eigenvalues_from_jfem(jfem_bytes)
    end

    run_log = ""
    if log_path !== nothing
        try
            txt = read(log_path, String)
            run_log = length(txt) > 8000 ? txt[end-7999:end] : txt
        catch; end
    end

    failed = Int(get(summary, "failed", 1))
    ok = failed == 0 && !isempty(jfem_bytes)
    return Dict{String,Any}(
        "ok" => ok,
        "case_id" => case_id,
        "bdf_path" => bdf_path,
        "output_dir" => out_dir,
        "jfem_path" => jfem_path === nothing ? "" : jfem_path,
        "jfem_bytes" => jfem_bytes,           # msgpack bin -> Uint8Array in browser
        "report_path" => report_path === nothing ? "" : report_path,
        "eigenvalues" => eigenvalues,
        "elapsed_s" => round(elapsed; digits=3),
        "log" => run_log,
    )
end

# Map a file extension to a Content-Type for the small set of static files we serve.
function _content_type(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".js"   && return "application/javascript; charset=utf-8"
    ext == ".html" && return "text/html; charset=utf-8"
    ext == ".css"  && return "text/css; charset=utf-8"
    ext == ".json" && return "application/json; charset=utf-8"
    ext == ".map"  && return "application/json; charset=utf-8"
    ext == ".wasm" && return "application/wasm"
    return "application/octet-stream"
end

# --- HTTP routing ------------------------------------------------------------
function handle(req::HTTP.Request)
    method = req.method
    target = HTTP.URI(req.target).path

    if method == "OPTIONS"
        return HTTP.Response(204, CORS_HEADERS)
    end

    if method == "GET" && (target == "/" || target == "/panel_app.html" || target == "/index.html")
        if isfile(APP_HTML)
            return HTTP.Response(200,
                ["Content-Type" => "text/html; charset=utf-8"; CORS_HEADERS...],
                read(APP_HTML))
        end
        return HTTP.Response(404, "panel_app.html not found at $APP_HTML")
    end

    if method == "GET" && (target == "/health" || target == "/ping")
        return _msgpack_response(Dict("ok" => true, "service" => "panel-server"))
    end

    # Static files: ONLY the vendored front-end libs under /vendor/.
    # Restricting to vendor/ (rather than all of POST/) avoids serving source
    # files like panel_server.jl, and the resolved-path containment check below
    # blocks any "/../" traversal regardless of how the client normalizes it.
    if method == "GET" && startswith(target, "/vendor/")
        try
            rel = String(lstrip(target, '/'))               # e.g. "vendor/babylon.js"
            path = normpath(joinpath(POST_DIR, rel))
            vendor_root = normpath(joinpath(POST_DIR, "vendor"))
            if startswith(path, vendor_root) && isfile(path)
                return HTTP.Response(200,
                    ["Content-Type" => _content_type(path),
                     "Cache-Control" => "public, max-age=86400",
                     CORS_HEADERS...],
                    read(path))
            end
            return HTTP.Response(404, "not found: $target")
        catch err
            _log("ERROR serving static $target: $(sprint(showerror, err))")
            return HTTP.Response(500, "static file error: $(sprint(showerror, err))")
        end
    end

    if method == "POST" && target == "/analyze"
        try
            payload = isempty(req.body) ? Dict{String,Any}() : MsgPack.unpack(req.body)
            payload isa AbstractDict || error("request body must be a msgpack map")
            _log("/analyze case_id=$(get(payload,"case_id","?")) bytes_in=$(length(req.body))")
            result = run_analysis(payload)
            return _msgpack_response(result)
        catch err
            bt = sprint(showerror, err, catch_backtrace())
            _log("ERROR in /analyze: $bt")
            return _msgpack_response(Dict("ok" => false, "error" => sprint(showerror, err),
                                          "traceback" => bt); status=500)
        end
    end

    return _msgpack_response(Dict("ok" => false, "error" => "not found: $method $target"); status=404)
end

# --- startup warm-up ---------------------------------------------------------
# Julia JIT-compiles lazily: HTTP.jl, the request handler, msgpack (de)coding and
# the whole OpenJFEM solver only compile on their FIRST use. Without warm-up that
# first use is the browser's first page request and the first Analyze, so the user
# stares at a blank tab for ~30-50s. We force those compiles HERE, before binding
# the socket (so the launcher's TCP poll - and therefore the browser - waits until
# we're warm). The wait moves into the "PLEASE WAIT" startup banner where it belongs.
function _warmup()
    # 1) HTTP request-handling path: drive synthetic requests straight through
    #    handle() (no network needed). Compiles HTTP.Request/Response + routing +
    #    static-file read + msgpack packing.
    try
        for tgt in ("/", "/health", "/vendor/msgpack.min.js")
            handle(HTTP.Request("GET", tgt))
        end
        # OPTIONS (CORS preflight) path too.
        handle(HTTP.Request("OPTIONS", "/analyze"))
    catch err
        _log("WARN: handler warm-up hit an error (non-fatal): $(sprint(showerror, err))")
    end
    # 2) Solver path: run one tiny SOL105 solve so the FIRST real Analyze is fast.
    #    A 2x1 single-element strip is enough to compile the assemble/solve/export
    #    code; its output is discarded.
    try
        warm_bdf = """
        SOL 105
        CEND
        TITLE = warmup
        SUBCASE 1
          SPC = 10
          LOAD = 20
        SUBCASE 2
          STATSUB = 1
          METHOD = 30
        BEGIN BULK
        PARAM,POST,-1
        MAT1,100,71000.,,0.33,2.7e-9
        PSHELL,1,100,2.,100,1.,100
        GRID,1,0,0.,0.,0.
        GRID,2,0,10.,0.,0.
        GRID,3,0,10.,10.,0.
        GRID,4,0,0.,10.,0.
        CQUAD4,1,1,1,2,3,4
        SPC1,10,123,1,4
        SPC1,10,3,2,3
        FORCE,20,2,0,1.,0.,-1.,0.
        FORCE,20,3,0,1.,0.,-1.,0.
        EIGRL,30,,,2
        ENDDATA
        """
        run_analysis(Dict{String,Any}("case_id" => "_warmup", "bdf" => warm_bdf))
        # clean the throwaway run dir
        wdir = joinpath(RUN_ROOT, "_warmup")
        isdir(wdir) && rm(wdir; recursive=true, force=true)
    catch err
        _log("WARN: solver warm-up hit an error (non-fatal; first Analyze will just be slower): $(sprint(showerror, err))")
    end
end

function serve(; host="127.0.0.1", port=8088)
    mkpath(RUN_ROOT)
    # Warm up the HTTP handler + solver BEFORE binding the socket, so the launcher
    # (which polls the TCP port) opens the browser only once we can answer fast.
    _log("warming up (compiling HTTP handler + solver; this is the one-time wait)...")
    t_warm = time_ns()
    _warmup()
    _log("warm-up done in $(round((time_ns()-t_warm)*1e-9; digits=1))s")
    # Bind the listening socket explicitly so we can (a) detect a port clash with
    # a clear message and (b) only announce "listening" once the bind succeeded.
    local server
    try
        server = Sockets.listen(Sockets.getaddrinfo(host), port)
    catch err
        _log("ERROR: could not bind http://$host:$port  ($(sprint(showerror, err)))")
        _log("       Another panel server is probably already running on that port.")
        _log("       Open the app at http://$host:$port/ in your browser, OR stop the")
        _log("       other server / pick another port:  --port 8090")
        rethrow()
    end
    _log("panel server listening on http://$host:$port  (warm: page + first Analyze are fast)")
    _log("  app:      http://$host:$port/")
    _log("  repo:     $REPO_ROOT")
    _log("  runs:     $RUN_ROOT")
    HTTP.serve(handle, server)
end

# --- CLI ---------------------------------------------------------------------
function _parse_cli(args)
    port = 8088
    host = "127.0.0.1"
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--port" && i < length(args)
            port = parse(Int, args[i+1]); i += 2
        elseif a == "--host" && i < length(args)
            host = args[i+1]; i += 2
        else
            i += 1
        end
    end
    return host, port
end

if abspath(PROGRAM_FILE) == @__FILE__
    host, port = _parse_cli(ARGS)
    serve(; host=host, port=port)
end
