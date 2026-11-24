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
# Scripted replies for one request each. An entry is a function (req,body) that
# returns a response, or `nothing` to use the ordinary mock behaviour.
const GOOGLE_QUEUE=Any[]
google_error(status,code,message;details=Any[])=G.json_response(Dict("error"=>Dict("code"=>status,"message"=>message,"status"=>code,"details"=>details));status)
# Captured from the real service on 2026-11-19 with a syntactically valid but unknown key.
const REAL_INVALID_KEY=(400,"INVALID_ARGUMENT","API key not valid. Please pass a valid API key.",Any[
    Dict("@type"=>"type.googleapis.com/google.rpc.ErrorInfo","reason"=>"API_KEY_INVALID","domain"=>"googleapis.com","metadata"=>Dict("service"=>"generativelanguage.googleapis.com")),
    Dict("@type"=>"type.googleapis.com/google.rpc.LocalizedMessage","locale"=>"en-US","message"=>"API key not valid. Please pass a valid API key.")])
# Captured from the real service on 2026-11-19 without any key.
const REAL_NO_KEY=(403,"PERMISSION_DENIED","Permission denied on the service.",Any[
    Dict("@type"=>"type.googleapis.com/google.rpc.ErrorInfo","reason"=>"ACCESS_DENIED","domain"=>"googleapis.com","metadata"=>Dict("service"=>"generativelanguage.googleapis.com")),
    Dict("@type"=>"type.googleapis.com/google.rpc.LocalizedMessage","locale"=>"en-US","message"=>"Permission denied on the service.")])
# Google's documented error object with its quota details. Not captured: a quota
# error cannot be produced without a working key.
quota_details(id,delay)=Any[Dict("@type"=>"type.googleapis.com/google.rpc.Help","links"=>[Dict("description"=>"Learn more about Gemini API quotas","url"=>"https://ai.google.dev/gemini-api/docs/rate-limits")]),
    Dict("@type"=>"type.googleapis.com/google.rpc.QuotaFailure","violations"=>[Dict("quotaMetric"=>"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId"=>id,"quotaDimensions"=>Dict("location"=>"global","model"=>"gemini-4-carbon"))]),
    Dict("@type"=>"type.googleapis.com/google.rpc.RetryInfo","retryDelay"=>delay)]
const QUOTA_ZERO=(429,"RESOURCE_EXHAUSTED","You exceeded your current quota, please check your plan and billing details.\n* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 0, model: gemini-4-carbon\nPlease retry in 34.2s.",quota_details("GenerateRequestsPerDayPerProjectPerModel-FreeTier","34s"))
const QUOTA_DAY=(429,"RESOURCE_EXHAUSTED","You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 250",quota_details("GenerateRequestsPerDayPerProjectPerModel-FreeTier","41s"))
const QUOTA_MINUTE=(429,"RESOURCE_EXHAUSTED","Resource has been exhausted (e.g. check quota).",quota_details("GenerateRequestsPerMinutePerProjectPerModel-FreeTier","34.2s"))
scripted(entry::Tuple)=(req,body)->google_error(entry[1],entry[2],entry[3];details=entry[4])
# A models.list page shaped like the real Model resource, with entries that a
# chat model picker must not choose and two that must not break the listing.
model_row(id,display;methods=["generateContent","countTokens"],description="",extra...)=merge(Dict{String,Any}("name"=>"models/"*id,"version"=>"001","displayName"=>display,
    "description"=>description,"inputTokenLimit"=>1048576,"outputTokenLimit"=>65536,"supportedGenerationMethods"=>methods,"temperature"=>1,"topP"=>0.95,"topK"=>64,"maxTemperature"=>2,"thinking"=>true),
    Dict{String,Any}(String(key)=>value for (key,value) in extra))
