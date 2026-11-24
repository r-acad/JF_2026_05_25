using Test, HTTP, JSON

module BoxerControlFixture
using HTTP, JSON, SHA
const APP=normpath(joinpath(@__DIR__,".."))
json_response(value;status=200)=HTTP.Response(status,["Content-Type"=>"application/json"],JSON.json(value))
error_response(message;status=400)=json_response(Dict("ok"=>false,"error"=>message);status)
guard=match(r"(?s)function study_save_request\(req\).*?(?=\nfunction register_study_destination!)",read(joinpath(APP,"src","study_save_server.jl"),String))
Base.include_string(@__MODULE__,guard.match,"production_study_origin_guard")
include(joinpath(APP,"src","boxer_control.jl"))
include(joinpath(APP,"src","boxer_mcp.jl"))
mutable struct State
    deck_store_dir::String
end

function connect(st;page="page-a",token="",title="Wing A")
    boxer_control_connect!(st,Dict("page_id"=>page,"token"=>token,"label"=>title,
        "state"=>Dict("title"=>title,"revision"=>1,"parameters"=>Dict("properties.upper_skin_thickness"=>.0015)),
        "catalog"=>Dict("revision"=>1,"actions"=>[
            Dict("id"=>"create-fem","label"=>"Create FEM","context"=>"Mesh","enabled"=>true),
            Dict("id"=>"run","label"=>"Run in JFEM","enabled"=>false)],
            "inputs"=>[Dict("id"=>"skin-mm","label"=>"Minimum upper skin thickness","unit"=>"mm","enabled"=>true)])))
end
function browser_request(st,action,raw;origin="http://127.0.0.1:8080",host="127.0.0.1:8080",content_type="application/json")
    req=HTTP.Request("POST","/api/control/"*action,["Host"=>host,"Origin"=>origin,"Content-Type"=>content_type],JSON.json(raw))
    handle_boxer_control(st,req;action)
end
function rpc(st,value;session="",token=boxer_control_broker(st).token,origin="",host="127.0.0.1:8080",method="POST",version="2025-11-25")
    headers=["Host"=>host,"Authorization"=>"Bearer "*token,"Content-Type"=>"application/json","Accept"=>"application/json, text/event-stream"]
    isempty(origin) || push!(headers,"Origin"=>origin)
    isempty(session) || push!(headers,"Mcp-Session-Id"=>session)
    isempty(version) || push!(headers,"MCP-Protocol-Version"=>version)
    handle_boxer_mcp(st,HTTP.Request(method,"/api/mcp",headers,JSON.json(value)))
end
message(id,method,params=Dict())=Dict("jsonrpc"=>"2.0","id"=>id,"method"=>method,"params"=>params)
end

const F=BoxerControlFixture

