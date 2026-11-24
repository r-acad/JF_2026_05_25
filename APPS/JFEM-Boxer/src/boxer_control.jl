import Random

"""Local, bounded command broker shared by MCP and Boxer's chat panel.

Commands are delivered to one authenticated browser and use its existing UI
handlers. This preserves unsaved changes, current selections and menu guards.
No endpoint evaluates Julia, JavaScript, shell commands or arbitrary files.
"""
mutable struct BoxerControlBroker
    token::String
    url::String
    discovery_file::String
    clients::Dict{String,Dict{String,Any}}
    operations::Dict{String,Dict{String,Any}}
    sessions::Dict{String,Dict{String,Any}}
    closed::Bool
end

struct BoxerControlAuthError <: Exception
    message::String
end
Base.showerror(io::IO,error::BoxerControlAuthError)=print(io,error.message)

const BOXER_CONTROL_LOCK=ReentrantLock()
const BOXER_CONTROL_BROKERS=WeakKeyDict{Any,BoxerControlBroker}()
const BOXER_CONTROL_CLIENT_TTL=120.0
const BOXER_CONTROL_QUEUE_TTL=120.0
const BOXER_CONTROL_EXECUTION_TTL=600.0
const BOXER_CONTROL_MAX_CLIENTS=16
const BOXER_CONTROL_MAX_OPERATIONS=256
const BOXER_CONTROL_COMMANDS=Set(["invoke_action","set_input","update_parameters","inspect","navigate",
    "get_state","list_actions","list_inputs","get_parameters"])

boxer_control_secret()=bytes2hex(rand(Random.RandomDevice(),UInt8,32))

function boxer_control_broker(st)
    lock(BOXER_CONTROL_LOCK) do
        get!(BOXER_CONTROL_BROKERS,st) do
            BoxerControlBroker(boxer_control_secret(),"","",Dict{String,Dict{String,Any}}(),
                Dict{String,Dict{String,Any}}(),Dict{String,Dict{String,Any}}(),false)
        end
    end
end

function boxer_control_secret_equal(actual,expected)
    actual isa AbstractString || return false
    a,b=codeunits(actual),codeunits(expected)
    length(a)==length(b) || return false
    difference=UInt8(0)
    for i in eachindex(a);difference|=a[i]⊻b[i];end
    difference==0
end

"""Validate local Host and Origin before reading or authenticating any control request."""
function boxer_control_origin_guard(req)
    host=HTTP.header(req,"Host","")
    isempty(host) && throw(BoxerControlAuthError("Boxer control requires the local application's Host header."))
    occursin(r"^(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]{1,5})?$",lowercase(host)) ||
        throw(BoxerControlAuthError("Boxer control only accepts loopback application hosts."))
    uri=try HTTP.URI("http://"*host) catch; throw(BoxerControlAuthError("Invalid local application host.")) end
    lowercase(String(uri.host)) in ("127.0.0.1","localhost","::1","[::1]") ||
        throw(BoxerControlAuthError("Boxer control only accepts loopback application hosts."))
    isempty(String(uri.path)) || String(uri.path)=="/" || throw(BoxerControlAuthError("Invalid local application host."))
    origin=HTTP.header(req,"Origin","")
    if !isempty(origin)
        source=try HTTP.URI(origin) catch; throw(BoxerControlAuthError("Invalid application origin.")) end
        authority=String(source.host)*(isempty(source.port) ? "" : ":"*String(source.port))
        String(source.scheme) in ("http","https") && authority==host &&
            String(source.path) in ("","/") && isempty(String(source.query)) && isempty(String(source.fragment)) ||
            throw(BoxerControlAuthError("Boxer control requires the application's own origin."))
    end
    nothing
end

function boxer_control_origin_guard(st,req)
    boxer_control_origin_guard(req)
    configured=boxer_control_broker(st).url
    if !isempty(configured)
        expected=HTTP.URI(configured)
        actual=HTTP.URI("http://"*HTTP.header(req,"Host",""))
        String(actual.port)==String(expected.port) || throw(BoxerControlAuthError("The request Host does not identify this Boxer listener."))
        origin=HTTP.header(req,"Origin","")
        isempty(origin) || String(HTTP.URI(origin).scheme)==String(expected.scheme) ||
            throw(BoxerControlAuthError("The request Origin does not identify this Boxer listener."))
    end
    nothing