const GOOGLE_CATALOG=Any[
    model_row("gemini-2.5-flash","Gemini 2.5 Flash";description="Deprecated. Requests route to Gemini 3.5 Flash-Lite."),
    model_row("gemini-omni-1.2-flash","Gemini Omni Flash";description="Video generation and editing"),
    model_row("gemini-3.1-pro-preview","Gemini 3.1 Pro Preview"),
    model_row("gemini-4-carbon","Gemini 4 Carbon"),
    model_row("gemini-3-flash-preview","Gemini 3 Flash Preview"),
    model_row("gemini-3.5-flash-lite","Gemini 3.5 Flash-Lite"),
    model_row("gemini-4-hydrogen","Gemini 4 Hydrogen"),
    model_row("gemini-3.8-flash","Gemini 3.8 Flash";description="Stable   multimodal\nmodel"),
    model_row("gemini-3.8-live","Gemini 3.8 Live";methods=["bidiGenerateContent"]),
    model_row("gemini-3.8-flash-tts","Gemini 3.8 Flash TTS"),
    model_row("gemini-3.5-transcribe","Gemini 3.5 Transcribe"),
    model_row("gemini-nano-banana-2.1","Nano Banana 2.1"),
    model_row("gemini-embedding-2","Gemini Embedding 2";methods=["embedContent"]),
    model_row("gemma-3-27b-it","Gemma 3 27B"),
    Dict{String,Any}("name"=>"models/odd name:with@symbols","supportedGenerationMethods"=>["generateContent"]),
    Dict{String,Any}("name"=>"models/gemini-3.6-flash","supportedGenerationMethods"=>["generateContent"]),
    "not an object"]
catalog_page(req,body)=G.json_response(Dict("models"=>GOOGLE_CATALOG))
# A complete generateContent reply as documented, including fields Boxer ignores.
full_reply(parts;finish="STOP")=G.json_response(Dict("candidates"=>[Dict("content"=>Dict("role"=>"model","parts"=>parts),"finishReason"=>finish,"index"=>0,
    "safetyRatings"=>[Dict("category"=>"HARM_CATEGORY_HARASSMENT","probability"=>"NEGLIGIBLE")])],
    "usageMetadata"=>Dict("promptTokenCount"=>1840,"candidatesTokenCount"=>12,"thoughtsTokenCount"=>96,"totalTokenCount"=>1948,
        "promptTokensDetails"=>[Dict("modality"=>"TEXT","tokenCount"=>1840)]),"modelVersion"=>"gemini-3.8-flash","responseId"=>"r3sp0ns31d"))

const GOOGLE_PARTS=Any[
    Dict("thought"=>true,"text"=>"Private model summary","thoughtSignature"=>"opaque-thought-signature"),
    Dict("text"=>"Updating the input.","thoughtSignature"=>"opaque-text-signature"),
    Dict("functionCall"=>Dict("name"=>"set_input","id"=>"google-call-1","args"=>Dict("id"=>"skin-mm","value"=>2.5)),"thoughtSignature"=>"opaque-function-signature"),
    Dict("functionCall"=>Dict("name"=>"get_state","id"=>"google-call-2","args"=>Dict()))]