@testset "Boxer authenticated command broker" begin
    mktempdir() do folder
        st=F.State(folder)
        path=F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        @test isfile(path)
        @test JSON.parsefile(path)["url"]=="http://127.0.0.1:8080/api/mcp"
        @test JSON.parsefile(path)["token"]==F.boxer_control_broker(st).token
        configuration=F.boxer_control_configuration(st)
        launch=configuration["mcp_client_config"]["mcpServers"]["JFEM-Boxer"]
        # The copied configuration names the connection file with the fixed name, which every start rewrites.
        @test last(launch["args"])==joinpath(st.deck_store_dir,"boxer_mcp.json")
        @test JSON.parsefile(last(launch["args"]))==JSON.parsefile(path)
        @test endswith(launch["args"][3],"BoxerMCP.jl")
        # A project folder ending in a separator would break the quoted command line that the Options view offers.
        @test startswith(launch["args"][2],"--project=") && !endswith(launch["args"][2],"/") && !endswith(launch["args"][2],"\\")
        @test !occursin(configuration["token"],JSON.json(configuration["mcp_client_config"]))
        @test_throws ArgumentError F.configure_boxer_mcp!(st,"http://remote.example:8080/")
        @test_throws ArgumentError F.boxer_control_snapshot(st)
        @test F.browser_request(st,"connect",Dict();origin="http://evil.example").status==403
        @test F.browser_request(st,"connect",Dict();origin="https://127.0.0.1:8080").status==403
        @test F.browser_request(st,"connect",Dict();host="evil.example",origin="http://evil.example").status==403
        @test F.browser_request(st,"connect",Dict();host="127.0.0.1:9999",origin="http://127.0.0.1:9999").status==403
        @test F.browser_request(st,"connect",Dict();content_type="text/plain").status==400

        client=F.connect(st)
        id=client["client_id"]
        auth=Dict("client_id"=>id,"token"=>client["token"])
        @test length(F.boxer_control_clients(st))==1
        @test F.boxer_control_snapshot(st)["state"]["title"]=="Wing A"
        @test !haskey(only(F.boxer_control_clients(st)),"token")
        @test_throws F.BoxerControlAuthError F.connect(st)
        @test F.connect(st;token=client["token"])["client_id"]==id

        op=F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>3.);request_id="resize",expected_revision=1)
        @test op["state"]=="queued"
        repeat=F.boxer_control_enqueue!(st,"set_input",Dict("value"=>3.,"input_id"=>"skin-mm");request_id="resize",expected_revision=1)
        @test repeat["id"]==op["id"]
        @test_throws ArgumentError F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>4.);request_id="resize",expected_revision=1)
        @test_throws ArgumentError F.boxer_control_enqueue!(st,"invoke_action",Dict("action_id"=>"run"))
        @test_throws ArgumentError F.boxer_control_enqueue!(st,"invoke_action",Dict("action_id"=>"invented"))
        @test_throws ArgumentError F.boxer_control_enqueue!(st,"javascript",Dict("code"=>"alert(1)"))
        @test_throws F.BoxerControlAuthError F.boxer_control_poll!(st,merge(auth,Dict("token"=>"wrong")))
        polled=F.boxer_control_poll!(st,auth)
        @test length(polled["commands"])==1
        @test only(polled["commands"])["expected_revision"]==1
        @test only(polled["commands"])["arguments"]["value"]==3.
        @test isempty(F.boxer_control_poll!(st,auth)["commands"])
        @test F.boxer_control_operation(st,op["id"])["state"]=="running"
        applied=F.boxer_control_result!(st,merge(auth,Dict("id"=>op["id"],"result"=>Dict("ok"=>true,"status"=>"updated"))))
        @test applied["operation"]["state"]=="done"
        @test F.boxer_control_result!(st,merge(auth,Dict("id"=>op["id"],"result"=>Dict())))["duplicate"]

        queued=F.boxer_control_enqueue!(st,"invoke_action",Dict("action_id"=>"create-fem"))
        @test F.boxer_control_cancel!(st,queued["id"])["cancelled"]
        @test isempty(F.boxer_control_poll!(st,auth)["commands"])
        failed=F.boxer_control_enqueue!(st,"invoke_action",Dict("action_id"=>"create-fem"))
        F.boxer_control_poll!(st,auth)
        @test !F.boxer_control_cancel!(st,failed["id"])["cancelled"]
        F.boxer_control_result!(st,merge(auth,Dict("id"=>failed["id"],"error"=>"The current mesh changed.")))
        @test F.boxer_control_operation(st,failed["id"])["state"]=="failed"

        second=F.connect(st;page="page-b",title="Wing B")
        @test_throws ArgumentError F.boxer_control_snapshot(st)
        @test F.boxer_control_snapshot(st;client_id=id)["state"]["title"]=="Wing A"
        @test_throws F.BoxerControlAuthError F.boxer_control_result!(st,merge(Dict("client_id"=>second["client_id"],"token"=>second["token"]),
            Dict("id"=>failed["id"],"result"=>Dict())))
        stale=F.boxer_control_enqueue!(st,"navigate",Dict("target"=>"Geometry");client_id=id)
        F.boxer_control_broker(st).operations[stale["id"]]["created_at"]-=130
        @test F.boxer_control_operation(st,stale["id"])["state"]=="expired"
        F.boxer_control_broker(st).clients[second["client_id"]]["last_seen"]-=130
        @test F.boxer_control_snapshot(st)["state"]["title"]=="Wing A"
        F.boxer_control_poll!(st,merge(auth,Dict("state"=>Dict("title"=>"Edited wing","revision"=>2))))
        @test F.boxer_control_snapshot(st)["state"]["revision"]==2
        @test !isempty(F.boxer_control_catalog(st)["catalog"]["actions"])
        F.stop_boxer_control!(st)
        @test !isfile(path)
        @test !isfile(joinpath(folder,"boxer_mcp.json"))
        @test_throws ArgumentError F.boxer_control_snapshot(st)
    end