end

function boxer_control_json_request(req;max_bytes=8*1024^2)
    boxer_control_origin_guard(req)
    length(req.body)<=max_bytes || throw(ArgumentError("The control request exceeds the 8 MiB limit."))
    value=study_save_request(req)
    value isa AbstractDict || throw(ArgumentError("Expected a control request object."))
    value
end

function boxer_control_bearer_guard(st,req)
    boxer_control_origin_guard(st,req)
    authorization=HTTP.header(req,"Authorization","")
    startswith(authorization,"Bearer ") || throw(BoxerControlAuthError("The Boxer MCP connection requires its local bearer token."))
    broker=boxer_control_broker(st)
    boxer_control_secret_equal(authorization[8:end],broker.token) || throw(BoxerControlAuthError("The Boxer MCP connection token is invalid or has expired."))
    broker.closed && throw(BoxerControlAuthError("The Boxer control server has stopped."))
    broker
end

function boxer_control_bounded(value,label,limit)
    ncodeunits(JSON.json(value))<=limit || throw(ArgumentError("$label exceeds the control interface size limit."))
    deepcopy(value)
end

function boxer_control_prune!(broker;now=time())
    for operation in values(broker.operations)
        state=operation["state"]
        if state=="queued" && now-operation["created_at"]>BOXER_CONTROL_QUEUE_TTL
            operation["state"]="expired";operation["finished_at"]=now
            operation["error"]="The browser did not receive this command before it expired. Check the app state before retrying."
        elseif state=="running" && now-get(operation,"started_at",operation["created_at"])>BOXER_CONTROL_EXECUTION_TTL
            operation["state"]="expired";operation["finished_at"]=now
            operation["error"]="Command delivery was recorded, but completion was not confirmed. Check the app and its dialogs before retrying."
        end
    end
    while length(broker.operations)>BOXER_CONTROL_MAX_OPERATIONS-1
        terminal=[op for op in values(broker.operations) if !(op["state"] in ("queued","running"))]
        isempty(terminal) && break
        oldest=argmin(op->(get(op,"sequence",0),op["created_at"]),terminal)
        delete!(broker.operations,oldest["id"])
    end
    for (id,session) in collect(broker.sessions)
        now-session["last_seen"]>3600 && delete!(broker.sessions,id)
    end
    nothing
end

function boxer_control_public_client(client;now=time())
    state=client["state"]
    study=get(state,"study",nothing)
    candidates=study isa AbstractDict ? Any[get(study,key,nothing) for key in ("title","name","path")] : Any[]
    append!(candidates,[get(state,"title",nothing),client["label"]])
    selected=findfirst(value->value isa AbstractString && !isempty(strip(value)),candidates)
    title=selected===nothing ? "Boxer Study" : first(String(candidates[selected]),512)
    Dict{String,Any}("client_id"=>client["id"],"label"=>client["label"],
        "connected"=>now-client["last_seen"]<=BOXER_CONTROL_CLIENT_TTL,
        "seconds_since_seen"=>round(max(0.,now-client["last_seen"]);digits=1),
        "revision"=>get(state,"revision",nothing),"title"=>title)
end

function boxer_control_clients(st)
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        sort!([boxer_control_public_client(client) for client in values(broker.clients)];by=x->x["client_id"])
    end
end

function boxer_control_selected_client(broker,client_id="")
    broker.closed && throw(ArgumentError("Boxer control is stopped."))
    now=time()
    if !isempty(client_id)
        client=get(broker.clients,String(client_id),nothing)
        client===nothing && throw(ArgumentError("Unknown Boxer browser client. Call list_clients to select an open Study."))
        now-client["last_seen"]<=BOXER_CONTROL_CLIENT_TTL || throw(ArgumentError("This Boxer browser has stopped responding. Bring its tab to the foreground and reconnect."))
        return client
    end
    active=[client for client in values(broker.clients) if now-client["last_seen"]<=BOXER_CONTROL_CLIENT_TTL]
    isempty(active) && throw(ArgumentError("Open Boxer in a browser to connect its current Study."))
    length(active)==1 || throw(ArgumentError("Several Boxer browser tabs are connected. Call list_clients and provide client_id to choose the intended Study."))
    only(active)
