# Dedicated VLM process. Service mode retains compiled Julia methods between
# requests; the original one-file command remains available for batch use.
const AERODYNAMIC_PACKAGE_LOAD_STARTED=time()
using WingFEGen, JSON, LinearAlgebra
include(joinpath(@__DIR__,"sensitivity_io.jl"))
BLAS.set_num_threads(min(4,Sys.CPU_THREADS))
const AERODYNAMIC_PACKAGE_LOAD_SECONDS=time()-AERODYNAMIC_PACKAGE_LOAD_STARTED

function run_aerodynamic_request(input;runtime=Dict(),reused=false,persistent=false)
    folder=dirname(input);last_progress=Ref(0.0)
    function write_progress(stage,done,total;force=false)
        now=time()
        !force&&now-last_progress[]<.1&&stage!="Complete"&&return
        last_progress[]=now
        # Avoid sub-poll-interval file churn while preserving atomic Windows
        # sharing retries and the final completion event.
        SensitivityFileIO.write_text(joinpath(folder,"progress.json"),
            JSON.json(Dict("stage"=>stage,"done"=>done,"total"=>total));progress=true)
    end
    started=time()
    try
        request=JSON.parsefile(input)
        result=WingFEGen.run_aerodynamic_study(request["parameters"],request["settings"];mesh_only=request["mesh_only"],progress=write_progress)
        result["signature"]=request["signature"]
        result["runtime"]=merge(Dict{String,Any}(runtime),Dict("julia_threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),
            "worker_pid"=>getpid(),"persistent_worker"=>persistent,"worker_reused"=>reused,
            "package_load_seconds"=>reused ? 0.0 : AERODYNAMIC_PACKAGE_LOAD_SECONDS,"calculation_wall_seconds"=>time()-started))
        write_progress("Writing aerodynamic results",0,1;force=true)
        SensitivityFileIO.write_text(joinpath(folder,"result.json"),JSON.json(result))
        write_progress("Complete",1,1;force=true)
        return nothing
    catch error
        SensitivityFileIO.write_text(joinpath(folder,"error.json"),JSON.json(Dict("error"=>sprint(showerror,error))))
        showerror(stderr,error,catch_backtrace());println(stderr);rethrow()
    end
end

if ARGS==["--service"]
    emit(value)=(println("[AERO_WORKER] ",JSON.json(value));flush(stdout))
    emit(Dict("status"=>"ready","pid"=>getpid()))
    for line in eachline(stdin)
        request=JSON.parse(line)
        get(request,"command","")=="shutdown"&&break
        id=request["id"];input=String(request["input"])
        try
            open(joinpath(dirname(input),"worker.log"),"a") do log
                redirect_stderr(log) do
                    run_aerodynamic_request(input;runtime=get(request,"runtime",Dict()),reused=get(request,"reused",false),persistent=true)
                end
            end
            emit(Dict("status"=>"done","id"=>id))
        catch error
            emit(Dict("status"=>"failed","id"=>id,"message"=>sprint(showerror,error)))
        end
        GC.gc(false)
    end
else
    try
        run_aerodynamic_request(only(ARGS))
    catch
        exit(1)
    end
end
