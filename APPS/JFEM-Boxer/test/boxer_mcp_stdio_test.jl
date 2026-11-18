using Test, HTTP, JSON

module BoxerStdioFixture
using HTTP, JSON, SHA
const APP=normpath(joinpath(@__DIR__,".."))
const REPO=normpath(joinpath(APP,"..",".."))
json_response(value;status=200)=HTTP.Response(status,["Content-Type"=>"application/json"],JSON.json(value))
error_response(message;status=400)=json_response(Dict("ok"=>false,"error"=>message);status)
guard=match(r"(?s)function study_save_request\(req\).*?(?=\nfunction register_study_destination!)",read(joinpath(APP,"src","study_save_server.jl"),String))
Base.include_string(@__MODULE__,guard.match,"production_study_origin_guard")
include(joinpath(APP,"src","boxer_control.jl"))
include(joinpath(APP,"src","boxer_mcp.jl"))
include(joinpath(APP,"BoxerMCP.jl"))
mutable struct State
    deck_store_dir::String
end
message(id,method,params=Dict())=Dict("jsonrpc"=>"2.0","id"=>id,"method"=>method,"params"=>params)
function receive(channel;timeout=15.)
    timedwait(()->isready(channel),timeout;pollint=.01)==:ok || error("The native stdio proxy did not reply in time.")
    value=take!(channel)
    value isa Exception && throw(value)
    value
end
send(io,value)=(println(io,JSON.json(value));flush(io))
end

const S=BoxerStdioFixture

