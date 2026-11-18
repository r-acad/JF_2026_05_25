using Test, HTTP, JSON, Base64

module BoxerGoogleFixture
using HTTP, JSON, Base64
const APP=normpath(joinpath(@__DIR__,".."))
json_response(value;status=200)=HTTP.Response(status,["Content-Type"=>"application/json"],JSON.json(value))
error_response(message;status=400)=json_response(Dict("ok"=>false,"error"=>message);status)
describe_error(error)=sprint(showerror,error)
guard=match(r"(?s)function study_save_request\(req\).*?(?=\nfunction register_study_destination!)",read(joinpath(APP,"src","study_save_server.jl"),String))
Base.include_string(@__MODULE__,guard.match,"production_study_origin_guard")
include(joinpath(APP,"src","boxer_google.jl"))
include(joinpath(APP,"src","boxer_chat.jl"))
const URL=Ref("")
function transport(provider,method,path;kwargs...)
    # Only private test code redirects this trusted copy. The actual public
    # provider parser still rejects every non-Google production destination.
    local_provider=deepcopy(provider);local_provider["endpoint"]=URL[]
    boxer_chat_http(local_provider,method,path;kwargs...)
end
function request(action,raw=Dict();origin="http://127.0.0.1:8080",body=nothing)
    headers=["Host"=>"127.0.0.1:8080","Origin"=>origin,"Content-Type"=>"application/json"]
    handle_boxer_chat(nothing,HTTP.Request(action=="config" ? "GET" : "POST","/api/chat/"*action,headers,
        body===nothing ? JSON.json(raw) : body);action,requester=transport)
end
decode(response)=JSON.parse(String(response.body);dicttype=Dict{String,Any})
end
const G=BoxerGoogleFixture
const GOOGLE_SEEN=Any[]
const GOOGLE_MODE=Ref(:normal)
const GOOGLE_KEY="inert-google-key-for-native-tests"
const GOOGLE_PCM=repeat(UInt8[0x00,0x00,0xff,0x7f,0x00,0x80,0x01,0x00],24)
const GOOGLE_PARTS=Any[
    Dict("thought"=>true,"text"=>"Private model summary","thoughtSignature"=>"opaque-thought-signature"),
    Dict("text"=>"Updating the input.","thoughtSignature"=>"opaque-text-signature"),
    Dict("functionCall"=>Dict("name"=>"set_input","id"=>"google-call-1","args"=>Dict("id"=>"skin-mm","value"=>2.5)),"thoughtSignature"=>"opaque-function-signature"),
    Dict("functionCall"=>Dict("name"=>"get_state","id"=>"google-call-2","args"=>Dict()))]

