using Test,JSON
include(joinpath(@__DIR__,"..","src","sensitivity_io.jl"))
include(joinpath(@__DIR__,"..","src","sensitivity_worker_core.jl"))
length(ARGS)<=1||error("Usage: sensitivity_progress_lifecycle_test.jl [fixture.json]")
mutable struct JobFixture
    outdir::String
    proc::NamedTuple
    state::Symbol
    message::String
    finished::Union{Nothing,Float64}
    lk::ReentrantLock
end
source=read(joinpath(@__DIR__,"..","src","sensitivity.jl"),String)
start=first(findfirst("function finish_sensitivity_job!",source))
stop=first(findfirst("function start_sensitivity_job",source))-1
include_string(@__MODULE__,source[start:stop])
@testset "Sensitivity worker progress and terminal lifecycle" begin
    mktempdir() do dir
        worker=JFEMSensitivityWorker
        worker.reset_worker!(dir,dirname(dirname(dirname(@__DIR__))))
        publish_progress=Base.invokelatest(getfield,worker,:progress)
        Base.invokelatest(publish_progress,Dict("phase"=>"native_package_load","detail"=>"Loading the cached JFEM solver package; an installation or source change may require precompilation"))
        cached=JSON.parsefile(joinpath(dir,"progress.json"))
        @test cached["phase"]=="native_package_load"
        @test cached["stage_category"]=="preparation"
        @test cached["stage_state"]=="started"
        @test cached["worker_seconds"]>=0
        Base.invokelatest(publish_progress,Dict("phase"=>"operators","detail"=>"Building operators","completed"=>3,"total"=>8))
        operators=JSON.parsefile(joinpath(dir,"progress.json"))
        @test operators["stage_category"]=="numerical"
        @test operators["completed"]==3
        Base.invokelatest(publish_progress,merge(operators,Dict("phase"=>"failed","detail"=>"Actual solver failure")))
        failed=JSON.parsefile(joinpath(dir,"progress.json"))
        @test failed["completed"]==3
        @test failed["stage_state"]=="failed"
        job(code=0;state=:running)=JobFixture(dir,(exitcode=code,),state,"",nothing,ReentrantLock())
        write(joinpath(dir,"result.json"),"{\"status\":\"ok\"}")
        completed=finish_sensitivity_job!(job())
        @test completed.state===:done
        @test completed.finished!==nothing
        write(joinpath(dir,"result.json"),"{\"status\":\"partial\"}")
        @test finish_sensitivity_job!(job()).state===:partial
        write(joinpath(dir,"result.json"),"{broken")
        malformed=finish_sensitivity_job!(job())
        @test malformed.state===:failed
        @test malformed.finished!==nothing
        @test occursin("could not be read",malformed.message)
        write(joinpath(dir,"error.json"),"{\"message\":\"Singular tangent matrix\"}")
        failed_job=finish_sensitivity_job!(job(1))
        @test failed_job.state===:failed
        @test failed_job.message=="Singular tangent matrix"
        cancelled=job(;state=:cancelled);cancelled.message="Cancelled by user"
        @test finish_sensitivity_job!(cancelled).state===:cancelled
        @test cancelled.message=="Cancelled by user"
        monitor=finish_sensitivity_job!(job();monitor_error=ErrorException("monitor read failure"))
        @test monitor.state===:failed
        @test occursin("monitor read failure",monitor.message)
        if !isempty(ARGS)
            mkpath(dirname(abspath(ARGS[1])))
            write(ARGS[1],JSON.json(Dict("origin"=>"Actual sensitivity worker progress helper; no numerical solve.",
                "cached"=>Dict("state"=>"running","seconds"=>12.875,"progress"=>cached),
                "operators"=>Dict("state"=>"running","seconds"=>34.875,"progress"=>operators),
                "failed"=>Dict("state"=>"failed","seconds"=>35.875,"progress"=>failed)),2))
        end
    end
end