end

@testset "MCP lifecycle, tools, resources and guarded HTTP" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        client=F.connect(st)
        @test F.rpc(st,F.message(1,"initialize");token="bad").status==403
        @test F.rpc(st,F.message(1,"initialize");origin="http://evil.example").status==403
        @test F.rpc(st,F.message(1,"initialize");host="evil.example",origin="http://evil.example").status==403
        @test F.rpc(st,F.message(1,"initialize");host="127.0.0.1:9999").status==403
        @test F.rpc(st,F.message(1,"tools/list")).status==400
        init=F.rpc(st,F.message(1,"initialize",Dict("protocolVersion"=>"2025-11-25")))
        @test init.status==200
        session=HTTP.header(init,"Mcp-Session-Id","")
        @test !isempty(session)
        @test JSON.parse(String(init.body))["result"]["protocolVersion"]=="2025-11-25"
        premature=F.rpc(st,F.message(2,"tools/list");session)
        @test JSON.parse(String(premature.body))["error"]["code"]==-32002
        initialized=F.rpc(st,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized");session)
        @test initialized.status==202 && isempty(initialized.body)
        @test F.rpc(st,F.message(2,"ping");session).status==200
        @test F.rpc(st,Dict();session,method="GET").status==405
        @test F.rpc(st,F.message(3,"tools/list");session,version="2099-01-01").status==400
        tools=JSON.parse(String(F.rpc(st,F.message(3,"tools/list");session).body))["result"]["tools"]
        @test length(tools)==17
        @test Set(tool["name"] for tool in tools)==Set(["list_clients","get_state","list_actions","list_inputs","invoke_action","set_input","update_parameters","inspect","navigate","get_operation","cancel_operation",
            "get_parameters","run_analysis","read_view","read_reserve_factors","find_airfoils","set_airfoil"])
        listed=JSON.parse(String(F.rpc(st,F.message(4,"tools/call",Dict("name"=>"list_actions","arguments"=>Dict("query"=>"mesh")));session).body))["result"]
        @test !listed["isError"] && listed["structuredContent"]["total"]==1
        @test only(listed["structuredContent"]["items"])["id"]=="create-fem"
        bad=JSON.parse(String(F.rpc(st,F.message(5,"tools/call",Dict("name"=>"set_input","arguments"=>Dict()));session).body))
        @test bad["error"]["code"]==-32602
        unknown=JSON.parse(String(F.rpc(st,F.message(6,"tools/call",Dict("name"=>"eval","arguments"=>Dict()));session).body))
        @test unknown["error"]["code"]==-32602
        disabled=JSON.parse(String(F.rpc(st,F.message(7,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"run")));session).body))["result"]
        @test disabled["isError"]
        @test occursin("disabled",disabled["structuredContent"]["error"])
        action=JSON.parse(String(F.rpc(st,F.message(8,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"create-fem")));session).body))["result"]
        @test action["structuredContent"]["state"]=="queued"
        opid=action["structuredContent"]["id"]
        @test F.rpc(st,Dict("jsonrpc"=>"2.0","method"=>"notifications/cancelled","params"=>Dict("requestId"=>8));session).status==202
        @test F.boxer_control_operation(st,opid)["state"]=="cancelled"
        resources=JSON.parse(String(F.rpc(st,F.message(9,"resources/list");session).body))["result"]["resources"]
        @test length(resources)==3
        uri="boxer://client/"*client["client_id"]*"/state"
        state=JSON.parse(String(F.rpc(st,F.message(10,"resources/read",Dict("uri"=>uri));session).body))["result"]["contents"]
        @test JSON.parse(only(state)["text"])["state"]["title"]=="Wing A"
        prompt=JSON.parse(String(F.rpc(st,F.message(11,"prompts/get",Dict("name"=>"boxer_workflow"));session).body))["result"]
        @test occursin("physical assumptions",only(prompt["messages"])["content"]["text"])
        @test F.rpc(st,Dict();session,method="DELETE").status==204
        @test F.rpc(st,F.message(12,"tools/list");session).status==404
        F.stop_boxer_control!(st)
    end