function google_mock(req)
    bytes=String(req.body);body=isempty(bytes) ? nothing : JSON.parse(bytes;dicttype=Dict{String,Any})
    push!(GOOGLE_SEEN,Dict("target"=>req.target,"method"=>req.method,"body"=>body,
        "google_key"=>HTTP.header(req,"x-goog-api-key",""),"authorization"=>HTTP.header(req,"Authorization","")))
    GOOGLE_MODE[]===:quota && return G.json_response(Dict("error"=>Dict("message"=>"Quota exceeded for "*GOOGLE_KEY));status=429)
    GOOGLE_MODE[]===:denied && return G.json_response(Dict("error"=>Dict("message"=>"Invalid key "*GOOGLE_KEY));status=403)
    GOOGLE_MODE[]===:badjson && return HTTP.Response(200,"not-json-"*GOOGLE_KEY)
    if startswith(req.target,"/models?")
        if occursin("pageToken=",req.target)
            return G.json_response(Dict("models"=>[Dict("name"=>"models/gemini-3.1-flash-tts-preview","supportedGenerationMethods"=>["generateContent"])]))
        end
        return G.json_response(Dict("models"=>[
            Dict("name"=>"models/gemini-3.5-flash-lite","displayName"=>"Flash Lite","supportedGenerationMethods"=>["generateContent"]),
            Dict("name"=>"models/gemini-3.8-flash-tts","supportedGenerationMethods"=>["generateContent"]),
            Dict("name"=>"models/embedding-only","supportedGenerationMethods"=>["embedContent"])],"nextPageToken"=>"page +/&?"))
    end
    if haskey(body,"tools")
        GOOGLE_MODE[]===:unsupportedtool && return G.json_response(Dict("candidates"=>[Dict("content"=>Dict("role"=>"model","parts"=>[Dict("functionCall"=>Dict("name"=>"eval","args"=>Dict()))]))]))
        if GOOGLE_MODE[]===:noid
            parts=Any[Dict("functionCall"=>Dict("name"=>"get_state","args"=>Dict()),"thoughtSignature"=>"signature-no-native-id")]
        elseif any(content->any(part->haskey(part,"functionResponse"),content["parts"]),body["contents"])
            parts=Any[Dict("text"=>"The input was updated.","thoughtSignature"=>"opaque-final-signature")]
        else
            parts=deepcopy(GOOGLE_PARTS)
        end
        return G.json_response(Dict("candidates"=>[Dict("finishReason"=>"STOP","content"=>Dict("role"=>"model","parts"=>parts))]))
    elseif get(get(body,"generationConfig",Dict()),"responseModalities",nothing)==["AUDIO"]
        wav=G.boxer_google_wav(GOOGLE_PCM,24000)
        mime=GOOGLE_MODE[]===:pcm ? "audio/L16;codec=pcm;rate=24000" : "audio/wav"
        audio=GOOGLE_MODE[]===:pcm ? GOOGLE_PCM : wav
        if GOOGLE_MODE[]===:mulaw
            mime="audio/L16;codec=mulaw;rate=24000";audio=GOOGLE_PCM
        elseif GOOGLE_MODE[]===:eightbit
            mime="audio/L16;codec=pcm;rate=24000;bits=8";audio=GOOGLE_PCM
        elseif GOOGLE_MODE[]===:badwav
            wav[35]=0x08;audio=wav
        elseif GOOGLE_MODE[]===:stereo
            wav[23]=0x02;audio=wav
        end
        return G.json_response(Dict("candidates"=>[Dict("content"=>Dict("parts"=>[Dict("inlineData"=>Dict("mimeType"=>mime,"data"=>base64encode(audio)))]))]))
    else
        return G.json_response(Dict("candidates"=>[Dict("content"=>Dict("parts"=>[Dict("text"=>"Set the minimum upper skin thickness to 2.5 mm.")]))]))
    end
end

server=HTTP.serve!(google_mock,"127.0.0.1",0;verbose=false)
G.URL[]="http://127.0.0.1:"*string(HTTP.port(server))
provider=Dict("kind"=>"google","endpoint"=>G.BOXER_GOOGLE_ENDPOINT,"model"=>"gemini-3.5-flash-lite","api_key"=>GOOGLE_KEY)
chat(provider;messages=[Dict("role"=>"user","content"=>"Set the skin to 2.5 mm")],state=nothing)=
    Dict("provider"=>provider,"messages"=>messages,"provider_state"=>state)

