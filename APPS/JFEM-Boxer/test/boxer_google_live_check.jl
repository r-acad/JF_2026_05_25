# Optional check of the Boxer chat server code against the real Google Gemini API.
# It is never part of the ordinary test run and sends nothing unless asked to:
#
#   julia --project=. APPS/JFEM-Boxer/test/boxer_google_live_check.jl
#       Without a key: confirms how Google rejects a missing and an invalid key
#       and that Boxer explains both. No quota is used.
#
#   set BOXER_GOOGLE_LIVE_KEY=<your key>      (PowerShell: $env:BOXER_GOOGLE_LIVE_KEY="<your key>")
#   julia --project=. APPS/JFEM-Boxer/test/boxer_google_live_check.jl
#       With a key: lists the models, lets Connect choose and test one, then runs
#       one tool-calling conversation turn and its follow-up. This uses a few
#       requests of the key's allowance. The key is read from the environment
#       only; it is never printed or written to disk.
#
# Optional: BOXER_GOOGLE_LIVE_MODEL=<model id> tests one particular model.
using Test, HTTP, JSON

module BoxerGoogleLive
using HTTP, JSON
const APP=normpath(joinpath(@__DIR__,".."))
json_response(value;status=200)=HTTP.Response(status,["Content-Type"=>"application/json"],JSON.json(value))
error_response(message;status=400)=json_response(Dict("ok"=>false,"error"=>message);status)
describe_error(error)=error isa ArgumentError ? error.msg : sprint(showerror,error)
guard=match(r"(?s)function study_save_request\(req\).*?(?=\nfunction register_study_destination!)",read(joinpath(APP,"src","study_save_server.jl"),String))
Base.include_string(@__MODULE__,guard.match,"production_study_origin_guard")
include(joinpath(APP,"src","boxer_google.jl"))
include(joinpath(APP,"src","boxer_chat.jl"))
function request(action,raw)
    headers=["Host"=>"127.0.0.1:8080","Origin"=>"http://127.0.0.1:8080","Content-Type"=>"application/json"]
    response=handle_boxer_chat(nothing,HTTP.Request("POST","/api/chat/"*action,headers,JSON.json(raw));action)
    response.status,JSON.parse(String(response.body);dicttype=Dict{String,Any})
end
end
const B=BoxerGoogleLive
const LIVE_KEY=get(ENV,"BOXER_GOOGLE_LIVE_KEY","")
safe(text)=isempty(LIVE_KEY) ? text : replace(text,LIVE_KEY=>"[key]")

@testset "Real Google service: missing and invalid keys" begin
    withenv("GEMINI_API_KEY"=>nothing,"GOOGLE_API_KEY"=>nothing,"BOXER_CHAT_API_KEY"=>nothing) do
        status,reply=B.request("test",Dict("provider"=>Dict("kind"=>"google","api_key"=>"  AIzaSyINVALIDKEYFORSHAPEPROBE000000000000 \n"),"verify"=>true))
        println("Invalid key  -> ",get(reply,"code","(none)")," :: ",reply["error"])
        @test status==400 && reply["code"]=="invalid_key"
        status,reply=B.request("test",Dict("provider"=>Dict("kind"=>"google","api_key"=>""),"verify"=>true))
        @test status==400 && reply["code"]=="no_key"
        failure=try B.boxer_chat_http(Dict("kind"=>"google","endpoint"=>B.BOXER_GOOGLE_ENDPOINT,"api_key"=>"\t"),"GET","/models");nothing catch error;error end
        @test failure isa B.BoxerChatFailure
        println("Blank header -> ",failure.code," :: ",failure.message)
    end
end

if isempty(LIVE_KEY)
    println("\nNo BOXER_GOOGLE_LIVE_KEY was set: the connection, model choice and tool-calling conversation were NOT exercised against the real service.")
else
    @testset "Real Google service: connect, choose a model, call a tool and continue" begin
        provider=Dict("kind"=>"google","api_key"=>LIVE_KEY,"model"=>get(ENV,"BOXER_GOOGLE_LIVE_MODEL",""))
        status,connected=B.request("test",Dict("provider"=>provider,"verify"=>true))
        println("Connect      -> HTTP ",status," :: ",safe(get(connected,"message",get(connected,"error",""))))
        @test status==200
        if status==200
            println("Listed       -> ",length(connected["models"])," models; recommended ",join(connected["recommended"],", "))
            println("Speech       -> ",join(connected["tts_models"],", "))
            @test get(connected,"verified",false)
            model=get(connected,"selected_model","")
            println("Selected     -> ",model," (tool declaration style: ",B.boxer_google_tool_style(model),")")
            if get(connected,"verified",false)
                provider["model"]=model
                context=Dict("state"=>Dict("application"=>"JFEM-Boxer","study"=>Dict("title"=>"Live check")),
                    "inputs"=>[Dict("id"=>"p-planform.aspect_ratio","label"=>"Base aspect ratio","value"=>"8","type"=>"number")])
                messages=Any[Dict("role"=>"user","content"=>"Set the aspect ratio to 15 using the set_input tool with id p-planform.aspect_ratio.")]
                status,opening=B.request("message",Dict("provider"=>provider,"messages"=>messages,"context"=>context))
                println("First turn   -> HTTP ",status," :: text ",repr(first(safe(get(opening,"text",get(opening,"error",""))),160))," :: tools ",JSON.json(get(opening,"tool_calls",Any[])))
                @test status==200
                if status==200 && !isempty(opening["tool_calls"])
                    parts=opening["provider_state"]["contents"][end]["parts"]
                    println("Signatures   -> ",count(part->haskey(part,"thoughtSignature"),parts)," of ",length(parts)," reply parts carry a thought signature; function-call ids: ",
                        join((string(get(part["functionCall"],"id","(none)")) for part in parts if haskey(part,"functionCall")),", "))
                    history=opening["messages"]
                    for call in opening["tool_calls"]
                        push!(history,Dict("role"=>"tool","tool_call_id"=>call["id"],"content"=>JSON.json(Dict("ok"=>true,"status"=>"updated","input_id"=>"p-planform.aspect_ratio","value"=>"15"))))
                    end
                    status,second=B.request("message",Dict("provider"=>provider,"messages"=>history,"context"=>context,"provider_state"=>opening["provider_state"]))
                    println("Follow-up    -> HTTP ",status," :: ",repr(first(safe(get(second,"text",get(second,"error",""))),300)))
                    @test status==200
                else
                    println("The model answered without calling a tool; the follow-up with a tool result was not exercised.")
                end
            end
        end
    end
end
