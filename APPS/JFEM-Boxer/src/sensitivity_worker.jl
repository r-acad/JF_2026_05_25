# Standalone entry point; Boxer itself uses the shared persistent FE worker.
length(ARGS)==2||error("Expected a sensitivity job directory and JFEM repository")
include(joinpath(@__DIR__,"sensitivity_worker_core.jl"))
JFEMSensitivityWorker.run_sensitivity_worker(abspath(ARGS[1]),abspath(ARGS[2]))||exit(1)