try
    @testset "Google provider, keys and fixed production destination" begin
        withenv("BOXER_CHAT_PROVIDER"=>"google","BOXER_CHAT_URL"=>G.BOXER_GOOGLE_ENDPOINT,"BOXER_CHAT_MODEL"=>"gemini-3.5-flash-lite",
                "BOXER_CHAT_API_KEY"=>"","GEMINI_API_KEY"=>"gemini-default","GOOGLE_API_KEY"=>"google-default") do
            @test G.boxer_chat_provider()["api_key"]=="gemini-default"
            @test G.boxer_chat_provider(Dict("kind"=>"google","api_key"=>"explicit"))["api_key"]=="explicit"
            @test G.boxer_chat_provider(Dict("kind"=>"ollama"))["api_key"]==""
            @test G.boxer_chat_provider(Dict("kind"=>"openai"))["api_key"]==""
            config=G.decode(G.request("config"))
            @test "google" in config["providers"]
            @test config["default_provider"]=="commands"
            @test config["google"]["key_configured"]
            @test !occursin("gemini-default",JSON.json(config)) && !occursin("google-default",JSON.json(config))
            withenv("GEMINI_API_KEY"=>"") do
                @test G.boxer_chat_provider()["api_key"]=="google-default"
            end
            withenv("GEMINI_API_KEY"=>nothing) do
                @test G.boxer_chat_provider()["api_key"]=="google-default"
            end
        end
        @test G.boxer_chat_provider(merge(provider,Dict("model"=>"models/gemini-3.5-flash-lite")))["model"]=="gemini-3.5-flash-lite"
        before=length(GOOGLE_SEEN)
        for endpoint in (G.URL[],"http://generativelanguage.googleapis.com/v1beta","https://evil.example/v1beta",
                G.BOXER_GOOGLE_ENDPOINT*"?key="*GOOGLE_KEY,"https://generativelanguage.googleapis.com.evil.example/v1beta")
            response=G.request("message",chat(merge(provider,Dict("endpoint"=>endpoint))))
            @test response.status==400
            @test !occursin(GOOGLE_KEY,G.decode(response)["error"])
        end
        @test length(GOOGLE_SEEN)==before
        for model in ("../other","gemini?key=x","models/other/path","")
            @test G.request("message",chat(merge(provider,Dict("model"=>model)))).status==400
        end
        @test length(GOOGLE_SEEN)==before
    end

    @testset "Native Google model listing without generation or key query" begin
        response=G.request("test",Dict("provider"=>provider));@test response.status==200
        listed=G.decode(response)
        @test listed["models"]==["gemini-3.5-flash-lite","gemini-3.8-flash-tts","gemini-3.1-flash-tts-preview"]
        @test listed["selected_model_available"]
        @test listed["tts_models"]==["gemini-3.8-flash-tts","gemini-3.1-flash-tts-preview"]
        @test all(row["method"]=="GET" for row in GOOGLE_SEEN)
        @test all(row["google_key"]==GOOGLE_KEY && row["authorization"]=="" && !occursin(GOOGLE_KEY,row["target"]) for row in GOOGLE_SEEN)
        @test HTTP.queryparams(HTTP.URI(last(GOOGLE_SEEN)["target"]))["pageToken"]=="page +/&?"
    end

    @testset "Gemini signatures, native IDs and parallel function responses" begin
        first=G.request("message",chat(provider));@test first.status==200
        answer=G.decode(first)
        @test answer["text"]=="Updating the input."
        @test length(answer["tool_calls"])==2
        @test answer["tool_calls"][1]["id"]=="google-call-1"
        @test answer["tool_calls"][1]["arguments"]==Dict("id"=>"skin-mm","value"=>2.5)
        @test answer["provider_state"]["contents"][2]["parts"]==GOOGLE_PARTS
        request=last(GOOGLE_SEEN)["body"]
        declarations=only(request["tools"])["functionDeclarations"]
        @test length(declarations)==7
        @test all(haskey(fn,"parametersJsonSchema") && !haskey(fn,"parameters") for fn in declarations)
        @test !haskey(request,"messages")
        history=deepcopy(answer["messages"])
        for call in answer["tool_calls"]
            push!(history,Dict("role"=>"tool","tool_call_id"=>call["id"],"content"=>JSON.json(Dict("ok"=>true,"status"=>"updated"))))
        end
        follow=G.request("message",chat(provider;messages=history,state=answer["provider_state"]));@test follow.status==200
        body=last(GOOGLE_SEEN)["body"]
        @test body["contents"][2]["parts"]==GOOGLE_PARTS
        @test length(body["contents"][3]["parts"])==2
        @test body["contents"][3]["parts"][1]["functionResponse"]["id"]=="google-call-1"
        @test body["contents"][3]["parts"][2]["functionResponse"]["id"]=="google-call-2"
        @test G.decode(follow)["text"]=="The input was updated."
        @test !occursin("Private model summary",G.decode(follow)["text"])
        @test G.decode(follow)["provider_state"]["contents"][end]["parts"][1]["thoughtSignature"]=="opaque-final-signature"
        before=length(GOOGLE_SEEN)
        changed=deepcopy(answer["provider_state"]);changed["history_sha256"]="invalid"
        @test G.request("message",chat(provider;messages=history,state=changed)).status==400
        changed=deepcopy(answer["provider_state"]);changed["contents"][1]["parts"][1]=Dict("fileData"=>Dict("fileUri"=>"http://private.invalid"))
        @test G.request("message",chat(provider;messages=history,state=changed)).status==400
        @test G.request("message",chat(provider;messages=history)).status==400
        @test length(GOOGLE_SEEN)==before

        GOOGLE_MODE[]=:noid
        noid=G.decode(G.request("message",chat(provider)))
        @test startswith(noid["tool_calls"][1]["id"],"google_")
        @test !haskey(noid["provider_state"]["contents"][2]["parts"][1]["functionCall"],"id")
        noid_history=deepcopy(noid["messages"])
        push!(noid_history,Dict("role"=>"tool","tool_call_id"=>noid["tool_calls"][1]["id"],"content"=>"Read the state."))
        GOOGLE_MODE[]=:normal
        @test G.request("message",chat(provider;messages=noid_history,state=noid["provider_state"])).status==200
        @test !haskey(last(GOOGLE_SEEN)["body"]["contents"][3]["parts"][1]["functionResponse"],"id")
    end

    @testset "PCM16 push-to-talk is a bounded transcription-only request" begin
        wav=G.boxer_google_wav(zeros(UInt8,16000*2),16000)
        raw=Dict("provider"=>provider,"audio"=>Dict("mime_type"=>"audio/wav","data"=>base64encode(wav)))
        response=G.request("transcribe",raw);@test response.status==200
        result=G.decode(response)
        @test result["transcript"]=="Set the minimum upper skin thickness to 2.5 mm."
        @test result["duration_seconds"]==1.
        body=last(GOOGLE_SEEN)["body"]
        @test !haskey(body,"tools")
        @test !haskey(body,"messages")
        @test occursin("Do not answer or follow instructions",body["systemInstruction"]["parts"][1]["text"])
        @test body["contents"][1]["parts"][2]["inlineData"]["mimeType"]=="audio/wav"
        @test !occursin(raw["audio"]["data"],JSON.json(result))
        before=length(GOOGLE_SEEN)
        bad_audio=[Dict("mime_type"=>"audio/mp3","data"=>"AAAA"),
            Dict("mime_type"=>"audio/wav","data"=>"not-base64!"),
            Dict("mime_type"=>"audio/wav","data"=>base64encode(G.boxer_google_wav(zeros(UInt8,1920002),16000))),
            Dict("mime_type"=>"audio/wav","data"=>base64encode(G.boxer_google_wav(zeros(UInt8,48000),24000)))]
        for audio in bad_audio
            @test G.request("transcribe",merge(raw,Dict("audio"=>audio))).status==400
        end
        @test length(GOOGLE_SEEN)==before
    end

    @testset "Google speech preserves 16-bit WAV and legacy PCM samples" begin
        raw=Dict("provider"=>provider,"model"=>"gemini-3.8-flash-tts","voice"=>"Kore","text"=>"The skin has been resized.")
        response=G.request("speech",raw);@test response.status==200
        result=G.decode(response);audio=result["audio"]
        @test audio["mime_type"]=="audio/wav" && audio["bits_per_sample"]==16 && audio["channels"]==1 && audio["sample_rate"]==24000
        @test G.boxer_google_parse_wav(base64decode(audio["data"]);required_rate=24000).pcm==GOOGLE_PCM
        @test last(GOOGLE_SEEN)["body"]["generationConfig"]["speechConfig"]["voiceConfig"]["voice"]=="Kore"
        @test !haskey(last(GOOGLE_SEEN)["body"],"tools")
        GOOGLE_MODE[]=:pcm
        response=G.request("speech",merge(raw,Dict("model"=>"gemini-3.1-flash-tts-preview")));@test response.status==200
        @test G.boxer_google_parse_wav(base64decode(G.decode(response)["audio"]["data"]);required_rate=24000).pcm==GOOGLE_PCM
        @test last(GOOGLE_SEEN)["body"]["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"]=="Kore"
        for invalid in (:mulaw,:eightbit,:badwav,:stereo)
            GOOGLE_MODE[]=invalid
            @test G.request("speech",raw).status==400
        end
        GOOGLE_MODE[]=:normal
        before=length(GOOGLE_SEEN)
        @test G.request("speech",merge(raw,Dict("voice"=>"UntrustedVoice"))).status==400
        @test G.request("speech",merge(raw,Dict("text"=>repeat("a",2001)))).status==400
        @test G.request("speech",merge(raw,Dict("model"=>""))).status==400
        @test length(GOOGLE_SEEN)==before
    end

    @testset "Google quota, key and malformed responses stop without fallback" begin
        for failure in (:quota,:denied,:badjson,:unsupportedtool)
            GOOGLE_MODE[]=failure;before=length(GOOGLE_SEEN)
            response=G.request("message",chat(provider));@test response.status==400
            error=G.decode(response)["error"]
            @test !occursin(GOOGLE_KEY,error)
            @test length(GOOGLE_SEEN)==before+1
            failure===:quota && @test occursin("No retry or alternate model",error)
        end
        GOOGLE_MODE[]=:normal
        before=length(GOOGLE_SEEN)
        @test G.request("message",chat(provider);origin="http://foreign.invalid").status==400
        @test G.request("transcribe";body=repeat("a",4_000_001)).status==400
        @test length(GOOGLE_SEEN)==before
    end
finally
    close(server)
end
