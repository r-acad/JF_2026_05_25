#!/usr/bin/env julia
# ===========================================================================
#  run.jl - entry point of the wing torsion box FE generator
#
#  Usage:
#      julia --project=. run.jl                    start the web application
#      julia --project=. run.jl my_wing.toml       use another input file
#      julia --project=. run.jl --nastran          generate and write, no UI
#      julia --project=. run.jl --port 9000
#      julia --project=. run.jl --no-browser
# ===========================================================================

include(joinpath(@__DIR__,"src","runtime_bootstrap.jl"))
WingFEGenBootstrap.restart_if_needed(@__DIR__,@__FILE__)
const startup_started = time()
println("Starting WingFEGen with Julia ", VERSION, " (", Threads.nthreads(), " threads).")
println("  Project: ", @__DIR__)
println("  First use or a code update can compile packages; the stages below report actual work.")
flush(stdout)
const startup_pipe = Pipe()
const startup_closed = Ref(false)
startup_process = nothing
try
    global startup_process = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --startup-file=no --history-file=no $(joinpath(@__DIR__, "src", "startup_progress.jl"))`),
        stdin=startup_pipe, stdout=stdout, stderr=stderr); wait=false)
    close(startup_pipe.out)
catch
    println("  Startup clock unavailable; stage changes will still be reported.")
end
function wingfegen_startup_progress(message::AbstractString)
    startup_closed[] && return nothing
    if startup_process !== nothing && process_running(startup_process) && isopen(startup_pipe.in)
        try
            println(startup_pipe, message)
            flush(startup_pipe)
            return nothing
        catch
            # Losing the optional clock must never stop application startup.
        end
    end
    println("  [", round(time()-startup_started;digits=1), " s] ", message)
    flush(stdout)
    return nothing
end
function close_startup_reporter()
    startup_closed[] && return nothing
    startup_closed[] = true
    try
        isopen(startup_pipe.in) && close(startup_pipe.in)
        startup_process === nothing || wait(startup_process)
    catch error
        # Reporting is optional; its cleanup must not mask a startup exception.
        println(stderr, "  Could not finish the optional startup clock: ", sprint(showerror,error))
    end
    return nothing
end
function startup_ready()
    startup_closed[] && return nothing
    wingfegen_startup_progress("Ready for the selected operation; startup took $(round(time()-startup_started;digits=1)) s")
    close_startup_reporter()
end
code = 1
try
    wingfegen_startup_progress("Loading Julia package/environment manager Pkg")
    using Pkg
    wingfegen_startup_progress("Activating the WingFEGen dependency environment")
    Pkg.activate(@__DIR__;io=devnull)
    include(joinpath(@__DIR__, "src", "WingFEGen.jl"))
    wingfegen_startup_progress("Preparing startup entry point (first-use Julia compilation); no FEM or analysis is running")
    global code = WingFEGen.main(ARGS; on_ready=startup_ready)
finally
    if !startup_closed[]
        wingfegen_startup_progress(code==0 ? "Command completed" : "Startup stopped before readiness; the error follows")
        close_startup_reporter()
    end
end
exit(code)
