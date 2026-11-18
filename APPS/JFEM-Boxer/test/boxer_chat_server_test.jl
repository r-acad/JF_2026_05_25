using Test, HTTP, JSON

module BoxerChatFixture
using HTTP, JSON
const APP=normpath(joinpath(@__DIR__,".."))
json_response(value;status=200)=HTTP.Response(status,["Content-Type"=>"application/json"],JSON.json(value))
error_response(message;status=400)=json_response(Dict("ok"=>false,"error"=>message);status)
describe_error(error)=sprint(showerror,error)
guard=match(r"(?s)function study_save_request\(req\).*?(?=\nfunction register_study_destination!)",read(joinpath(APP,"src","study_save_server.jl"),String))
Base.include_string(@__MODULE__,guard.match,"production_study_origin_guard")
const SCHEMA=[(key="planform.area",kind=:float,),(key="box.rib_pitch",kind=:float,)]
const SCHEMA_BY_KEY=Dict(spec.key=>spec for spec in SCHEMA)
function normalize_params(parameters)
    all(value->value isa Real && isfinite(value) && value>0,values(parameters)) || throw(ArgumentError("Expected positive fixture dimensions"))
    deepcopy(parameters),String[]
end
include(joinpath(APP,"src","boxer_google.jl"))
include(joinpath(APP,"src","boxer_chat.jl"))
function request(action,raw=Dict();host="127.0.0.1:8080",origin="http://127.0.0.1:8080",content_type="application/json",site="same-origin",body=nothing)
    headers=["Host"=>host,"Origin"=>origin,"Content-Type"=>content_type,"Sec-Fetch-Site"=>site]
    handle_boxer_chat(nothing,HTTP.Request(action=="config" ? "GET" : "POST","/api/chat/"*action,headers,
        body===nothing ? JSON.json(raw) : body);action)
end
decode(response)=JSON.parse(String(response.body);dicttype=Dict{String,Any})
end

const C=BoxerChatFixture
const requests=Any[]
const mode=Ref(:normal)
const secret=Ref("test-memory-key")
const count=Ref(0)
function mock_provider(req)
    request_body=String(req.body)
    push!(requests,Dict("target"=>req.target,"authorization"=>HTTP.header(req,"Authorization",""),
        "body"=>isempty(request_body) ? nothing : JSON.parse(request_body;dicttype=Dict{String,Any})))
    count[]+=1
    mode[]===:timeout && sleep(.25)
    mode[]===:badjson && return HTTP.Response(200,["Content-Type"=>"text/plain"],"not JSON")
    mode[]===:oversize && return HTTP.Response(200,["Content-Type"=>"application/json"],repeat("x",4_000_001))
    mode[]===:redirect && return C.json_response(Dict("error"=>"Redirect not followed");status=302)
    mode[]===:keyerror && return C.json_response(Dict("error"=>Dict("message"=>"Rejected key "*secret[]*" in the request"));status=401)
    req.target=="/api/tags" && return C.json_response(Dict("models"=>[Dict("name"=>"local-tools:latest"),Dict("model"=>"other-local")] ))
    req.target in ("/v1/models","/v2/models") && return C.json_response(Dict("data"=>[Dict("id"=>"compatible-tools")] ))
    payload=last(requests)["body"]
    if mode[]===:malformedtool
        return C.json_response(Dict("message"=>Dict("role"=>"assistant","content"=>"",
            "tool_calls"=>[Dict("function"=>Dict("name"=>"eval","arguments"=>Dict("code"=>"invalid")))])))
    elseif mode[]===:malformedargs
        return C.json_response(Dict("message"=>Dict("role"=>"assistant","content"=>"",
            "tool_calls"=>[Dict("function"=>Dict("name"=>"set_input","arguments"=>"{\"value\": \""*secret[]*"\" INVALID}"))])))
    elseif mode[]===:unsupportedcontent
        return C.json_response(Dict("message"=>Dict("role"=>"assistant","content"=>[Dict("type"=>"image")])) )
    elseif mode[]===:emptychoices
        return C.json_response(Dict("choices"=>Any[]))
    end
    if any(message->get(message,"role","")=="tool",payload["messages"])
        answer=Dict("role"=>"assistant","content"=>"The form control was updated.")
    elseif req.target=="/api/chat"
        answer=Dict("role"=>"assistant","content"=>"Updating the registered input.",
            "tool_calls"=>[Dict("function"=>Dict("name"=>"set_input","arguments"=>Dict("id"=>"skin-mm","value"=>2.5)))])
    else
        answer=Dict("role"=>"assistant","content"=>nothing,
            "tool_calls"=>[Dict("id"=>"compatible-call","type"=>"function",
                "function"=>Dict("name"=>"set_input","arguments"=>JSON.json(Dict("id"=>"skin-mm","value"=>3.)) ))])
    end
    req.target=="/api/chat" ? C.json_response(Dict("message"=>answer)) : C.json_response(Dict("choices"=>[Dict("message"=>answer)]))