end

@testset "MCP real loopback HTTP transport" begin
    mktempdir() do folder
        st=F.State(folder)
        router=HTTP.Router()
        HTTP.register!(router,"POST","/api/mcp",req->F.handle_boxer_mcp(st,req))
        HTTP.register!(router,"GET","/api/mcp",req->F.handle_boxer_mcp(st,req))
        for action in ("connect","poll","result")
            HTTP.register!(router,"POST","/api/control/"*action,let action=action;req->F.handle_boxer_control(st,req;action);end)
        end
        server=HTTP.serve!(router,"127.0.0.1",0;verbose=false)
        url="http://127.0.0.1:"*string(HTTP.port(server))
        try
            F.configure_boxer_mcp!(st,url)
            browser_headers=["Content-Type"=>"application/json","Origin"=>url]
            connection=HTTP.post(url*"/api/control/connect",browser_headers,JSON.json(Dict("page_id"=>"real-browser",
                "state"=>Dict("title"=>"HTTP wing","revision"=>1),"catalog"=>Dict("actions"=>[Dict("id"=>"fit","label"=>"Fit model","enabled"=>true)],"inputs"=>Any[]))))
            client=JSON.parse(String(connection.body));@test connection.status==200
            headers=["Content-Type"=>"application/json","Accept"=>"application/json, text/event-stream",
                "Authorization"=>"Bearer "*F.boxer_control_broker(st).token]
            initialization=HTTP.post(url*"/api/mcp",headers,JSON.json(F.message(1,"initialize",Dict("protocolVersion"=>"2025-06-18"))))
            push!(headers,"Mcp-Session-Id"=>HTTP.header(initialization,"Mcp-Session-Id",""))
            push!(headers,"MCP-Protocol-Version"=>"2025-06-18")
            @test JSON.parse(String(initialization.body))["result"]["protocolVersion"]=="2025-06-18"
            initialized=HTTP.post(url*"/api/mcp",headers,JSON.json(Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized")))
            @test initialized.status==202 && isempty(initialized.body)
            called=HTTP.post(url*"/api/mcp",headers,JSON.json(F.message(2,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"fit","request_id"=>"real-fit")))))
            operation=JSON.parse(String(called.body))["result"]["structuredContent"]
            @test operation["state"]=="queued"
            auth=Dict("client_id"=>client["client_id"],"token"=>client["token"])
            delivery=HTTP.post(url*"/api/control/poll",browser_headers,JSON.json(auth))
            commands=JSON.parse(String(delivery.body))["commands"]
            @test length(commands)==1 && only(commands)["arguments"]["action_id"]=="fit"
            acknowledgement=HTTP.post(url*"/api/control/result",browser_headers,JSON.json(merge(auth,
                Dict("id"=>operation["id"],"result"=>Dict("ok"=>true,"status"=>"dispatched")))))
            @test acknowledgement.status==200
            completed=HTTP.post(url*"/api/mcp",headers,JSON.json(F.message(3,"tools/call",Dict("name"=>"get_operation","arguments"=>Dict("operation_id"=>operation["id"])))))
            outcome=JSON.parse(String(completed.body))["result"]["structuredContent"]
            @test outcome["state"]=="done"
            @test outcome["result"]["status"]=="dispatched"
            @test isempty(F.boxer_control_poll!(st,auth)["commands"])
        finally
            F.stop_boxer_control!(st)
            close(server)
        end
    end
