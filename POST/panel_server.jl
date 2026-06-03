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
using LinearAlgebra   # BLAS.set_num_threads for dense-solve thread tuning

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

# Report whether THIS process is running inside a custom sysimage (loaded via -J)
# vs the default Julia system image. This is how we confirm the web app is
# actually getting the sysimage's fast startup, rather than just assuming it.
function _sysimage_info()
    img = try
        unsafe_string(Base.JLOptions().image_file)
    catch
        ""
    end
    # The default image is "<...>/lib/julia/sys.dll|so|dylib"; anything else
    # (e.g. our OpenJFEM_sysimage.dll) is a custom sysimage.
    is_custom = !isempty(img) && !occursin(r"(?i)[\\/]sys\.(dll|so|dylib)$", img)
    return Dict{String,Any}(
        "custom" => is_custom,
        "image_file" => img,
        "name" => isempty(img) ? "" : basename(img),
    )
end

# Number of PHYSICAL cores (not hyperthreads). Dense BLAS (the Cholesky factor in
# SOL 101/105 and the eigensolve in SOL 103/105) is fastest at the physical core
# count; using all logical processors (hyperthreads) is measurably slower for
# dense linear algebra. Julia has no stdlib physical-core query, so we ask the OS
# and fall back to the logical count if that fails.
function _physical_cores()
    try
        if Sys.iswindows()
            out = read(`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum"`, String)
            n = tryparse(Int, strip(out)); n !== nothing && n > 0 && return n
        elseif Sys.islinux()
            # count unique (physical id, core id) pairs in /proc/cpuinfo
            pairs = Set{Tuple{String,String}}(); pid = ""; cid = ""
            for ln in eachline("/proc/cpuinfo")
                if startswith(ln, "physical id"); pid = strip(split(ln, ':')[end]); end
                if startswith(ln, "core id");     cid = strip(split(ln, ':')[end]); end
                if isempty(strip(ln)) && !isempty(pid) && !isempty(cid)
                    push!(pairs, (pid, cid)); pid = ""; cid = ""
                end
            end
            !isempty(pairs) && return length(pairs)
        elseif Sys.isapple()
            out = read(`sysctl -n hw.physicalcpu`, String)
            n = tryparse(Int, strip(out)); n !== nothing && n > 0 && return n
        end
    catch
    end
    return Sys.CPU_THREADS
end

# Set the BLAS thread count to the optimum for dense factorization/eigensolve.
# Called once at server startup so every solve's BLAS phase runs at full physical
# throughput (the assembly path still pins BLAS to 1 and restores to THIS value).
function _tune_blas_threads!()
    nphys = _physical_cores()
    # never exceed available logical processors; never below 1
    target = clamp(nphys, 1, Sys.CPU_THREADS)
    LinearAlgebra.BLAS.set_num_threads(target)
    return target
end

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

# Detect the solution-sequence number from a deck's executive control. Mirrors
# the solver's own parsing (regex on the "SOL <n>" line); defaults to 101 when
# absent. Only the first ~200 lines are scanned (the SOL line precedes CEND).
function _detect_sol(deck_path::AbstractString)
    found = nothing
    try
        open(deck_path, "r") do io
            for _ in 1:200
                eof(io) && break
                ln = strip(uppercase(readline(io)))
                startswith(ln, "BEGIN BULK") && break   # exec control is over
                m = match(r"^SOL\s+(\d+)", ln)
                # NOTE: a bare `return` here would only exit this do-block closure,
                # not _detect_sol - so capture into `found` and break instead.
                if m !== nothing
                    found = parse(Int, m.captures[1])
                    break
                end
            end
        end
    catch err
        _log("WARN: could not detect SOL from $deck_path: $(sprint(showerror, err))")
    end
    return found === nothing ? 101 : found
end

# Human-readable analysis label for a SOL number (SOL 63 is normal modes too).
function _analysis_type(sol::Integer)
    sol = (sol == 63) ? 103 : sol
    sol == 101 && return "SOL101_STATIC"
    sol == 103 && return "SOL103_MODES"
    sol == 105 && return "SOL105_BUCKLING"
    sol == 106 && return "SOL106_NONLINEAR"
    return "SOL$(sol)"
end

# Parse the "Pipeline timing" table out of a REPORT.md into a phase => seconds
# map, so the server can show WHERE a slow run spent its time (parse vs assemble
# vs solve vs export). The report rows look like "| BDF parsing | 0.012 s |".
function _parse_report_timings(report_text::AbstractString)
    timings = Dict{String,Float64}()
    isempty(report_text) && return timings
    in_table = false
    for raw in split(report_text, '\n')
        ln = strip(raw)
        if occursin("Pipeline timing", ln); in_table = true; continue; end
        if in_table
            # stop at the next top-level heading after the timing section
            startswith(ln, "## ") && break
            startswith(ln, "|") || continue
            # "| label | 1.234 s |"  (also handles "**Total ...**" and "ms")
            m = match(r"^\|\s*(.+?)\s*\|\s*([\d.]+)\s*(ms|s)\s*\|", ln)
            m === nothing && continue
            label = replace(strip(m.captures[1]), "**" => "")
            val = parse(Float64, m.captures[2])
            m.captures[3] == "ms" && (val /= 1000)
            timings[label] = val
        end
    end
    return timings