function google_mock(req)
    bytes=String(req.body);body=isempty(bytes) ? nothing : JSON.parse(bytes;dicttype=Dict{String,Any})
    push!(GOOGLE_SEEN,Dict("target"=>req.target,"method"=>req.method,"body"=>body,
        "google_key"=>HTTP.header(req,"x-goog-api-key",""),"authorization"=>HTTP.header(req,"Authorization","")))
    if !isempty(GOOGLE_QUEUE)
        # Scripted replies are closures defined after this server task started.
        reply=Base.invokelatest(popfirst!(GOOGLE_QUEUE),req,body)
        reply===nothing || return reply
    end
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

    @testset "Pasted keys and typed model names are normalized before any request" begin
        for pasted in ("  "*GOOGLE_KEY*" \r\n","\""*GOOGLE_KEY*"\"",GOOGLE_KEY[1:12]*" \n "*GOOGLE_KEY[13:end],"GEMINI_API_KEY="*GOOGLE_KEY,"\ufeff"*GOOGLE_KEY*"\u200b","key: '"*GOOGLE_KEY*"'")
            @test G.boxer_chat_provider(merge(provider,Dict("api_key"=>pasted)))["api_key"]==GOOGLE_KEY
            response=G.request("models",Dict("provider"=>merge(provider,Dict("api_key"=>pasted))));@test response.status==200
            @test last(GOOGLE_SEEN)["google_key"]==GOOGLE_KEY
        end
        before=length(GOOGLE_SEEN)
        response=G.request("test",Dict("provider"=>merge(provider,Dict("api_key"=>"clé-secrète-ñ"))));@test response.status==400
        @test G.decode(response)["code"]=="invalid_key"
        @test !occursin("secrète",G.decode(response)["error"])
        withenv("GEMINI_API_KEY"=>nothing,"GOOGLE_API_KEY"=>nothing,"BOXER_CHAT_API_KEY"=>nothing) do
            response=G.request("test",Dict("provider"=>merge(provider,Dict("api_key"=>"   \n"))))
            @test response.status==400 && G.decode(response)["code"]=="no_key"
            @test occursin("aistudio.google.com/apikey",G.decode(response)["error"])
        end
        response=G.request("message",chat(merge(provider,Dict("model"=>" "))))
        @test response.status==400 && G.decode(response)["code"]=="no_model"
        @test length(GOOGLE_SEEN)==before
        for typed in ("models/gemini-3.5-flash-lite","/models/gemini-3.5-flash-lite","  gemini-3.5-flash-lite\n","Gemini 3.5 Flash Lite")
            @test G.boxer_chat_provider(merge(provider,Dict("model"=>typed)))["model"]=="gemini-3.5-flash-lite"
        end
        response=G.request("message",chat(merge(provider,Dict("model"=>"models/gemini-3.5-flash-lite"))));@test response.status==200
        @test startswith(last(GOOGLE_SEEN)["target"],"/models/gemini-3.5-flash-lite:generateContent")
        error=G.decode(G.request("message",chat(merge(provider,Dict("model"=>"gemini<script>")))))["error"]
        @test occursin("is not a Google model name",error) && !occursin("<script>",error)
    end

    @testset "Google error bodies become a reason code and a next step" begin
        cases=[(REAL_INVALID_KEY,"invalid_key",r"did not accept this API key.*Copy button"),
            (REAL_NO_KEY,"permission",r"refused this key"),
            (QUOTA_ZERO,"quota",r"no allowance for the model “gemini-3.5-flash-lite” on the free tier.*choose another model"),
            (QUOTA_DAY,"quota",r"Today's allowance.*resets at midnight Pacific"),
            (QUOTA_MINUTE,"quota",r"Wait 35 seconds and send the message again"),
            ((404,"NOT_FOUND","models/gemini-3.5-flash-lite is not found for API version v1beta, or is not supported for generateContent. Call ListModels to see the list of available models and their supported methods.",Any[]),"model_not_found",r"does not offer the model “gemini-3.5-flash-lite”.*press Connect"),
            ((400,"FAILED_PRECONDITION","User location is not supported for the API use.",Any[]),"region",r"country or account"),
            ((400,"FAILED_PRECONDITION","Gemini API free tier is not available in your country. Please enable billing on your project in Google AI Studio.",Any[]),"region",r"billing"),
            ((403,"PERMISSION_DENIED","Your API key was reported as leaked. Please use another API key.",Any[]),"key_blocked",r"reported as leaked.*Create a new key"),
            ((403,"PERMISSION_DENIED","Requests to this API generativelanguage.googleapis.com method are blocked.",Any[Dict("@type"=>"type.googleapis.com/google.rpc.ErrorInfo","reason"=>"API_KEY_SERVICE_BLOCKED")]),"key_restricted",r"restriction"),
            ((403,"PERMISSION_DENIED","Generative Language API has not been used in project 123 before or it is disabled.",Any[Dict("@type"=>"type.googleapis.com/google.rpc.ErrorInfo","reason"=>"SERVICE_DISABLED")]),"api_disabled",r"not switched on"),
            ((403,"PERMISSION_DENIED","Free tier verification required for this project.",Any[Dict("@type"=>"type.googleapis.com/google.rpc.ErrorInfo","reason"=>"FREE_TIER_VERIFICATION_REQUIRED")]),"verification",r"verify this project"),
            ((402,"RESOURCE_EXHAUSTED","Your prepayment credits are depleted.",Any[]),"billing",r"prepaid credit"),
            ((400,"INVALID_ARGUMENT","Function call `set_input` in the `2.` content block is missing a `thought_signature`.",Any[]),"conversation_state",r"Clear conversation"),
            ((400,"INVALID_ARGUMENT","The input token count exceeds the maximum number of tokens allowed.",Any[]),"too_large",r"Clear conversation"),
            ((400,"INVALID_ARGUMENT","Unsupported field value.",Any[]),"request_rejected",r"Choose another model"),
            ((500,"INTERNAL","An internal error has occurred.",Any[]),"server_error",r"internal error"),
            ((504,"DEADLINE_EXCEEDED","Deadline expired before operation could complete.",Any[]),"timeout",r"time limit")]
        for (fixture,code,pattern) in cases
            before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,scripted(fixture))
            response=G.request("message",chat(provider));@test response.status==400
            result=G.decode(response)
            @test result["code"]==code
            @test occursin(pattern,result["error"])
            @test occursin("Google: HTTP $(fixture[1])",result["error"])
            @test !occursin(GOOGLE_KEY,result["error"])
            @test length(GOOGLE_SEEN)==before+1
        end
        # 503 is the one status that is repeated, once.
        before=length(GOOGLE_SEEN)
        overloaded=(503,"UNAVAILABLE","The model is overloaded. Please try again later.",Any[])
        push!(GOOGLE_QUEUE,scripted(overloaded),scripted(overloaded))
        result=G.decode(G.request("message",chat(provider)))
        @test result["code"]=="overloaded" && occursin("tried twice",result["error"])
        @test length(GOOGLE_SEEN)==before+2
        push!(GOOGLE_QUEUE,scripted(overloaded))
        @test G.request("message",chat(provider)).status==200
        @test length(GOOGLE_SEEN)==before+4
        # A proxy or sign-in page answering instead of Google.
        push!(GOOGLE_QUEUE,(req,body)->HTTP.Response(502,["Content-Type"=>"text/html"],"<html><body>Proxy authentication required "*GOOGLE_KEY*"</body></html>"))
        result=G.decode(G.request("message",chat(provider)))
        @test result["code"]=="blocked_response" && occursin("HTTP 502",result["error"]) && !occursin(GOOGLE_KEY,result["error"])
        # An echoed key is redacted before the message is shortened.
        push!(GOOGLE_QUEUE,(req,body)->google_error(400,"INVALID_ARGUMENT","Bad request for key "*GOOGLE_KEY*" "*repeat("x",600)))
        result=G.decode(G.request("message",chat(provider)))
        @test occursin("[redacted]",result["error"]) && !occursin(GOOGLE_KEY,result["error"])
        # Unreachable, refused and slow destinations never echo exception text.
        for (endpoint,timeout,code) in (("http://boxer-test-host.invalid",5.,"offline"),("http://127.0.0.1:9",5.,"network_blocked"))
            failure=try G.boxer_chat_http(merge(provider,Dict("endpoint"=>endpoint)),"GET","/models";timeout);nothing catch error;error end
            @test failure isa G.BoxerChatFailure && failure.code==code
            @test !occursin(GOOGLE_KEY,sprint(showerror,failure))
        end
        push!(GOOGLE_QUEUE,(req,body)->(sleep(.6);nothing))
        failure=try G.boxer_chat_http(merge(provider,Dict("endpoint"=>G.URL[])),"GET","/models?pageSize=1000";timeout=.1);nothing catch error;error end
        @test failure isa G.BoxerChatFailure && failure.code=="timeout" && occursin("did not answer",failure.message)
        sleep(.7);empty!(GOOGLE_QUEUE)
    end

    @testset "Connect ranks the listed models and confirms that one answers" begin
        push!(GOOGLE_QUEUE,catalog_page)
        listed=G.decode(G.request("models",Dict("provider"=>merge(provider,Dict("model"=>"")))))
        @test listed["models"]==["gemini-2.5-flash","gemini-omni-1.2-flash","gemini-3.1-pro-preview","gemini-4-carbon","gemini-3-flash-preview","gemini-3.5-flash-lite",
            "gemini-4-hydrogen","gemini-3.8-flash","gemini-3.8-flash-tts","gemini-3.5-transcribe","gemini-nano-banana-2.1","gemma-3-27b-it","gemini-3.6-flash"]
        @test listed["recommended"]==["gemini-3.8-flash","gemini-4-hydrogen","gemini-3.6-flash","gemini-3.5-flash-lite","gemini-3-flash-preview"]
        @test listed["chat_models"][end]=="gemini-2.5-flash"
        @test !any(id->id in listed["chat_models"],["gemini-omni-1.2-flash","gemini-3.8-flash-tts","gemini-3.5-transcribe","gemini-nano-banana-2.1","gemma-3-27b-it"])
        @test listed["tts_models"]==["gemini-3.8-flash-tts"]
        details=Dict(row["id"]=>row for row in listed["model_details"])
        @test details["gemini-3.8-flash"]["display_name"]=="Gemini 3.8 Flash" && details["gemini-3.8-flash"]["description"]=="Stable multimodal model"
        @test details["gemini-3.8-flash"]["recommended_rank"]==1 && details["gemini-3.8-flash"]["category"]=="chat"
        @test details["gemini-3.6-flash"]["display_name"]=="gemini-3.6-flash"
        @test details["gemini-3.8-flash-tts"]["category"]=="speech" && details["gemini-omni-1.2-flash"]["category"]=="other"
        @test !haskey(listed,"verified")
        # One press: list, then one short tool-calling request to the first choice.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,catalog_page)
        connected=G.decode(G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true)))
        @test connected["verified"] && connected["selected_model"]=="gemini-3.8-flash"
        @test occursin("answered a short test request",connected["message"])
        # A plain request first, then one that carries Boxer's actions.
        @test length(GOOGLE_SEEN)==before+3
        plain=GOOGLE_SEEN[end-1];ping=last(GOOGLE_SEEN)
        @test plain["method"]=="POST" && startswith(plain["target"],"/models/gemini-3.8-flash:generateContent")
        @test sort(collect(keys(plain["body"])))==["contents"]
        @test ping["method"]=="POST" && startswith(ping["target"],"/models/gemini-3.8-flash:generateContent")
        @test length(only(ping["body"]["tools"])["functionDeclarations"])==7
        @test !haskey(ping["body"],"generationConfig")
        # No allowance for the first choice: the next recommended model is tried.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,catalog_page,scripted(QUOTA_ZERO))
        connected=G.decode(G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true)))
        @test connected["verified"] && connected["selected_model"]=="gemini-4-hydrogen"
        @test occursin("“gemini-3.8-flash” was skipped",connected["message"])
        @test length(GOOGLE_SEEN)==before+4
        # A model the user chose is tested alone and never replaced silently.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,catalog_page,scripted(QUOTA_ZERO))
        connected=G.decode(G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"models/gemini-4-carbon")),"verify"=>true)))
        @test connected["ok"] && !connected["verified"] && connected["verify_code"]=="quota" && connected["selected_model"]=="gemini-4-carbon"
        @test occursin("“gemini-4-carbon” did not answer a short test request",connected["message"]) && occursin("no allowance",connected["message"])
        @test length(connected["models"])==13 && length(GOOGLE_SEEN)==before+2
        # At most two models are tried.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,catalog_page,scripted(QUOTA_ZERO),scripted(QUOTA_ZERO))
        connected=G.decode(G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true)))
        @test !connected["verified"] && occursin("the 2 models tried (gemini-3.8-flash, gemini-4-hydrogen)",connected["message"])
        @test connected["verify_stage"]=="plain"
        @test length(GOOGLE_SEEN)==before+3
        # A model that never answers is reported in seconds, with the stage that was silent.
        slow=(req,body)->(sleep(1.2);nothing);quiet=merge(provider,Dict("model"=>""))
        push!(GOOGLE_QUEUE,catalog_page,slow,slow);started=time()
        connected=G.boxer_google_connect(quiet,Dict("verify"=>true);requester=G.transport,plain_timeout=.3,tools_timeout=.3)
        @test time()-started<3
        @test !connected["verified"] && connected["verify_code"]=="timeout" && connected["verify_stage"]=="plain"
        @test occursin("the 2 models tried (gemini-3.8-flash, gemini-4-hydrogen) did not answer a short test request. Google did not answer within 0 seconds.",connected["message"])
        sleep(1.3);empty!(GOOGLE_QUEUE)
        # It answers plain requests but is silent once Boxer's actions are attached: the conservative form is tried.
        push!(GOOGLE_QUEUE,catalog_page,(req,body)->nothing,slow)
        connected=G.boxer_google_connect(quiet,Dict("verify"=>true);requester=G.transport,plain_timeout=2.,tools_timeout=.3)
        @test connected["verified"] && connected["selected_model"]=="gemini-3.8-flash"
        @test G.boxer_google_tool_style("gemini-3.8-flash")===:simple
        @test !haskey(only(last(GOOGLE_SEEN)["body"]["tools"])["functionDeclarations"][2],"parametersJsonSchema")
        sleep(1.3);empty!(G.BOXER_GOOGLE_TOOL_STYLE);empty!(GOOGLE_QUEUE)
        # Silent in both forms: said plainly, and no second model is made to wait as well.
        push!(GOOGLE_QUEUE,catalog_page,(req,body)->nothing,slow,slow);before=length(GOOGLE_SEEN)
        connected=G.boxer_google_connect(quiet,Dict("verify"=>true);requester=G.transport,plain_timeout=2.,tools_timeout=.3)
        @test !connected["verified"] && connected["verify_stage"]=="tools" && connected["verify_code"]=="timeout"
        @test occursin("“gemini-3.8-flash” answers a plain test request and not one that carries Boxer’s actions. Google did not answer within 0 seconds.",connected["message"])
        @test length(GOOGLE_SEEN)==before+4
        sleep(1.3);empty!(GOOGLE_QUEUE);empty!(G.BOXER_GOOGLE_TOOL_STYLE)
        # A key problem ends the attempt at once with its own explanation.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,scripted(REAL_INVALID_KEY))
        response=G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true))
        @test response.status==400 && G.decode(response)["code"]=="invalid_key" && length(GOOGLE_SEEN)==before+1
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,catalog_page,scripted((400,"FAILED_PRECONDITION","User location is not supported for the API use.",Any[])))
        response=G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true))
        @test response.status==400 && G.decode(response)["code"]=="region" && length(GOOGLE_SEEN)==before+2
        # A key whose project lists nothing usable.
        push!(GOOGLE_QUEUE,(req,body)->G.json_response(Dict("models"=>[model_row("gemini-embedding-2","Embedding";methods=["embedContent"])])))
        connected=G.decode(G.request("test",Dict("provider"=>merge(provider,Dict("model"=>"")),"verify"=>true)))
        @test !connected["verified"] && connected["verify_code"]=="no_chat_model" && isempty(connected["models"])
        @test G.boxer_google_rank("gemini-9.1-flash")>G.boxer_google_rank("gemini-9.1-flash-lite")>G.boxer_google_rank("gemini-9.1-pro")
        @test G.boxer_google_rank("gemini-9.1-flash")>G.boxer_google_rank("gemini-9.1-flash-preview-05-2031")
        @test G.boxer_google_rank("gemini-3.1-flash";newest=4.)>G.boxer_google_rank("gemini-2.5-flash";newest=4.)+1000
    end

    @testset "Rejected tool schema falls back once to the conservative declaration" begin
        model="gemini-3.6-flash";fallback=merge(provider,Dict("model"=>model))
        rejected=(req,body)->haskey(only(body["tools"])["functionDeclarations"][2],"parametersJsonSchema") ?
            google_error(400,"INVALID_ARGUMENT","Invalid JSON payload received. Unknown name \"parametersJsonSchema\" at 'tools[0].function_declarations[1]': Cannot find field.") : nothing
        text_args=(req,body)->full_reply(Any[Dict("functionCall"=>Dict("name"=>"update_parameters","id"=>"fc-1","args"=>Dict("values"=>"{\"planform.aspect_ratio\": 15}")),"thoughtSignature"=>"sig-fallback")])
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,rejected,text_args)
        response=G.request("message",chat(fallback));@test response.status==200
        answer=G.decode(response)
        @test length(GOOGLE_SEEN)==before+2
        simple=only(last(GOOGLE_SEEN)["body"]["tools"])["functionDeclarations"]
        @test all(fn->!haskey(fn,"parametersJsonSchema"),simple)
        @test !haskey(simple[1],"parameters")
        @test !occursin("additionalProperties",JSON.json(simple))
        byname=Dict(fn["name"]=>fn for fn in simple)
        @test byname["set_input"]["parameters"]["properties"]["value"]["anyOf"]==[Dict("type"=>"string"),Dict("type"=>"number"),Dict("type"=>"boolean")]
        @test byname["update_parameters"]["parameters"]["properties"]["values"]["type"]=="string"
        @test byname["set_input"]["parameters"]["required"]==["id","value"]
        @test answer["tool_calls"][1]["arguments"]==Dict("values"=>Dict("planform.aspect_ratio"=>15))
        @test answer["provider_state"]["contents"][2]["parts"][1]["functionCall"]["args"]["values"] isa String
        history=deepcopy(answer["messages"])
        push!(history,Dict("role"=>"tool","tool_call_id"=>"fc-1","content"=>JSON.json(Dict("ok"=>true))))
        before=length(GOOGLE_SEEN)
        follow=G.request("message",chat(fallback;messages=history,state=answer["provider_state"]));@test follow.status==200
        @test length(GOOGLE_SEEN)==before+1
        @test !haskey(only(last(GOOGLE_SEEN)["body"]["tools"])["functionDeclarations"][2],"parametersJsonSchema")
        @test last(GOOGLE_SEEN)["body"]["contents"][2]["parts"][1]["thoughtSignature"]=="sig-fallback"
        # Another model still starts with the JSON Schema form; unrelated 400s are not repeated.
        @test G.request("message",chat(provider)).status==200
        @test haskey(only(last(GOOGLE_SEEN)["body"]["tools"])["functionDeclarations"][2],"parametersJsonSchema")
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,scripted((400,"INVALID_ARGUMENT","Unsupported field value.",Any[])))
        @test G.request("message",chat(provider)).status==400
        @test length(GOOGLE_SEEN)==before+1
        empty!(G.BOXER_GOOGLE_TOOL_STYLE)
    end

    @testset "Complete and unusual generateContent replies" begin
        push!(GOOGLE_QUEUE,(req,body)->full_reply(Any[
            Dict("thought"=>true,"text"=>"Hidden reasoning","thoughtSignature"=>"sig-thought"),
            Dict("executableCode"=>Dict("language"=>"PYTHON","code"=>"print(1)")),
            Dict("inlineData"=>Dict("mimeType"=>"image/png","data"=>"AAAA")),
            Dict("text"=>"Setting the aspect ratio.","mediaResolution"=>Dict("level"=>"MEDIA_RESOLUTION_LOW")),
            Dict("functionCall"=>Dict("name"=>"set_input","id"=>"fc-9","args"=>Dict("id"=>"p-planform.aspect_ratio","value"=>15),"willContinue"=>false),"thoughtSignature"=>"sig-call"),
            Dict("functionCall"=>Dict("name"=>"get_state","id"=>"fc-10"))]))
        answer=G.decode(G.request("message",chat(provider)))
        @test answer["text"]=="Setting the aspect ratio."
        @test [call["name"] for call in answer["tool_calls"]]==["set_input","get_state"]
        @test answer["tool_calls"][2]["arguments"]==Dict()
        kept=answer["provider_state"]["contents"][2]["parts"]
        @test length(kept)==4
        @test kept[1]==Dict("thought"=>true,"text"=>"Hidden reasoning","thoughtSignature"=>"sig-thought")
        @test kept[2]==Dict("text"=>"Setting the aspect ratio.")
        @test kept[3]==Dict("functionCall"=>Dict("name"=>"set_input","id"=>"fc-9","args"=>Dict("id"=>"p-planform.aspect_ratio","value"=>15)),"thoughtSignature"=>"sig-call")
        @test kept[4]==Dict("functionCall"=>Dict("name"=>"get_state","id"=>"fc-10"))
        unusable=[((req,body)->G.json_response(Dict("candidates"=>[Dict("content"=>Dict("role"=>"model"),"finishReason"=>"MAX_TOKENS","index"=>0)],"usageMetadata"=>Dict("thoughtsTokenCount"=>65000))),r"used up its answer length.*MAX_TOKENS"),
            ((req,body)->G.json_response(Dict("promptFeedback"=>Dict("blockReason"=>"PROHIBITED_CONTENT"),"usageMetadata"=>Dict("promptTokenCount"=>9))),r"blocked this request before answering \(reason: PROHIBITED_CONTENT\)"),
            ((req,body)->G.json_response(Dict("candidates"=>Any[])),r"returned no response"),
            ((req,body)->G.json_response(Dict("candidates"=>[Dict("finishReason"=>"MALFORMED_FUNCTION_CALL","content"=>Dict("role"=>"model","parts"=>Any[]))])),r"invalid action request"),
            ((req,body)->G.json_response(Dict("candidates"=>[Dict("finishReason"=>"SAFETY")])),r"content filter"),
            ((req,body)->G.json_response(Dict("candidates"=>[Dict("finishReason"=>"MISSING_THOUGHT_SIGNATURE")])),r"Clear conversation"),
            ((req,body)->G.json_response(Dict("candidates"=>[Dict("finishReason"=>"OTHER","content"=>Dict("parts"=>Any[]))])),r"no content \(finish reason OTHER\)"),
            ((req,body)->full_reply(Any[Dict("inlineData"=>Dict("mimeType"=>"image/png","data"=>"AAAA"))]),r"only content that Boxer cannot use"),
            ((req,body)->full_reply(Any[Dict("functionCall"=>Dict("name"=>"delete_everything<b>","args"=>Dict()))]),r"does not provide \(“delete_everything\?b\?”\)")]
        for (reply,pattern) in unusable
            push!(GOOGLE_QUEUE,reply)
            response=G.request("message",chat(provider));@test response.status==400
            error=G.decode(response)["error"]
            @test occursin(pattern,error)
            @test occursin(r"No (Boxer )?action was executed",error)
        end
        wav=G.boxer_google_wav(zeros(UInt8,16000*2),16000)
        @test G.request("transcribe",Dict("provider"=>provider,"audio"=>Dict("mime_type"=>"audio/wav","data"=>base64encode(wav)))).status==200
        @test !haskey(last(GOOGLE_SEEN)["body"],"generationConfig")
        # A speech model that rejects one documented voice form gets the other.
        before=length(GOOGLE_SEEN);push!(GOOGLE_QUEUE,scripted((400,"INVALID_ARGUMENT","Invalid value at 'generation_config.speech_config.voice_config'.",Any[])))
        @test G.request("speech",Dict("provider"=>provider,"model"=>"gemini-3.8-flash-tts","voice"=>"Kore","text"=>"Done.")).status==200
        @test length(GOOGLE_SEEN)==before+2
        @test haskey(GOOGLE_SEEN[end-1]["body"]["generationConfig"]["speechConfig"]["voiceConfig"],"voice")
        @test last(GOOGLE_SEEN)["body"]["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"]=="Kore"
    end
finally
    close(server)
end