end

@testset "MCP parameterized curated actions retain nested arguments" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        client=F.connect(st)
        auth=Dict("client_id"=>client["client_id"],"token"=>client["token"])
        actions=[("open_study",Dict("path"=>raw"C:\Study folder\wing.json")),
            ("read_nastran",Dict("path"=>raw"C:\FE models\fuselage.dat")),
            ("inspect_element",Dict("id"=>128)),
            ("read_reserve_factors",Dict("offset"=>50,"limit"=>25))]
        F.boxer_control_poll!(st,merge(auth,Dict("catalog"=>Dict("actions"=>[
            Dict("id"=>id,"label"=>id,"enabled"=>true) for (id,_) in actions],"inputs"=>Any[]))))
        tool=F.boxer_mcp_find_tool("invoke_action")
        @test tool["inputSchema"]["properties"]["arguments"]["type"]=="object"
        @test tool["inputSchema"]["additionalProperties"]===false
        init=F.rpc(st,F.message(1,"initialize",Dict("protocolVersion"=>"2025-11-25")))
        session=HTTP.header(init,"Mcp-Session-Id","")
        F.rpc(st,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized");session)
        for (index,(action_id,nested)) in enumerate(actions)
            arguments=Dict("action_id"=>action_id,"arguments"=>nested,"request_id"=>"parameterized_"*string(index))
            response=F.rpc(st,F.message(index+1,"tools/call",Dict("name"=>"invoke_action","arguments"=>arguments));session)
            result=JSON.parse(String(response.body))["result"]
            @test !result["isError"]
            operation=result["structuredContent"]
            @test operation["arguments"]["arguments"]==nested
            received=only(F.boxer_control_poll!(st,auth)["commands"])
            @test received["arguments"]["action_id"]==action_id
            @test received["arguments"]["arguments"]==nested
            F.boxer_control_result!(st,merge(auth,Dict("id"=>operation["id"],"result"=>Dict("ok"=>true,"status"=>"dispatched"))))
            @test F.boxer_mcp_call_tool(st,"invoke_action",arguments)["id"]==operation["id"]
            @test isempty(F.boxer_control_poll!(st,auth)["commands"])
        end
        for forbidden in (Dict("action_id"=>"open_study","path"=>"wing.json"),
                Dict("action_id"=>"open_study","arguments"=>"wing.json"),
                Dict("action_id"=>"open_study","arguments"=>Dict("path"=>"wing.json"),"javascript"=>"alert(1)"))
            rejected=F.rpc(st,F.message(99,"tools/call",Dict("name"=>"invoke_action","arguments"=>forbidden));session)
            @test JSON.parse(String(rejected.body))["error"]["code"]==-32602
            @test isempty(F.boxer_control_poll!(st,auth)["commands"])
        end
        F.stop_boxer_control!(st)
    end
end

@testset "Command acknowledgments publish fresh Study state atomically" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        client=F.connect(st)
        auth=Dict("client_id"=>client["client_id"],"token"=>client["token"])
        original=F.boxer_control_snapshot(st)["state"]
        op=F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>2.5);expected_revision=1)
        F.boxer_control_poll!(st,auth)
        fresh=Dict("title"=>"JFEM-Boxer generic document","revision"=>2,
            "study"=>Dict("title"=>"Sized Regional wing","name"=>"Regional.wingfem.json","path"=>raw"C:\Studies\Regional.wingfem.json"),
            "parameters"=>Dict("properties.upper_skin_thickness"=>.0025))
        response=F.browser_request(st,"result",merge(auth,Dict("id"=>op["id"],"state"=>fresh,
            "result"=>Dict("ok"=>true,"status"=>"updated"))))
        @test response.status==200
        @test F.boxer_control_operation(st,op["id"])["state"]=="done"
        immediate=F.boxer_control_snapshot(st)
        @test immediate["state"]["parameters"]["properties.upper_skin_thickness"]==.0025
        @test immediate["state"]["revision"]==2
        @test immediate["client"]["revision"]==2
        @test immediate["client"]["title"]=="Sized Regional wing"
        @test only(F.boxer_control_clients(st))["title"]=="Sized Regional wing"
        resources=F.boxer_mcp_resources(st)
        @test only(filter(resource->endswith(resource["uri"],"/state"),resources))["name"]=="Sized Regional wing current state"
        @test only(filter(resource->endswith(resource["uri"],"/interface"),resources))["name"]=="Sized Regional wing menu and input catalog"
        duplicate=F.boxer_control_result!(st,merge(auth,Dict("id"=>op["id"],"state"=>original,"result"=>Dict())))
        @test duplicate["duplicate"]
        @test F.boxer_control_snapshot(st)["state"]["revision"]==2
        @test length(F.boxer_control_catalog(st)["catalog"]["actions"])==2

        for (study,expected) in ((Dict("title"=>" ","name"=>"Named Study","path"=>"/studies/wing.json"),"Named Study"),
                (Dict("title"=>"","name"=>"","path"=>"/studies/wing.json"),"/studies/wing.json"),
                (Dict("title"=>nothing,"name"=>nothing,"path"=>nothing),"Legacy title"),
                (nothing,"Legacy title"))
            F.boxer_control_poll!(st,merge(auth,Dict("state"=>Dict("title"=>"Legacy title","study"=>study,"revision"=>3))))
            @test only(F.boxer_control_clients(st))["title"]==expected
        end

        op2=F.boxer_control_enqueue!(st,"navigate",Dict("target"=>"Geometry"))
        F.boxer_control_poll!(st,auth)
        next_state=Dict("revision"=>4,"study"=>Dict("name"=>"After failed command"))
        next_catalog=Dict("revision"=>4,"actions"=>[Dict("id"=>"fresh-action","enabled"=>true)],"inputs"=>Any[])
        F.boxer_control_result!(st,merge(auth,Dict("id"=>op2["id"],"state"=>next_state,"catalog"=>next_catalog,"error"=>"A dialog still needs attention.")))
        @test F.boxer_control_operation(st,op2["id"])["state"]=="failed"
        @test F.boxer_control_snapshot(st)["state"]["revision"]==4
        @test only(F.boxer_control_catalog(st)["catalog"]["actions"])["id"]=="fresh-action"

        op3=F.boxer_control_enqueue!(st,"navigate",Dict("target"=>"Geometry"))
        F.boxer_control_poll!(st,auth)
        @test_throws ArgumentError F.boxer_control_result!(st,merge(auth,Dict("id"=>op3["id"],"state"=>["invalid"],"result"=>Dict("ok"=>true))))
        @test F.boxer_control_operation(st,op3["id"])["state"]=="running"
        @test F.boxer_control_snapshot(st)["state"]["revision"]==4
        F.stop_boxer_control!(st)
    end