end

function boxer_control_snapshot(st;client_id="")
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        client=boxer_control_selected_client(broker,client_id)
        Dict{String,Any}("client"=>boxer_control_public_client(client),"state"=>deepcopy(client["state"]))
    end
end

function boxer_control_catalog(st;client_id="")
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        client=boxer_control_selected_client(broker,client_id)
        Dict{String,Any}("client"=>boxer_control_public_client(client),"catalog"=>deepcopy(client["catalog"]))
    end
end

function boxer_control_validate_publication(raw)
    state=get(raw,"state",Dict{String,Any}())
    state isa AbstractDict || throw(ArgumentError("Browser state must be an object."))
    catalog=get(raw,"catalog",Dict{String,Any}("actions"=>Any[],"inputs"=>Any[]))
    catalog isa AbstractDict || throw(ArgumentError("The command catalog must be an object."))
    for key in ("actions","inputs")
        values=get(catalog,key,Any[])
        values isa AbstractVector || throw(ArgumentError("The $key catalog must be an array."))
        all(item->item isa AbstractDict && get(item,"id",nothing) isa AbstractString,values) ||
            throw(ArgumentError("Each $key entry requires an id."))
        ids=[item["id"] for item in values]
        length(ids)==length(unique(ids)) || throw(ArgumentError("The $key catalog contains duplicate IDs."))
    end
    boxer_control_bounded(state,"Browser state",2*1024^2),boxer_control_bounded(catalog,"Command catalog",4*1024^2)
end

function boxer_control_connect!(st,raw)
    state,catalog=boxer_control_validate_publication(raw)
    page_id=String(get(raw,"page_id",get(raw,"client_id","")))
    length(page_id)<=128 || throw(ArgumentError("Browser page ID is too long."))
    label=first(String(get(raw,"label",get(raw,"title","Boxer Study"))),200)
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        broker.closed && throw(ArgumentError("Boxer control is stopped."))
        existing=isempty(page_id) ? nothing : findfirst(client->client["page_id"]==page_id,broker.clients)
        if existing!==nothing
            client=broker.clients[existing]
            boxer_control_secret_equal(get(raw,"token",""),client["token"]) ||
                throw(BoxerControlAuthError("An existing browser page can reconnect only with its own connection token."))
            client["last_seen"]=time();client["label"]=label;client["state"]=state;client["catalog"]=catalog
        else
            stale=[id for (id,client) in broker.clients if time()-client["last_seen"]>BOXER_CONTROL_CLIENT_TTL]
            for id in stale
                any(op->op["client_id"]==id && op["state"] in ("queued","running"),values(broker.operations)) || delete!(broker.clients,id)
            end
            length(broker.clients)<BOXER_CONTROL_MAX_CLIENTS || throw(ArgumentError("Too many Boxer browser clients are connected. Close unused tabs and wait two minutes."))
            id="boxer_"*bytes2hex(rand(UInt8,8))
            client=Dict{String,Any}("id"=>id,"page_id"=>page_id,"token"=>boxer_control_secret(),"label"=>label,
                "last_seen"=>time(),"state"=>state,"catalog"=>catalog)
            broker.clients[id]=client
        end
        Dict{String,Any}("ok"=>true,"client_id"=>client["id"],"token"=>client["token"],"poll_ms"=>500)
    end
end

function boxer_control_browser_client(broker,raw)
    id=get(raw,"client_id","")
    id isa AbstractString || throw(BoxerControlAuthError("Invalid browser client."))
    client=get(broker.clients,String(id),nothing)
    client===nothing && throw(BoxerControlAuthError("The Boxer browser connection expired. Reconnect this tab."))
    boxer_control_secret_equal(get(raw,"token",""),client["token"]) || throw(BoxerControlAuthError("The Boxer browser connection token is invalid."))
    broker.closed && throw(BoxerControlAuthError("Boxer control is stopped."))
    client
end

function boxer_control_public_operation(operation)
    Dict{String,Any}(key=>deepcopy(value) for (key,value) in operation if !(key in ("fingerprint","request_id")))
end