@testset "Boxer MCP stdio proxy and private connection configuration" begin
    mktempdir(;prefix="boxer MCP paths with spaces ! ") do folder
        st=S.State(folder);seen=Any[];fail_response=Ref(true);mutation_requests=Ref(0)
        router=HTTP.Router()
        HTTP.register!(router,"POST","/api/mcp") do req
            raw=JSON.parse(String(req.body))
            push!(seen,Dict("method"=>get(raw,"method",""),"protocol"=>HTTP.header(req,"MCP-Protocol-Version",""),
                "session"=>HTTP.header(req,"Mcp-Session-Id","")))
            losing=get(raw,"method","")=="tools/call" && get(get(raw,"params",Dict()),"name","")=="invoke_action" &&
                get(get(get(raw,"params",Dict()),"arguments",Dict()),"request_id","")=="network-failure"
            losing && (mutation_requests[]+=1)
            result=S.handle_boxer_mcp(st,req)
            delay=get(get(raw,"params",Dict()),"test_delay_seconds",0.)
            delay>0 && sleep(delay)
            if losing && fail_response[]
                fail_response[]=false
                return HTTP.Response(503,"The response was lost after accepting the command.")
            end
            result
        end
        server=HTTP.serve!(router,"127.0.0.1",0;verbose=false)
        url="http://127.0.0.1:"*string(HTTP.port(server))
        S.configure_boxer_mcp!(st,url)
        browser=S.boxer_control_connect!(st,Dict("page_id"=>"stdio-browser","state"=>Dict("title"=>"Stdio wing","revision"=>1),
            "catalog"=>Dict("actions"=>[Dict("id"=>"fit","label"=>"Fit model","enabled"=>true)],"inputs"=>Any[])))
        auth=Dict("client_id"=>browser["client_id"],"token"=>browser["token"])
        discovery=S.boxer_control_broker(st).discovery_file
        token=S.boxer_control_broker(st).token
        logpath=joinpath(folder,"proxy stderr.txt")
        process=nothing;log=nothing;reader=nothing
        try
            config=S.boxer_control_configuration(st)
            @test occursin(" ",discovery)
            @test !occursin(token,JSON.json(config["mcp_client_config"]))
            @test S.BoxerMCP.settings(["--token-env","CUSTOM_BOXER_TOKEN"])["token_env"]=="CUSTOM_BOXER_TOKEN"
            withenv("BOXER_MCP_TIMEOUT_SECONDS"=>nothing) do
                @test S.BoxerMCP.settings(String[])["timeout"]==300.
            end
            withenv("BOXER_MCP_TIMEOUT_SECONDS"=>"1.25") do
                @test S.BoxerMCP.settings(String[])["timeout"]==1.25
                @test S.BoxerMCP.settings(["--timeout","6.5"])["timeout"]==6.5
            end
            for invalid in ("0","-1","NaN","Inf","invalid")
                @test_throws ErrorException S.BoxerMCP.settings(["--timeout",invalid])
            end
            withenv("CUSTOM_BOXER_TOKEN"=>token) do
                options=S.BoxerMCP.settings(["--url",url*"/api/mcp","--token-env","CUSTOM_BOXER_TOKEN"])
                @test S.BoxerMCP.connection(options)==(url*"/api/mcp",token)
            end
            withenv("BOXER_MCP_DISCOVERY"=>discovery) do
                @test S.BoxerMCP.connection(S.BoxerMCP.settings(String[]))==(url*"/api/mcp",token)
            end
            command=`$(Base.julia_cmd()) --startup-file=no --project=$(S.REPO) $(joinpath(S.APP,"BoxerMCP.jl")) --discovery $discovery --timeout 15`
            log=open(logpath,"w")
            process=open(pipeline(command;stderr=log),"r+")
            replies=Channel{Any}(32)
            reader=@async try
                for line in eachline(process)
                    value=JSON.parse(line)
                    value isa AbstractDict && get(value,"jsonrpc",nothing)=="2.0" || error("The stdio proxy wrote non-protocol output.")
                    put!(replies,value)
                end
            catch error
                put!(replies,error)
            end

            S.send(process,S.message(1,"initialize",Dict("protocolVersion"=>"2025-06-18")))
            initialized=S.receive(replies)
            @test initialized["result"]["protocolVersion"]=="2025-06-18"
            S.send(process,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized"))
            S.send(process,S.message(2,"tools/list"))
            @test length(S.receive(replies)["result"]["tools"])==11
            @test !isempty(seen[2]["session"])
            @test all(request["protocol"]=="2025-06-18" for request in seen[2:end])
            @test all(request["session"]==seen[2]["session"] for request in seen[2:end])

            S.send(process,S.message(3,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"fit","request_id"=>"first-fit"))))
            queued=S.receive(replies)["result"]["structuredContent"]
            @test queued["state"]=="queued"
            delivery=S.boxer_control_poll!(st,auth)
            @test only(delivery["commands"])["id"]==queued["id"]
            S.boxer_control_result!(st,merge(auth,Dict("id"=>queued["id"],"result"=>Dict("ok"=>true,"status"=>"dispatched"))))
            S.send(process,S.message(4,"tools/call",Dict("name"=>"get_operation","arguments"=>Dict("operation_id"=>queued["id"])) ))
            @test S.receive(replies)["result"]["structuredContent"]["result"]["status"]=="dispatched"

            println(process,"{");flush(process)
            malformed=S.receive(replies)
            @test malformed["error"]["code"]==-32700
            @test malformed["error"]["message"]=="Invalid JSON-RPC JSON."
            @test !occursin(token,JSON.json(malformed))

            S.send(process,S.message(5,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"fit","request_id"=>"network-failure"))))
            uncertain=S.receive(replies)
            @test uncertain["error"]["code"]==-32000
            @test occursin("not retried",uncertain["error"]["message"])
            @test mutation_requests[]==1
            pending=S.boxer_control_poll!(st,auth)
            @test length(pending["commands"])==1
            pending_id=only(pending["commands"])["id"]
            S.boxer_control_result!(st,merge(auth,Dict("id"=>pending_id,"result"=>Dict("ok"=>true,"status"=>"dispatched"))))
            S.send(process,S.message(6,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"fit","request_id"=>"network-failure"))))
            repeated=S.receive(replies)["result"]["structuredContent"]
            @test repeated["id"]==pending_id && repeated["state"]=="done"
            @test isempty(S.boxer_control_poll!(st,auth)["commands"])

            original=read(discovery,String)
            write(discovery,"{\"token\":\""*token*"\", broken discovery")
            S.send(process,S.message(7,"ping"))
            discovery_error=S.receive(replies)
            @test !occursin(token,JSON.json(discovery_error))
            @test occursin("connection file could not be read",discovery_error["error"]["message"])
            S.send(process,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized"))
            sleep(.2)
            @test !isready(replies)
            write(discovery,original)
            S.send(process,S.message(8,"ping"))
            @test haskey(S.receive(replies),"result")

            S.send(process,S.message(9,"ping",Dict("test_delay_seconds"=>5.2,
                "_meta"=>Dict("progressToken"=>"cold-boxer-wait"))))
            progress=Any[]
            while true
                waiting=S.receive(replies)
                if get(waiting,"method",nothing)=="notifications/progress"
                    push!(progress,waiting["params"])
                else
                    @test waiting["id"]==9 && haskey(waiting,"result")
                    break
                end
            end
            @test !isempty(progress)
            @test all(update["progressToken"]=="cold-boxer-wait" for update in progress)
            @test all(!haskey(update,"total") for update in progress)
            @test all(occursin("not been repeated",update["message"]) for update in progress)
            @test all(progress[index]["progress"]>progress[index-1]["progress"] for index in 2:length(progress))
            @test first(progress)["progress"]>=1.5

            requests_before=length(seen)
            timeout_headers=["Content-Type"=>"application/json","Authorization"=>"Bearer "*token,
                "MCP-Protocol-Version"=>"2025-06-18","Mcp-Session-Id"=>seen[2]["session"]]
            @test_throws ErrorException S.BoxerMCP.request_boxer(url*"/api/mcp",timeout_headers,
                S.message(10,"ping",Dict("test_delay_seconds"=>1.0)),.15,value->nothing)
            @test length(seen)==requests_before+1
            @test !isready(replies)
            closewrite(process)
            @test timedwait(()->!process_running(process),10.;pollint=.05)==:ok
            wait(process)
            @test success(process)
            wait(reader)
            @test !isready(replies)
            flush(log)
            @test !occursin(token,read(logpath,String))
        finally
            if process!==nothing
                try closewrite(process) catch end
                timedwait(()->!process_running(process),2.;pollint=.05)
                process_running(process) && kill(process)
                try close(process) catch end
                try wait(process) catch end
            end
            log===nothing || close(log)
            S.stop_boxer_control!(st)
            close(server)
        end
    end
end
