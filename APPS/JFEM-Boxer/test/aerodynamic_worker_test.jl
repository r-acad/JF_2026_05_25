using Test, WingFEGen, JSON
const W=WingFEGen

mutable struct AerodynamicWorkerTestState
    root::String
    deck_store_dir::String
end

@testset "Owned aerodynamic worker reuse and request isolation" begin
    mktempdir() do folder
        root=dirname(@__DIR__);st=AerodynamicWorkerTestState(root,folder)
        fake=joinpath(folder,"protocol_worker.jl")
        write(fake,raw"""
using JSON
emit(x)=(println("[AERO_WORKER] ",JSON.json(x));flush(stdout))
emit(Dict("status"=>"ready","pid"=>getpid()))
for line in eachline(stdin)
    message=JSON.parse(line);input=message["input"];request=JSON.parsefile(input)
    output=dirname(input)
    if get(request,"pause",false)
        write(joinpath(output,"entered"),"ready")
        while true;sleep(.1);end
    end
    if get(request,"fail",false)
        emit(Dict("status"=>"failed","id"=>message["id"],"message"=>"Requested protocol failure"))
        continue
    end
    write(joinpath(output,"result.json"),JSON.json(Dict("signature"=>request["signature"],
        "pid"=>getpid(),"reused"=>message["reused"],"value"=>request["value"])))
    emit(Dict("status"=>"done","id"=>message["id"]))
end
""")
        factory=(state,job,signature)->W.create_aerodynamic_worker(state,job,signature;script=fake)
        function job(id;extra=Dict())
            output=joinpath(folder,id);mkpath(output)
            input=joinpath(output,"request.json")
            write(input,JSON.json(merge(Dict("signature"=>id,"value"=>id),extra)))
            item=W.AerodynamicJob(id,"running",nothing,output,time(),"Preparing",id)
            lock(W.AERODYNAMIC_JOB_LOCK) do
                get!(()->Dict{String,W.AerodynamicJob}(),W.AERODYNAMIC_JOBS,st)[id]=item
            end
            item,input
        end
        try
            a,input=job("first");W.run_aerodynamic_job!(st,a,input;worker_factory=factory)
            @test a.state=="done"
            first=JSON.parsefile(joinpath(a.folder,"result.json"))
            @test first["signature"]=="first"&&!first["reused"]
            @test process_running(a.process)
            b,input=job("second");W.run_aerodynamic_job!(st,b,input;worker_factory=factory)
            second=JSON.parsefile(joinpath(b.folder,"result.json"))
            @test b.state=="done"&&second["signature"]=="second"
            @test first["pid"]==second["pid"]&&second["reused"]
            @test first["value"]=="first"&&second["value"]=="second"
            @test JSON.parsefile(joinpath(a.folder,"result.json"))==first

            # A runtime/source signature change must retire the old process.
            withenv("JFEM_NO_SYSIMAGE"=>get(ENV,"JFEM_NO_SYSIMAGE","")=="1" ? "0" : "1") do
                c,input=job("changed-runtime");W.run_aerodynamic_job!(st,c,input;worker_factory=factory)
                third=JSON.parsefile(joinpath(c.folder,"result.json"))
                @test c.state=="done"&&third["pid"]!=first["pid"]&&!third["reused"]
                @test process_exited(a.process)
            end

            paused,input=job("cancelled";extra=Dict("pause"=>true))
            task=Threads.@spawn W.run_aerodynamic_job!(st,paused,input;worker_factory=factory)
            @test timedwait(()->isfile(joinpath(paused.folder,"entered")),120;pollint=.02)==:ok
            lock(W.AERODYNAMIC_JOB_LOCK) do;paused.state="cancelled";end
            W.stop_aerodynamic_worker!(st;job=paused)
            @test timedwait(()->istaskdone(task),15;pollint=.02)==:ok
            @test paused.state=="cancelled"&&process_exited(paused.process)
            @test !haskey(W.AERODYNAMIC_WORKERS,st)

            after,input=job("after-cancel");W.run_aerodynamic_job!(st,after,input;worker_factory=factory)
            @test after.state=="done"&&process_running(after.process)
            @test JSON.parsefile(joinpath(after.folder,"result.json"))["signature"]=="after-cancel"

            failure,input=job("failure";extra=Dict("fail"=>true))
            W.run_aerodynamic_job!(st,failure,input;worker_factory=factory)
            @test failure.state=="failed"&&occursin("Requested protocol failure",failure.message)
            @test process_exited(failure.process)&&!haskey(W.AERODYNAMIC_WORKERS,st)

            recovered,input=job("recovered");W.run_aerodynamic_job!(st,recovered,input;worker_factory=factory)
            @test recovered.state=="done"
            W.stop_aerodynamic_jobs!(st)
            @test process_exited(recovered.process)&&!haskey(W.AERODYNAMIC_WORKERS,st)
            @test recovered.state=="done"
        finally
            W.stop_aerodynamic_jobs!(st)
        end
    end
end
