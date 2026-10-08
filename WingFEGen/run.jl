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
using Pkg
Pkg.activate(@__DIR__;io=devnull)

const startup_started = time()
println("Starting WingFEGen — loading Julia code. First use can take longer while packages compile.")
flush(stdout)
const startup_pipe = Pipe()
startup_process = nothing
try
    global startup_process = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --startup-file=no --history-file=no $(joinpath(@__DIR__, "src", "startup_progress.jl"))`),
        stdin=startup_pipe, stdout=stdout, stderr=stderr); wait=false)
    close(startup_pipe.out)
catch
    println("  Loading packages…")
end
function startup_ready()
    if isopen(startup_pipe.in)
        close(startup_pipe.in)
        startup_process === nothing || wait(startup_process)
        println("  Startup finished in ", round(time() - startup_started; digits=1), " s. The viewer shows progress while preparing the first FEM.")
        flush(stdout)
    end
end
code = 1
try
    include(joinpath(@__DIR__, "src", "WingFEGen.jl"))
    if isopen(startup_pipe.in)
        println(startup_pipe, "Packages loaded; preparing the local web server")
        flush(startup_pipe)
    end
    global code = WingFEGen.main(ARGS; on_ready=startup_ready)
finally
    startup_ready()
end
exit(code)
