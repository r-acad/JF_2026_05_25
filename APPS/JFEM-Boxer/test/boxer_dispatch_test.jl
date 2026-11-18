using Test, HTTP, JSON, SHA

module BoxerDispatchFixture
const APP=normpath(joinpath(@__DIR__,".."))
const SOURCE=read(joinpath(APP,"src","server.jl"),String)
const MATCH=match(r"(?s)const BOXER_MODEL_DISPATCH_LOCK.*?(?=\r?\n\"\"\"\r?\n    get_job)",SOURCE)
MATCH===nothing && error("Could not locate the production model-dispatch helper")
const FRAGMENT=MATCH.match
Base.include_string(@__MODULE__,FRAGMENT,"production_model_dispatch")
mutable struct State
    id::Int
end
end
const D=BoxerDispatchFixture
const evidence=Dict{String,Any}("default_threads"=>Threads.nthreads(:default),"interactive_threads"=>Threads.nthreads(:interactive),
    "source_sha256"=>bytes2hex(SHA.sha256(D.FRAGMENT)),"real_fe_solves"=>0)

function eventually(predicate;seconds=8.)
    deadline=time()+seconds
    while time()<deadline
        predicate() && return true
        sleep(.005)
    end
    predicate()
end

const results=@testset "Production model request dispatch" begin
    state=D.State(1)
    @test D.dispatch_model_request((st,req)->(st.id,req),state,:request)==(1,:request)
    calling_thread=Threads.threadid()
    worker_thread=D.dispatch_model_request((st,req)->Threads.threadid(),state,nothing)
    if Threads.nthreads(:default)>1
        @test worker_thread in Threads.threadpooltids(:default)
    else
        @test worker_thread==calling_thread
    end
    evidence["direct_worker_thread"]=worker_thread

    error=try D.dispatch_model_request((st,req)->throw(ArgumentError("deliberate model failure")),state,nothing);nothing catch error;error end
    @test error isa Exception
    @test occursin("deliberate model failure",sprint(showerror,error))
    @test D.dispatch_model_request((st,req)->42,state,nothing)==42
    @test D.BOXER_MODEL_DISPATCHES[state] isa ReentrantLock

    @testset "One model lock per live application" begin
        first=D.State(2);second=D.State(3);started=Channel{Int}(2);release=Channel{Nothing}(2)
        handler=(st,req)->begin put!(started,st.id);take!(release);st.id end
        one=@async D.dispatch_model_request(handler,first,nothing)
        two=@async D.dispatch_model_request(handler,second,nothing)
        @test eventually(()->Base.n_avail(started)==2)
        @test Set([take!(started),take!(started)])==Set([2,3])
        put!(release,nothing);put!(release,nothing)
        @test fetch(one)==2 && fetch(two)==3
        @test D.BOXER_MODEL_DISPATCHES[first]!==D.BOXER_MODEL_DISPATCHES[second]
    end

    @testset "Concurrent requests for one application serialize" begin
        active=Ref(0);maximum=Ref(0);started=Channel{Int}(2);release=Channel{Nothing}(2)
        handler=(st,req)->begin
            active[]+=1;maximum[]=max(maximum[],active[]);put!(started,req)
            try take!(release);req finally active[]-=1 end
        end
        first=@async D.dispatch_model_request(handler,state,1)
        @test eventually(()->isready(started))
        @test take!(started)==1
        second=@async D.dispatch_model_request(handler,state,2)
        yield();sleep(.03)
        @test !isready(started)
        @test active[]==1
        put!(release,nothing)
        @test eventually(()->isready(started))
        @test take!(started)==2
        put!(release,nothing)
        @test fetch(first)==1 && fetch(second)==2
        @test maximum[]==1 && active[]==0
        evidence["maximum_concurrent_same_app"]=maximum[]
    end

    if Threads.nthreads(:default)>1
        @testset "CPU model work keeps native HTTP status responsive" begin
            active=Threads.Atomic{Int}(0);maximum=Threads.Atomic{Int}(0);release=Threads.Atomic{Bool}(false)
            starts=Threads.Atomic{Int}(0);worker=Threads.Atomic{Int}(0);finished=Threads.Atomic{Int}(0)
            handler=(st,req)->begin
                if occursin("warm",req.target)
                    return HTTP.Response(200,JSON.json(Dict("ok"=>true,"warm"=>true)))
                end
                current=Threads.atomic_add!(active,1)+1
                starts[]+=1;maximum[]=max(maximum[],current);worker[]=Threads.threadid()
                checksum=UInt64(1);deadline=time_ns()+UInt64(8_000_000_000)
                try
                    # Intentionally no sleep, yield or I/O in the numerical loop.
                    # The status response must arrive before this gate opens.
                    while !release[] && time_ns()<deadline
                        checksum=xor(checksum<<1,checksum>>3)+UInt64(17)
                    end
                    HTTP.Response(200,JSON.json(Dict("ok"=>true,"checksum"=>string(checksum),"worker"=>worker[])))
                finally
                    Threads.atomic_sub!(active,1);Threads.atomic_add!(finished,1)
                end
            end
            router=HTTP.Router()
            HTTP.register!(router,"POST","/model",req->D.dispatch_model_request(handler,state,req))
            HTTP.register!(router,"GET","/status",req->HTTP.Response(200,JSON.json(Dict("running"=>active[]>0,"starts"=>starts[],"finished"=>finished[]))))
            server=HTTP.serve!(router,"127.0.0.1",0;verbose=false)
            url="http://127.0.0.1:"*string(HTTP.port(server))
            pending=nothing
            try
                @test HTTP.post(url*"/model?warm=1";request_timeout=15).status==200
                @test HTTP.get(url*"/status";request_timeout=15).status==200
                pending=@async HTTP.post(url*"/model";request_timeout=15)
                @test eventually(()->active[]>0)
                status=HTTP.get(url*"/status";request_timeout=4)
                value=JSON.parse(String(status.body))
                @test status.status==200
                @test value["running"]===true
                @test value["starts"]==1 && value["finished"]==0
                release[]=true
                @test fetch(pending).status==200
                @test active[]==0 && finished[]==1
                evidence["status_responded_during_cpu_work"]=value["running"]
                evidence["http_worker_thread"]=worker[]
                evidence["http_status_before_model_completion"]=value
            finally
                release[]=true
                pending===nothing || try fetch(pending) catch end
                close(server)
            end
        end
    else
        evidence["single_thread_fallback_verified"]=true
    end
end

counts=Test.get_test_counts(results)
evidence["assertions"]=counts.passes+counts.cumulative_passes
evidence["passed"]=counts.fails+counts.errors+counts.cumulative_fails+counts.cumulative_errors==0
if !isempty(ARGS)
    mkpath(dirname(abspath(ARGS[1])))
    open(io->JSON.print(io,evidence,2),ARGS[1],"w")
end
println(JSON.json(evidence))
