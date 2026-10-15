#!/usr/bin/env julia
# ===========================================================================
#  JFEM-Boxer.jl - entry point of the wing torsion box FE generator
#
#  Usage:
#      julia --project=../.. JFEM-Boxer.jl                    start the web application
#      julia --project=../.. JFEM-Boxer.jl my_wing.toml       use another input file
#      julia --project=../.. JFEM-Boxer.jl --reference          generate and write, no UI
#      julia --project=../.. JFEM-Boxer.jl --port 9000
#      julia --project=../.. JFEM-Boxer.jl --no-browser
# ===========================================================================

include(joinpath(@__DIR__,"src","runtime_bootstrap.jl"))
WingFEGenBootstrap.restart_if_needed(@__DIR__,@__FILE__)
const startup_started = time()
println("Starting JFEM-Boxer with Julia ", VERSION, " (", Threads.nthreads(), " threads).")
println("  Project: ", WingFEGenBootstrap.locate_solver(@__DIR__))
println("  First use or a code update can compile packages; the stages below report actual work.")
flush(stdout)
const startup_pipe = Pipe()
const startup_closed = Ref(false)
startup_process = nothing
try
    reporter_julia=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    global startup_process = run(pipeline(ignorestatus(`$reporter_julia --startup-file=no --history-file=no $(joinpath(@__DIR__, "src", "startup_progress.jl"))`),
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
    solver_root=WingFEGenBootstrap.locate_solver(@__DIR__)
    solver_root===nothing&&error("Keep APPS/JFEM-Boxer inside the complete JFEM repository.")
    wingfegen_startup_progress("Activating the shared JFEM and applications environment")
    Pkg.activate(solver_root;io=devnull)
    wingfegen_startup_progress("Checking recorded shared dependencies; missing packages install automatically")
    include(joinpath(solver_root,"utils","julia_tools","environment_setup.jl"))
    JFEMEnvironmentSetup.ensure_environment(solver_root)
    using WingFEGen
    wingfegen_startup_progress("Preparing startup entry point (first-use Julia compilation); no FEM or analysis is running")
    global code = WingFEGen.main(ARGS; on_ready=startup_ready)
finally
    if !startup_closed[]
        wingfegen_startup_progress(code==0 ? "Command completed" : "Startup stopped before readiness; the error follows")
        close_startup_reporter()
    end
end
exit(code)