end

# --- the core: write deck, run a one-case manifest, collect artifacts --------
function run_analysis(payload::AbstractDict)
    case_id = string(get(payload, "case_id", "panel_" *
                Dates.format(now(UTC), "yyyymmdd_HHMMSS_sss")))
    out_dir = joinpath(RUN_ROOT, case_id)
    mkpath(out_dir)

    # Resolve the deck. A server-side path is run IN PLACE (we pass the original
    # absolute path to the solver) so that any INCLUDE cards resolve relative to
    # the deck's own directory. Decks supplied as 'bdf' text (the form-built
    # panel, or a browser-uploaded file's contents) are written into this case's
    # run dir; uploaded files carry a 'filename' hint so the stem/name is real.
    bdf_path = ""
    if haskey(payload, "bdf_path") && !isempty(string(payload["bdf_path"]))
        bdf_path = abspath(string(payload["bdf_path"]))
        isfile(bdf_path) || error("bdf_path not found: $bdf_path")
    else
        bdf_text = string(get(payload, "bdf", ""))
        isempty(strip(bdf_text)) && error("payload needs a non-empty 'bdf' string or 'bdf_path'")
        # name the written deck from the upload's filename when provided, else the
        # case id. Sanitize to a bare basename so a stray path can't escape out_dir.
        raw_name = strip(string(get(payload, "filename", "")))
        fname = isempty(raw_name) ? (case_id * ".bdf") : basename(replace(raw_name, '\\' => '/'))
        occursin(r"(?i)\.(bdf|dat|nas)$", fname) || (fname *= ".bdf")
        bdf_path = joinpath(out_dir, fname)
        write(bdf_path, bdf_text)
        _log("wrote deck: $bdf_path")
    end
    # strip a .bdf / .dat / .nas extension to get the output stem
    stem = replace(basename(bdf_path), r"(?i)\.(bdf|dat|nas)$" => "")
    sol = _detect_sol(bdf_path)
    analysis_type = _analysis_type(sol)
    _log("deck SOL=$sol ($analysis_type): $bdf_path")

    # One-case manifest. Export options are SOL-agnostic: binary .jfem (the 3D
    # viewer reads v3/v4/v5 from any SOL), the per-SOL results JSON, mode/eigen-
    # vectors, and the markdown report. We do NOT inject EIGRL/METHOD or force a
    # mode count - an uploaded deck's own EIGRL is respected.
    # NOTE: the manifest core reads these under "output_options" (NOT "options");
    # the latter is silently ignored, which suppresses the results JSON and the
    # stored mode-shape eigenvectors.
    manifest = Dict{String,Any}(
        "output_root" => RUN_ROOT,
        "defaults" => Dict{String,Any}(
            "output_options" => Dict{String,Any}(
                "binary" => true,        # write <stem>.jfem
                "json" => true,          # write the per-SOL results JSON
                "eigenvectors" => true,  # mode shapes into .jfem / JSON (103/105)
                "report" => true,        # <stem>.REPORT.md
            ),
            "flags" => Dict{String,Any}(
                "JFEM_EXPORT_BINARY" => "true",
                # store public mode shapes so SOL 103/105 modes reach the viewer;
                # harmless for SOL 101/106 (no eigen modes to store).
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
    # Run the (potentially long) solve on a worker thread and `fetch` it, instead
    # of running it directly on the HTTP handler task. This keeps the HTTP event
    # loop responsive during a multi-minute solve, so health checks and other
    # requests are still served and connections are not starved/cancelled. The
    # SOLVE_LOCK still serialises solves to one at a time.
    summary = fetch(Threads.@spawn begin
        lock(SOLVE_LOCK) do
            default_flags = manifest_default_flags(manifest)
            manifest_apply_flags!(default_flags)
            run_batch_manifest!(manifest;
                manifest_path=nothing,
                repo_root=REPO_ROOT,
                script_path=@__FILE__,
                args=String[],
                quiet=true)
        end
    end)
    elapsed = (time_ns() - t0) * 1e-9
    _log("solve finished in $(round(elapsed; digits=1))s")

    # collect artifacts
    jfem_path = _first_existing(out_dir, [stem * ".jfem"])
    report_path = _first_existing(out_dir, [stem * ".REPORT.md"])
    log_path = _first_existing(out_dir, ["jfem_case_stdout.log"])
    # The results JSON name depends on the SOL: 103/105 -> .BUCKLING.JSON,
    # 101 -> .JU.JSON, 106 -> .NONLINEAR.JSON, 200 -> .OPTIMIZATION.JSON. Probe
    # all of them so the server stays SOL-agnostic.
    json_path = _first_existing(out_dir, [
        stem * ".BUCKLING.JSON",
        stem * ".JU.JSON",
        stem * ".NONLINEAR.JSON",
        stem * ".OPTIMIZATION.JSON",
    ])

    jfem_bytes = jfem_path === nothing ? UInt8[] : read(jfem_path)
    eigenvalues = Float64[]
    frequencies = Float64[]
    if json_path !== nothing
        try
            j = JSON.parsefile(json_path)
            if j isa AbstractDict
                # buckling load factors (105) or eigenvalues (103)
                haskey(j, "eigenvalues") && (eigenvalues = Float64.(j["eigenvalues"]))
                # natural frequencies in Hz (103)
                haskey(j, "frequencies") && (frequencies = Float64.(j["frequencies"]))
            end
        catch err
            _log("WARN: could not parse results JSON $(basename(json_path)): $err")
        end
    end
    # eigen footer in the .jfem is the fallback for 103/105 eigenvalues
    if isempty(eigenvalues) && !isempty(jfem_bytes)
        eigenvalues = _eigenvalues_from_jfem(jfem_bytes)
    end

    # The markdown report text (sent to the browser so the user sees a summary).
    # Parse the pipeline timing table from the FULL report first, then truncate
    # the copy that goes to the browser.
    report_text = ""
    timings = Dict{String,Float64}()
    if report_path !== nothing
        try
            txt = read(report_path, String)
            timings = _parse_report_timings(txt)
            report_text = length(txt) > 20000 ? txt[1:20000] * "\n... (truncated)" : txt
        catch; end
    end
    # Log WHERE the time went, so a "slow" run is diagnosable from the server
    # window without guessing. Shows the main phases when the report had them.
    if !isempty(timings)
        _phase(k) = haskey(timings, k) ? "$(round(timings[k]; digits=2))s" : "-"
        _log("timing: parse=$(_phase("BDF parsing"))  build=$(_phase("Model construction"))  " *
             "solve=$(_phase("Solve (total)"))  export=$(_phase("Export (all formats)"))  " *
             "[wall=$(round(elapsed; digits=1))s]")
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
        "sol" => sol,
        "analysis_type" => analysis_type,
        "bdf_path" => bdf_path,
        "output_dir" => out_dir,
        "jfem_path" => jfem_path === nothing ? "" : jfem_path,
        "jfem_bytes" => jfem_bytes,           # msgpack bin -> Uint8Array in browser
        "report_path" => report_path === nothing ? "" : report_path,
        "report" => report_text,
        "eigenvalues" => eigenvalues,
        "frequencies" => frequencies,
        "elapsed_s" => round(elapsed; digits=3),
        "timings" => timings,        # phase => seconds, parsed from the report
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
        return _msgpack_response(Dict(
            "ok" => true,
            "service" => "panel-server",
            "sysimage" => _sysimage_info(),
            "threads" => Threads.nthreads(),
        ))
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
    # Use all PHYSICAL cores for dense BLAS (Cholesky/eigensolve). OpenBLAS
    # defaults to ~half the logical processors; the physical-core count is the
    # fastest setting for FE factorization (hyperthreads slow dense BLAS down).
    let nblas = _tune_blas_threads!()
        _log("BLAS threads set to $nblas (physical cores; logical=$(Sys.CPU_THREADS), Julia threads=$(Threads.nthreads()))")
    end
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
    let si = _sysimage_info()
        if si["custom"]
            _log("  sysimage: YES ($(si["name"]))  -  fast startup active")
        else
            _log("  sysimage: NO (default Julia image)  -  build POST/build_sysimage.cmd for fast startup")
        end
        _log("  threads:  $(Threads.nthreads())")
    end
    # HTTP.serve normally blocks forever. If it RETURNS or THROWS, the process is
    # about to stop - say WHY, so the launcher window does not just close silently.
    # (Note: an out-of-memory kill by the OS terminates the process abruptly and
    # cannot be caught here; the front end detects that as a dropped connection.)
    try
        # readtimeout=0 disables the idle-connection timeout: a large model can
        # keep the /analyze connection open for minutes while the solve runs, and
        # we must not drop it. verbose=false keeps the per-connection chatter down
        # (a client that navigates away mid-solve otherwise logs a stack trace).
        HTTP.serve(handle, server; readtimeout=0, verbose=false)
        _log("server loop ended normally (listening socket closed). Stopping.")
    catch err
        if err isa InterruptException
            _log("server stopped by Ctrl+C / interrupt.")
        else
            _log("ERROR: server loop crashed - stopping. Reason:")
            _log(sprint(showerror, err, catch_backtrace()))
        end
        rethrow()
    finally
        try; isopen(server) && close(server); catch; end
    end
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