end

@testset "MCP interface search ranks exact controls before broad help" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        client=F.connect(st)
        auth=Dict("client_id"=>client["client_id"],"token"=>client["token"])
        actions=Any[Dict("id"=>"help_"*string(i),"label"=>"Help","context"=>"Geometry Loft",
            "description"=>"Read about loft geometry.","enabled"=>true) for i in 1:50]
        append!(actions,[Dict("id"=>"loft_options","label"=>"Loft options","enabled"=>true),
            Dict("id"=>"tab:geometry:loft","label"=>"Loft","enabled"=>true),
            Dict("id"=>"curated_loft","label"=>"Loft","enabled"=>true,"curated"=>true)])
        inputs=Any[Dict("id"=>"help_area_"*string(i),"label"=>"Help","context"=>"Planform wing area",
            "description"=>"The wing area controls aerodynamic reference values.","enabled"=>true) for i in 1:50]
        append!(inputs,[Dict("id"=>"area_adjustment","label"=>"Wing area adjustment","enabled"=>true),
            Dict("id"=>"planform-area","label"=>"Area","aliases"=>["Wing area","Reference area"],
                "parameter_key"=>"planform.area","enabled"=>true)])
        F.boxer_control_poll!(st,merge(auth,Dict("catalog"=>Dict("revision"=>4,"actions"=>actions,"inputs"=>inputs))))

        loft=F.boxer_mcp_call_tool(st,"list_actions",Dict("query"=>"Loft","limit"=>12))
        @test loft["total"]==53
        @test length(loft["items"])==12
        @test [entry["id"] for entry in loft["items"]][1:3]==["curated_loft","tab:geometry:loft","loft_options"]
        @test loft["next_offset"]==12
        next=F.boxer_mcp_call_tool(st,"list_actions",Dict("query"=>"Loft","offset"=>12,"limit"=>12))
        @test first(next["items"])["id"]=="help_10"

        area=F.boxer_mcp_call_tool(st,"list_inputs",Dict("query"=>"wing area","limit"=>12))
        @test area["total"]==52
        @test first(area["items"])["id"]=="planform-area"
        @test area["items"][2]["id"]=="area_adjustment"
        @test first(F.boxer_mcp_call_tool(st,"list_inputs",Dict("query"=>"Reference area"))["items"])["id"]=="planform-area"
        @test only(F.boxer_mcp_call_tool(st,"list_inputs",Dict("query"=>"planform.area"))["items"])["id"]=="planform-area"
        @test first(F.boxer_mcp_call_tool(st,"list_actions",Dict("query"=>"tab:geometry:loft"))["items"])["id"]=="tab:geometry:loft"
        @test first(F.boxer_mcp_call_tool(st,"list_actions",Dict("limit"=>12))["items"])["id"]=="help_1"
        F.stop_boxer_control!(st)
    end