function boxer_control_poll!(st,raw)
    publication=if haskey(raw,"state") || haskey(raw,"catalog")
        # Validate before acquiring the shared lock. An omitted catalog stays unchanged.
        boxer_control_validate_publication(raw)
    else
        nothing
    end
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        client=boxer_control_browser_client(broker,raw)
        client["last_seen"]=time()
        if publication!==nothing
            haskey(raw,"state") && (client["state"]=publication[1])
            haskey(raw,"catalog") && (client["catalog"]=publication[2])
        end
        commands=Any[]
        busy=any(op->op["client_id"]==client["id"] && op["state"]=="running",values(broker.operations))
        if !busy
            queued=sort!([op for op in values(broker.operations) if op["client_id"]==client["id"] && op["state"]=="queued"];
                by=op->(get(op,"sequence",0),op["created_at"]))
            if !isempty(queued)
                operation=first(queued)
                operation["state"]="running";operation["started_at"]=time()
                push!(commands,Dict{String,Any}(key=>deepcopy(operation[key]) for key in
                    ("id","command","arguments","expected_revision","expected_study_epoch","created_at") if haskey(operation,key)))
            end
        end
        Dict{String,Any}("ok"=>true,"commands"=>commands,"poll_ms"=>500)
    end
end

function boxer_control_result!(st,raw)
    result=boxer_control_bounded(get(raw,"result",nothing),"Command result",2*1024^2)
    publication=haskey(raw,"state") || haskey(raw,"catalog") ? boxer_control_validate_publication(raw) : nothing
    error=get(raw,"error",nothing)
    error===nothing || (error=first(error isa AbstractString ? String(error) : JSON.json(error),4000))
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        client=boxer_control_browser_client(broker,raw)
        id=String(get(raw,"id",""));operation=get(broker.operations,id,nothing)
        operation===nothing && throw(ArgumentError("Unknown or expired Boxer operation."))
        operation["client_id"]==client["id"] || throw(BoxerControlAuthError("This command belongs to a different browser."))
        if operation["state"] in ("done","failed")
            return Dict("ok"=>true,"operation"=>boxer_control_public_operation(operation),"duplicate"=>true)
        end
        operation["state"]=="running" || throw(ArgumentError("This operation is no longer awaiting a browser result."))
        # The acknowledgment is the read-after-write boundary for native tools.
        # Commit its fresh browser snapshot before making completion observable.
        if publication!==nothing
            haskey(raw,"state") && (client["state"]=publication[1])
            haskey(raw,"catalog") && (client["catalog"]=publication[2])
        end
        operation["state"]=error===nothing && !(result isa AbstractDict && get(result,"ok",true)===false) ? "done" : "failed"
        operation["result"]=result;operation["finished_at"]=time()
        error===nothing || (operation["error"]=error)
        if operation["state"]=="failed" && error===nothing
            operation["error"]=first(string(get(result,"error","The browser rejected this command.")),4000)
        end
        client["last_seen"]=time()
        Dict("ok"=>true,"operation"=>boxer_control_public_operation(operation))
    end
end

boxer_control_canonical(value::AbstractDict)="{"*join((JSON.json(String(key))*":"*boxer_control_canonical(value[key]) for key in sort!(collect(keys(value));by=String)),",")*"}"
boxer_control_canonical(value::AbstractVector)="["*join(boxer_control_canonical.(value),",")*"]"
boxer_control_canonical(value)=JSON.json(value)

