# Standalone entry point; Boxer itself uses the shared persistent FE worker.
length(ARGS)==2||error("Expected a sensitivity job directory and JFEM repository")
include(joinpath(@__DIR__,"..","..","..","utils","julia_tools","compilation_defaults.jl"))
using WingFEGen
worker=Base.invokelatest(getfield,WingFEGen,:JFEMSensitivityWorker)
execute=Base.invokelatest(getfield,worker,:run_sensitivity_worker)
Base.invokelatest(execute,abspath(ARGS[1]),abspath(ARGS[2]))||exit(1)