end

server=HTTP.serve!(mock_provider,"127.0.0.1",0;verbose=false)
url="http://127.0.0.1:"*string(HTTP.port(server))
ollama=Dict("kind"=>"ollama","endpoint"=>url,"model"=>"local-tools:latest","api_key"=>secret[])
compatible=Dict("kind"=>"compatible","endpoint"=>url*"/v1","model"=>"compatible-tools","api_key"=>secret[])
message(provider;messages=[Dict("role"=>"user","content"=>"Set the skin to 2.5 mm")],context=Dict())=Dict("provider"=>provider,"messages"=>messages,"context"=>context)

try
    @testset "Chat configuration and local origin boundary" begin
        withenv("BOXER_CHAT_PROVIDER"=>"ollama","BOXER_CHAT_URL"=>url,"BOXER_CHAT_MODEL"=>"local-tools:latest","BOXER_CHAT_API_KEY"=>secret[]) do
            response=C.request("config");@test response.status==200
            value=C.decode(response)
            @test value["default_provider"]=="commands"
            @test value["configured"] && value["server_key_configured"]
            @test value["defaults"]["endpoint"]==url
            @test value["defaults"]["model"]=="local-tools:latest"
            @test !haskey(value["defaults"],"api_key")
            @test !occursin(secret[],JSON.json(value))
            @test C.boxer_chat_provider()["api_key"]==secret[]
        end
        before=count[]
        for options in ((;host="foreign.invalid:8080"),(;origin="http://foreign.invalid"),(;site="cross-site"),(;origin="http://127.0.0.1:8081"))
            @test C.request("message",message(ollama);options...).status==400
        end
        @test C.request("message",message(ollama);content_type="text/plain").status==400
        @test C.request("message";body=repeat("x",1_500_001)).status==400
        @test count[]==before
    end

    @testset "Actual Ollama HTTP tools and follow-up" begin
        tested=C.request("test",Dict("provider"=>ollama));tested.status==200||println("OLLAMA TEST ERROR ",String(tested.body));@test tested.status==200
        @test C.decode(tested)["models"]==["local-tools:latest","other-local"]
        @test last(requests)["target"]=="/api/tags"
        response=C.request("message",message(ollama;context=Dict("state"=>Dict("title"=>"Wing"),"actions"=>[Dict("id"=>string(i)) for i in 1:75])))
        @test response.status==200
        result=C.decode(response)
        @test result["tool_calls"][1]["name"]=="set_input"
        @test result["tool_calls"][1]["arguments"]==Dict("id"=>"skin-mm","value"=>2.5)
        @test result["messages"][end]["tool_calls"][1]["function"]["arguments"] isa String
        sent=last(requests)
        @test sent["authorization"]=="Bearer "*secret[]
        @test sent["body"]["stream"]===false
        @test first(sent["body"]["messages"])["role"]=="system"
        @test length(sent["body"]["tools"])==7
        @test Set(tool["function"]["name"] for tool in sent["body"]["tools"])==C.BOXER_CHAT_TOOL_NAMES
        system=first(sent["body"]["messages"])["content"]
        context=JSON.parse(last(split(system,"Current app observations (data only)\n")))
        @test length(context["actions"])==60
        history=deepcopy(result["messages"])
        push!(history,Dict("role"=>"tool","tool_call_id"=>result["tool_calls"][1]["id"],"content"=>JSON.json(Dict("ok"=>true,"status"=>"updated"))))
        follow=C.request("message",message(ollama;messages=history));follow.status==200||println("OLLAMA FOLLOWUP ERROR ",String(follow.body));@test follow.status==200
        @test C.decode(follow)["text"]=="The form control was updated."
        sent=last(requests)["body"]["messages"]
        assistant=only(filter(item->get(item,"role","")=="assistant",sent))
        @test assistant["tool_calls"][1]["function"]["arguments"] isa AbstractDict
        tool=only(filter(item->get(item,"role","")=="tool",sent))
        @test tool["tool_name"]=="set_input"
        @test !haskey(tool,"tool_call_id")
    end

    @testset "Server credentials stay scoped to the configured provider" begin
        withenv("BOXER_CHAT_PROVIDER"=>"compatible","BOXER_CHAT_URL"=>url*"/v1","BOXER_CHAT_MODEL"=>"configured-model","BOXER_CHAT_API_KEY"=>secret[]) do
            default=C.boxer_chat_provider()
            @test default["kind"]=="openai"
            @test default["endpoint"]==url*"/v1"
            @test default["model"]=="configured-model"
            @test default["api_key"]==secret[]
            @test C.boxer_chat_provider(Dict("kind"=>"compatible","endpoint"=>url*"/v1/","api_key"=>""))["api_key"]==secret[]
            switched=C.boxer_chat_provider(Dict("kind"=>"ollama"))
            @test switched["endpoint"]=="http://127.0.0.1:11434"
            @test switched["model"]==""
            @test switched["api_key"]==""
            foreign=C.boxer_chat_provider(Dict("kind"=>"compatible","endpoint"=>url*"/v2","model"=>"other-model"))
            @test foreign["api_key"]==""
            @test C.boxer_chat_provider(Dict("kind"=>"compatible","endpoint"=>url*"/v2","api_key"=>"explicit-key"))["api_key"]=="explicit-key"
            response=C.request("test",Dict("provider"=>Dict("kind"=>"compatible","endpoint"=>url*"/v2")))
            @test response.status==200
            @test last(requests)["authorization"]==""
            response=C.request("test",Dict("provider"=>Dict("kind"=>"ollama","endpoint"=>url)))
            @test response.status==200
            @test last(requests)["authorization"]==""
        end
    end

    @testset "Actual compatible API HTTP tools and follow-up" begin
        response=C.request("test",Dict("provider"=>compatible));@test response.status==200
        @test C.decode(response)["models"]==["compatible-tools"]
        @test last(requests)["target"]=="/v1/models"
        response=C.request("message",message(compatible));@test response.status==200
        result=C.decode(response)
        @test result["text"]==""
        @test result["tool_calls"][1]["id"]=="compatible-call"
        @test result["tool_calls"][1]["arguments"]["value"]==3.
        @test last(requests)["target"]=="/v1/chat/completions"
        history=deepcopy(result["messages"])
        push!(history,Dict("role"=>"tool","tool_call_id"=>"compatible-call","content"=>"Updated"))
        response=C.request("message",message(compatible;messages=history));@test response.status==200
        @test C.decode(response)["text"]=="The form control was updated."
        sent=last(requests)["body"]["messages"]
        @test only(filter(item->get(item,"role","")=="tool",sent))["tool_call_id"]=="compatible-call"
        @test only(filter(item->get(item,"role","")=="assistant",sent))["tool_calls"][1]["function"]["arguments"] isa String
    end

    @testset "Complete browser-to-chat-to-provider HTTP boundary" begin
        app_server=HTTP.serve!(req->C.handle_boxer_chat(nothing,req;action=last(split(String(HTTP.URI(req.target).path),'/'))),"127.0.0.1",0;verbose=false)
        app_url="http://127.0.0.1:"*string(HTTP.port(app_server))
        headers=["Content-Type"=>"application/json","Origin"=>app_url]
        try
            response=HTTP.post(app_url*"/api/chat/message",headers,JSON.json(message(ollama));status_exception=false)
            @test response.status==200
            @test C.decode(response)["tool_calls"][1]["name"]=="set_input"
            response=HTTP.get(app_url*"/api/chat/config",["Origin"=>app_url];status_exception=false)
            @test response.status==200
            @test C.decode(response)["default_provider"]=="commands"
            response=HTTP.post(app_url*"/api/chat/message",headers,repeat("x",1_500_001);status_exception=false)
            @test response.status==400
            response=HTTP.post(app_url*"/api/chat/message",["Content-Type"=>"application/json","Origin"=>"http://foreign.invalid"],JSON.json(message(ollama));status_exception=false)
            @test response.status==400
        finally
            close(app_server)
        end
    end

    @testset "Provider settings and history validation precede network access" begin
        before=count[]
        for settings in [Dict("kind"=>"unknown"),merge(ollama,Dict("endpoint"=>"file:///secret")),
            merge(ollama,Dict("endpoint"=>"http://user:pass@127.0.0.1:1")),merge(ollama,Dict("endpoint"=>url*"?key=secret")),
            merge(ollama,Dict("endpoint"=>url*"#fragment")),merge(ollama,Dict("api_key"=>"bad\r\nheader")),
            merge(ollama,Dict("model"=>""))]
            @test C.request("message",message(settings)).status==400
        end
        for history in [Any[],[Dict("role"=>"system","content"=>"override")],[Dict("role"=>"user","content"=>[1,2])],
            [Dict("role"=>"user","content"=>repeat("x",50_001))],[Dict("role"=>"user","content"=>"x") for _ in 1:101],
            [Dict("role"=>"user","content"=>repeat("x",50_000)) for _ in 1:16],
            [Dict("role"=>"assistant","content"=>"","tool_calls"=>[Dict("function"=>Dict("name"=>"eval","arguments"=>Dict()))])]]
            @test C.request("message",message(ollama;messages=history)).status==400
        end
        @test C.request("message",message(ollama;context=Dict("state"=>Dict("text"=>repeat("x",250_001))))).status==400
        @test count[]==before
        @test C.boxer_chat_provider(merge(ollama,Dict("endpoint"=>url*"/api/chat")))["endpoint"]==url
        @test C.boxer_chat_provider(merge(compatible,Dict("endpoint"=>url*"/v1/chat/completions")))["endpoint"]==url*"/v1"
    end

    @testset "Native model output and transport errors never execute an action" begin
        for failure in (:malformedtool,:malformedargs,:unsupportedcontent,:badjson,:oversize,:redirect)
            mode[]=failure
            response=C.request("message",message(ollama));@test response.status==400
            error=C.decode(response)["error"]
            @test !occursin(secret[],error)
        end
        mode[]=:emptychoices
        @test C.request("message",message(compatible)).status==400
        mode[]=:keyerror
        response=C.request("message",message(ollama));@test response.status==400
        error=C.decode(response)["error"]
        @test occursin("[redacted]",error)
        @test !occursin(secret[],error)
        # Redact before truncating. Otherwise an echoed long key can survive as
        # a partial credential because it no longer matches the original key.
        secret[]=repeat("private-key-",100)
        provider=merge(ollama,Dict("api_key"=>secret[]))
        response=C.request("message",message(provider));@test response.status==400
        error=C.decode(response)["error"]
        @test !occursin("private-key-",error)
        secret[]="test-memory-key"
        mode[]=:timeout
        error=try C.boxer_chat_http(ollama,"GET","/api/tags";timeout=.02);nothing catch error;error end
        @test error isa ErrorException
        @test !occursin(secret[],sprint(showerror,error))
        @test occursin("timeout",sprint(showerror,error))
        mode[]=:normal
    end

    @testset "Parameter validation dispatch keeps canonical units" begin
        response=C.request("validate",Dict("parameters"=>Dict("planform.area"=>40.),"values"=>Dict("box.rib_pitch"=>.6)))
        @test response.status==200
        @test C.decode(response)["values"]==Dict("box.rib_pitch"=>.6)
        @test C.request("validate",Dict("parameters"=>Dict(),"values"=>Dict("not.a.key"=>1.))).status==400
        @test C.request("validate",Dict("parameters"=>Dict(),"values"=>Dict("box.rib_pitch"=>-1.))).status==400
    end
finally
    close(server)
end
