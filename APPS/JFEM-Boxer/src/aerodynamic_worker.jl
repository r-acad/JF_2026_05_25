# Dedicated, bounded-lifetime VLM process. No FE model or solver is launched.
using WingFEGen, JSON, LinearAlgebra
include(joinpath(@__DIR__,"sensitivity_io.jl"))
BLAS.set_num_threads(min(4,Sys.CPU_THREADS))
input=only(ARGS);folder=dirname(input)
function write_progress(stage,done,total)
    # Status polling can briefly hold this file open on Windows. Reuse the
    # bounded sharing retries and atomic publication used by sensitivity jobs.
    SensitivityFileIO.write_text(joinpath(folder,"progress.json"),
        JSON.json(Dict("stage"=>stage,"done"=>done,"total"=>total));progress=true)
end
try
    request=JSON.parsefile(input)
    result=WingFEGen.run_aerodynamic_study(request["parameters"],request["settings"];mesh_only=request["mesh_only"],progress=write_progress)
    result["signature"]=request["signature"]
    SensitivityFileIO.write_text(joinpath(folder,"result.json"),JSON.json(result))
catch error
    SensitivityFileIO.write_text(joinpath(folder,"error.json"),JSON.json(Dict("error"=>sprint(showerror,error))))
    showerror(stderr,error,catch_backtrace());println(stderr);exit(1)
end
