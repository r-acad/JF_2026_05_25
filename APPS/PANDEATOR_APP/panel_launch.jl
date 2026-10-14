# =============================================================================
# panel_launch.jl - cross-platform launcher for the stiffened-panel web app.
#
# Starts the pure-Julia panel server in this process and opens the default
# browser at the app URL. Works on Windows, macOS, and Linux.
#
#   julia --project=<JFEM> --threads=auto JFEM/APPS/PANDEATOR_APP/panel_launch.jl [--port 8088] [--no-open]
#
# It picks the OpenJFEM project automatically (the JFEM folder two levels up),
# so you can run it from anywhere. Press Ctrl+C to stop the server.
# =============================================================================

const _APP_DIR  = @__DIR__
const _REPO_ROOT = normpath(joinpath(_APP_DIR, "..", ".."))   # <repo>/JFEM (the project)

# Parse args
port = 8088
do_open = true
let i = 1
    global port, do_open
    while i <= length(ARGS)
        a = ARGS[i]
        if a in ("--help", "-h")
            println("Usage: julia --startup-file=no --project=. APPS/PANDEATOR_APP/panel_launch.jl [--port 8088] [--no-open]")
            println("Missing dependencies install automatically. For explicit setup, run setup.cmd or bash setup.sh from the repository root.")
            exit(0)
        elseif a == "--port" && i < length(ARGS)
            port = parse(Int, ARGS[i+1]); i += 2
            1<=port<=65535 || error("Port must be between 1 and 65535")
        elseif a == "--no-open"
            do_open = false; i += 1
        else
            error("Unknown or incomplete PANDEATOR option: $a (see --help)")
        end
    end
end

const URL = "http://127.0.0.1:$port/"

# Cross-platform "open a URL in the default browser". Returns true on success.
# IMPORTANT: open the URL exactly ONCE. On Windows, explorer.exe successfully
# hands the URL to the browser but then returns a NON-ZERO exit code, which makes
# Julia's run() throw even though a tab DID open. Previously the catch then ran
# `cmd /c start` too, opening a SECOND tab - and the caller invoked this twice -
# so up to four tabs appeared. We now treat "explorer launched" as success and
# never fall through to a second opener.
function open_in_browser(url::AbstractString)
    @static if Sys.iswindows()
        try
            # Don't wait on / inspect explorer's exit code (it lies); just launch.
            run(`explorer.exe $url`; wait=false)
            return true
        catch
            # explorer truly failed to start - fall back to start, once.
            try
                run(`cmd /c start "" $url`; wait=false)
                return true
            catch err
                @warn "Could not auto-open the browser; open this URL manually." url exception=err
                return false
            end
        end
    else
        try
            Sys.isapple() ? run(`open $url`) : run(`xdg-open $url`)
            return true
        catch err
            @warn "Could not auto-open the browser; open this URL manually." url exception=err
            return false
        end
    end
end

# Open the browser ONLY once the server is actually accepting connections. The
# server now warms up (compiles the HTTP handler + solver) BEFORE it binds the
# port, so a successful TCP connect means the server is genuinely ready and the
# page will load instantly - no more opening onto a stalled/compiling socket.
# We poll the port, and once it's up we try to open the browser a few times in
# case the first hand-off is swallowed by the OS.
using Sockets
function _port_is_listening(port::Integer; host="127.0.0.1")
    try
        s = connect(host, port)   # throws until something is listening
        close(s)
        return true
    catch
        return false
    end
end
if do_open
    @async begin
        up = false
        for _ in 1:1200                     # up to ~10 min (warm-up can take ~2 min)
            if _port_is_listening(port); up = true; break; end
            sleep(0.5)
        end
        if up
            @info "Server is up - opening $URL"
            # Open exactly once. (open_in_browser no longer double-fires on Windows.)
            open_in_browser(URL)
            @info "If no browser window appeared, open this URL manually:" URL
        else
            @warn "Server didn't come up in time; open $URL manually once it's listening." URL
        end
    end
end

# panel_server activates the project and installs missing dependencies first.
println(stderr, "Preparing PANDEATOR dependencies and loading the server; first use can take several minutes...")
include(joinpath(_APP_DIR, "panel_server.jl"))

# Hand off to the server (blocks until Ctrl+C). Wrap it so that, whatever makes
# the server stop, we print a clear reason BEFORE the .cmd window's "pause" - so
# the user never sees the window just close with no explanation.
try
    serve(; host="127.0.0.1", port=port)
    println(stderr, "\n[panel] Server stopped normally.")
catch err
    if err isa InterruptException
        println(stderr, "\n[panel] Server stopped (Ctrl+C / window closed).")
    else
        println(stderr, "\n[panel] Server STOPPED because of an error:")
        showerror(stderr, err, catch_backtrace())
        println(stderr, "\n[panel] If you were running a very large model, the most likely")
        println(stderr,   "        cause is the machine running out of memory (the process is")
        println(stderr,   "        killed by the OS and cannot report a Julia error). Try a")
        println(stderr,   "        coarser mesh / smaller model, or a machine with more RAM.")
        exit(1)
    end
end