function boxer_control_enqueue!(st,command::AbstractString,arguments=Dict{String,Any}();client_id="",request_id="",expected_revision=nothing)
    command in BOXER_CONTROL_COMMANDS || throw(ArgumentError("Unknown Boxer command. Use the published actions and inputs."))
    arguments isa AbstractDict || throw(ArgumentError("Command arguments must be an object."))
    args=boxer_control_bounded(arguments,"Command arguments",512*1024)
    ncodeunits(request_id)<=128 || throw(ArgumentError("request_id is too long."))
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        client=boxer_control_selected_client(broker,client_id)
        fingerprint=bytes2hex(SHA.sha256(boxer_control_canonical(Dict("command"=>command,"arguments"=>args,"expected_revision"=>expected_revision))))
        if !isempty(request_id)
            for operation in values(broker.operations)
                if operation["client_id"]==client["id"] && operation["request_id"]==request_id
                    operation["fingerprint"]==fingerprint || throw(ArgumentError("request_id was already used for a different command. No command was repeated."))
                    return boxer_control_public_operation(operation)
                end
            end
        end
        catalog=client["catalog"]
        if command in ("invoke_action","set_input")
            key=command=="invoke_action" ? "action_id" : "input_id"
            id=get(args,key,nothing)
            id isa AbstractString && !isempty(id) || throw(ArgumentError("$key is required."))
            command=="set_input" && !haskey(args,"value") && throw(ArgumentError("set_input requires value."))
            entries=get(catalog,command=="invoke_action" ? "actions" : "inputs",Any[])
            found=findfirst(item->get(item,"id",nothing)==id,entries)
            if found===nothing
                get(catalog,"truncated",false)===true || throw(ArgumentError("Unknown $key. Discover the current interface before changing the Study."))
            else
                get(entries[found],"enabled",true)===false && throw(ArgumentError("This control is currently disabled. Check the current Study, selection and active operation."))
                get(entries[found],"readonly",false)===true && command=="set_input" && throw(ArgumentError("This input is read-only."))
            end
        elseif command=="update_parameters"
            get(args,"values",nothing) isa AbstractDict || throw(ArgumentError("update_parameters requires a values object."))
        end
        length(broker.operations)<BOXER_CONTROL_MAX_OPERATIONS || throw(ArgumentError("The Boxer command queue is full. Wait for pending commands or cancel them."))
        count(op->op["client_id"]==client["id"] && op["state"] in ("queued","running"),values(broker.operations))<16 ||
            throw(ArgumentError("This browser already has sixteen pending commands. Wait for their results."))
        id="command_"*bytes2hex(rand(UInt8,12))
        sequence=isempty(broker.operations) ? 1 : 1+maximum(get(op,"sequence",0) for op in values(broker.operations))
        operation=Dict{String,Any}("id"=>id,"client_id"=>client["id"],"command"=>String(command),
            "arguments"=>args,"state"=>"queued","created_at"=>time(),"sequence"=>sequence,
            "request_id"=>String(request_id),"fingerprint"=>fingerprint)
        expected_revision===nothing || (operation["expected_revision"]=expected_revision)
        if !(command in ("get_state","list_actions","list_inputs"))
            study=get(client["state"],"study",nothing)
            epoch=study isa AbstractDict ? get(study,"epoch",nothing) : nothing
            if epoch isa Union{AbstractString,Integer} && !(epoch isa Bool)
                operation["expected_study_epoch"]=epoch
            end
        end
        broker.operations[id]=operation
        boxer_control_public_operation(operation)
    end
end

function boxer_control_operation(st,id::AbstractString)
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        operation=get(broker.operations,String(id),nothing)
        operation===nothing && throw(ArgumentError("Unknown or expired Boxer operation."))
        boxer_control_public_operation(operation)
    end
end

function boxer_control_cancel!(st,id::AbstractString)
    lock(BOXER_CONTROL_LOCK) do
        broker=boxer_control_broker(st);boxer_control_prune!(broker)
        operation=get(broker.operations,String(id),nothing)
        operation===nothing && throw(ArgumentError("Unknown or expired Boxer operation."))
        cancelled=operation["state"]=="queued"
        if cancelled
            operation["state"]="cancelled";operation["finished_at"]=time()
        end
        Dict("cancelled"=>cancelled,"operation"=>boxer_control_public_operation(operation),
            "message"=>cancelled ? "Queued command cancelled." : "The command has already been delivered or finished. To stop an active analysis, invoke its existing Cancel action in Boxer.")
    end
end