end

@testset "Queued mutations stay bound to their original Study epoch" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        client=F.connect(st)
        auth=Dict("client_id"=>client["client_id"],"token"=>client["token"])
        state1=Dict("revision"=>1,"study"=>Dict("epoch"=>11,"title"=>"First Study"))
        F.boxer_control_poll!(st,merge(auth,Dict("state"=>state1)))
        first=F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>2.);request_id="first-epoch-edit")
        second=F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>2.5);request_id="second-epoch-edit")
        third=F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>3.);request_id="third-epoch-edit")
        # Windows wall-clock timestamps can be identical for rapid batch edits.
        # Their delivery order must come from the serialized enqueue sequence.
        for operation in (first,second,third)
            F.boxer_control_broker(st).operations[operation["id"]]["created_at"]=first["created_at"]
        end
        @test first["sequence"]<second["sequence"]<third["sequence"]
        @test first["expected_study_epoch"]==11
        @test second["expected_study_epoch"]==11
        @test !haskey(first,"expected_revision") && !haskey(second,"expected_revision")
        delivered=only(F.boxer_control_poll!(st,auth)["commands"])
        @test delivered["id"]==first["id"]
        @test delivered["expected_study_epoch"]==11
        @test !haskey(delivered,"expected_revision")
        updated=Dict("revision"=>2,"study"=>Dict("epoch"=>11,"title"=>"First Study"))
        F.boxer_control_result!(st,merge(auth,Dict("id"=>first["id"],"state"=>updated,"result"=>Dict("ok"=>true))))
        next=only(F.boxer_control_poll!(st,auth)["commands"])
        @test next["id"]==second["id"]
        @test next["expected_study_epoch"]==11
        @test !haskey(next,"expected_revision")
        replaced=Dict("revision"=>3,"study"=>Dict("epoch"=>12,"title"=>"Replacement Study"))
        F.boxer_control_result!(st,merge(auth,Dict("id"=>second["id"],"state"=>replaced,"result"=>Dict("ok"=>true))))
        stale=only(F.boxer_control_poll!(st,auth)["commands"])
        @test stale["id"]==third["id"]
        @test stale["expected_study_epoch"]==11
        @test F.boxer_control_snapshot(st)["state"]["study"]["epoch"]==12
        F.boxer_control_result!(st,merge(auth,Dict("id"=>stale["id"],"state"=>replaced,"error"=>"The Study was replaced before this queued edit was applied.")))
        @test F.boxer_control_operation(st,third["id"])["state"]=="failed"
        @test F.boxer_control_snapshot(st)["state"]["study"]["epoch"]==12
        @test F.boxer_control_enqueue!(st,"set_input",Dict("input_id"=>"skin-mm","value"=>2.);request_id="first-epoch-edit")["id"]==first["id"]

        for command in ("get_state","list_actions","list_inputs")
            readonly=F.boxer_control_enqueue!(st,command)
            @test !haskey(readonly,"expected_study_epoch")
            @test F.boxer_control_cancel!(st,readonly["id"])["cancelled"]
        end
        current=F.boxer_control_enqueue!(st,"navigate",Dict("target"=>"Geometry"))
        @test current["expected_study_epoch"]==12
        F.boxer_control_cancel!(st,current["id"])
        F.boxer_control_poll!(st,merge(auth,Dict("state"=>Dict("revision"=>4,"title"=>"Legacy state without Study epoch"))))
        legacy=F.boxer_control_enqueue!(st,"navigate",Dict("target"=>"Geometry"))
        @test !haskey(legacy,"expected_study_epoch")
        F.stop_boxer_control!(st)
    end