function configure_boxer_mcp!(st,url::AbstractString)
    uri=HTTP.URI(url)
    String(uri.scheme)=="http" && String(uri.host) in ("127.0.0.1","localhost","::1") &&
        String(uri.path) in ("","/") && isempty(String(uri.query)) && isempty(String(uri.fragment)) ||
        throw(ArgumentError("Boxer MCP must use the local HTTP listener's base URL."))
    broker=boxer_control_broker(st)
    lock(BOXER_CONTROL_LOCK) do
        broker.url=rstrip(String(url),'/')*"/api/mcp"
        folder=joinpath(st.deck_store_dir,"control");mkpath(folder)
        broker.discovery_file=joinpath(folder,"boxer_mcp_"*string(getpid())*"_"*String(uri.port)*".json")
        value=Dict("url"=>broker.url,"token"=>broker.token,"pid"=>getpid(),"application"=>"JFEM-Boxer",
            "protocol_versions"=>["2025-11-25","2025-06-18","2024-11-05"],"created_at"=>time())
        for path in (broker.discovery_file,joinpath(st.deck_store_dir,"boxer_mcp.json"))
            temporary=path*".tmp_"*bytes2hex(rand(UInt8,4))
            try
                open(io->JSON.print(io,value,2),temporary,"w")
                try chmod(temporary,0o600) catch end
                mv(temporary,path;force=true)
            finally
                isfile(temporary) && rm(temporary;force=true)
            end
        end
    end
    broker.discovery_file
end

function boxer_control_configuration(st)
    broker=boxer_control_broker(st)
    lock(BOXER_CONTROL_LOCK) do
        root=hasproperty(st,:root) ? st.root : normpath(joinpath(@__DIR__,".."))
        executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
        # The connection file with the fixed name is rewritten at every start, so a program that was set up once
        # keeps working after Boxer restarts. The file named after the process serves a second Boxer on its own.
        stable=hasproperty(st,:deck_store_dir) ? joinpath(st.deck_store_dir,"boxer_mcp.json") : ""
        discovery=!isempty(stable) && isfile(stable) ? stable : broker.discovery_file
        # No separator at the end of the project folder: a backslash before a closing quote breaks a pasted command line.
        project=String(rstrip(normpath(joinpath(root,"..","..")),['/','\\']))
        client_config=Dict("mcpServers"=>Dict("JFEM-Boxer"=>Dict("command"=>executable,
            "args"=>["--startup-file=no","--project="*project,
                joinpath(root,"BoxerMCP.jl"),"--discovery",discovery])))
        Dict{String,Any}("ok"=>true,"url"=>broker.url,"token"=>broker.token,
            "discovery_file"=>broker.discovery_file,"protocol_versions"=>["2025-11-25","2025-06-18","2024-11-05"],
            "clients"=>boxer_control_clients(st),"mcp_client_config"=>client_config)
    end
end

function handle_boxer_control(st,req;action="status")
    try
        boxer_control_origin_guard(st,req)
        if action in ("config","status")
            return json_response(action=="config" ? boxer_control_configuration(st) : Dict("ok"=>true,"clients"=>boxer_control_clients(st)))
        end
        raw=boxer_control_json_request(req)
        if action=="connect"
            return json_response(boxer_control_connect!(st,raw))
        elseif action=="poll"
            return json_response(boxer_control_poll!(st,raw))
        elseif action=="result"
            return json_response(boxer_control_result!(st,raw))
        elseif action=="disconnect"
            return lock(BOXER_CONTROL_LOCK) do
                broker=boxer_control_broker(st);client=boxer_control_browser_client(broker,raw)
                client["last_seen"]=0.0
                for operation in values(broker.operations)
                    operation["client_id"]==client["id"] && operation["state"]=="queued" || continue
                    operation["state"]="cancelled";operation["finished_at"]=time()
                end
                json_response(Dict("ok"=>true))
            end
        end
        error_response("Unknown Boxer control operation.";status=404)
    catch error
        error_response("Boxer control: "*sprint(showerror,error);status=error isa BoxerControlAuthError ? 403 : 400)
    end
end

function stop_boxer_control!(st)
    lock(BOXER_CONTROL_LOCK) do
        broker=get(BOXER_CONTROL_BROKERS,st,nothing)
        broker===nothing && return nothing
        broker.closed=true
        for operation in values(broker.operations)
            operation["state"] in ("queued","running") || continue
            operation["state"]="cancelled";operation["finished_at"]=time()
            operation["error"]="Boxer stopped before confirming completion."
        end
        empty!(broker.sessions)
        for path in (broker.discovery_file,joinpath(st.deck_store_dir,"boxer_mcp.json"))
            isempty(path) && continue
            try
                isfile(path) && get(JSON.parsefile(path),"token",nothing)==broker.token && rm(path;force=true)
            catch
                # Shutdown must not fail because an external editor locked a discovery file.
            end
        end
    end
    nothing
end