end

@testset "Repeated native RPC IDs do not duplicate unkeyed mutations" begin
    mktempdir() do folder
        st=F.State(folder);F.configure_boxer_mcp!(st,"http://127.0.0.1:8080/")
        F.connect(st)
        init=F.rpc(st,F.message(1,"initialize",Dict("protocolVersion"=>"2025-11-25")))
        session=HTTP.header(init,"Mcp-Session-Id","")
        F.rpc(st,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized");session)
        arguments=Dict("action_id"=>"create-fem")
        call=F.message(11,"tools/call",Dict("name"=>"invoke_action","arguments"=>arguments))
        original=JSON.parse(String(F.rpc(st,call;session).body))["result"]["structuredContent"]
        repeat=JSON.parse(String(F.rpc(st,call;session).body))["result"]["structuredContent"]
        @test original["id"]==repeat["id"]
        @test length(F.boxer_control_broker(st).operations)==1
        @test !haskey(arguments,"request_id")
        another=JSON.parse(String(F.rpc(st,F.message(12,"tools/call",Dict("name"=>"invoke_action","arguments"=>arguments));session).body))["result"]["structuredContent"]
        @test another["id"]!=original["id"]
        @test length(F.boxer_control_broker(st).operations)==2
        explicit=Dict("action_id"=>"create-fem","request_id"=>"caller-provided-id")
        given=JSON.parse(String(F.rpc(st,F.message(13,"tools/call",Dict("name"=>"invoke_action","arguments"=>explicit));session).body))["result"]["structuredContent"]
        given_again=JSON.parse(String(F.rpc(st,F.message(14,"tools/call",Dict("name"=>"invoke_action","arguments"=>explicit));session).body))["result"]["structuredContent"]
        @test given["id"]==given_again["id"]
        @test length(F.boxer_control_broker(st).operations)==3
        @test F.boxer_control_broker(st).operations[given["id"]]["request_id"]=="caller-provided-id"
        changed=JSON.parse(String(F.rpc(st,F.message(11,"tools/call",Dict("name"=>"invoke_action","arguments"=>Dict("action_id"=>"create-fem","arguments"=>Dict("different"=>true))));session).body))["result"]
        @test changed["isError"]
        @test length(F.boxer_control_broker(st).operations)==3
        F.stop_boxer_control!(st)
    end
end
