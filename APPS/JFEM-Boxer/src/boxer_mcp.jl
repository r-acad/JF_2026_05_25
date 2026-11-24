"""MCP JSON-RPC over authenticated loopback HTTP for the native stdio proxy."""
const BOXER_MCP_PROTOCOLS=["2025-11-25","2025-06-18","2024-11-05"]

struct BoxerMCPProtocolError <: Exception
    code::Int
    message::String
end
Base.showerror(io::IO,error::BoxerMCPProtocolError)=print(io,error.message)

boxer_mcp_property(type,description)=Dict("type"=>type,"description"=>description)
function boxer_mcp_tool(name,description,properties=Dict{String,Any}();required=String[],read_only=true)
    Dict{String,Any}("name"=>name,"description"=>description,
        "inputSchema"=>Dict("type"=>"object","properties"=>properties,"required"=>required,"additionalProperties"=>false),
        "annotations"=>Dict("readOnlyHint"=>read_only,"destructiveHint"=>!read_only,"idempotentHint"=>read_only,"openWorldHint"=>false))
end

function boxer_mcp_tools()
    client=boxer_mcp_property("string","Choose a browser from list_clients. Required when several Boxer tabs are connected.")
    common=Dict{String,Any}("client_id"=>client)
    mutation=merge(common,Dict("request_id"=>boxer_mcp_property("string","Unique caller request ID. Retries return the retained operation instead of repeating its mutation."),
        "expected_revision"=>Dict("type"=>["string","integer"],"description"=>"Optional revision from get_state. The browser rejects edits if the Study changed.")))
    lists=merge(common,Dict("query"=>boxer_mcp_property("string","Case-insensitive text to find labels, context, descriptions or IDs."),
        "offset"=>Dict("type"=>"integer","minimum"=>0),"limit"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>200),
        "force_browser"=>boxer_mcp_property("boolean","Search the complete current browser catalog. Returns an operation to poll if the catalog was truncated.")))
    Any[
        boxer_mcp_tool("list_clients","List connected Boxer browser tabs and their current Study titles. Select the intended client_id before making changes."),
        boxer_mcp_tool("get_state","Read the current browser Study, unsaved changes, analysis progress, selected view and result summary. This is browser state, including edits not yet saved to disk.",common),
        boxer_mcp_tool("list_actions","Discover actions from Boxer's existing menus, forms and dialogs. Disabled controls are reported. Large catalogs return a queued browser search; use get_operation for its result.",lists),
        boxer_mcp_tool("list_inputs","Discover editable inputs, labels, units, bounds and select options from the current interface. Values follow the displayed units. Large catalogs return an operation to poll.",lists),
        boxer_mcp_tool("invoke_action","Invoke an existing Boxer menu/button action by its discovered ID. Existing disabled controls, dialogs and save confirmations still apply. A completed command may mean dispatched or waiting_for_user, not a completed FE solve.",
            merge(mutation,Dict("action_id"=>boxer_mcp_property("string","Exact action ID returned by list_actions."),
                "arguments"=>Dict("type"=>"object","description"=>"Arguments required by the selected action's advertised schema, such as path for open_study/read_nastran, id for inspect_element, or offset/limit for read_reserve_factors. They are passed unchanged to that existing action handler.")));required=["action_id"],read_only=false),
        boxer_mcp_tool("set_input","Set one discovered input in its displayed units, using the same input/change handlers as the menu form. Existing validation and dirty-state behavior apply.",
            merge(mutation,Dict("input_id"=>boxer_mcp_property("string","Exact input ID returned by list_inputs."),"value"=>Dict("description"=>"New value in displayed units. Use boolean for a checkbox or an advertised select-option value.")));required=["input_id","value"],read_only=false),
        boxer_mcp_tool("update_parameters","Update authored Study parameter values through Boxer's parameter setter. Keys and values are validated by the browser. Parameter keys use internal SI units; use set_input for displayed units such as millimetres.",
            merge(mutation,Dict("values"=>Dict("type"=>"object","description"=>"Parameter key/value object using keys from get_state, with internal SI units.")));required=["values"],read_only=false),
        boxer_mcp_tool("navigate","Open an existing Boxer tab or sub-tab by its visible name or advertised target.",
            merge(mutation,Dict("target"=>boxer_mcp_property("string","Tab or sub-tab target.")));required=["target"],read_only=false),
        boxer_mcp_tool("inspect","Inspect an element, node or property using Boxer's inspection behavior and show the corresponding information in the app.",
            merge(mutation,Dict("element_id"=>boxer_mcp_property("integer","Finite element ID."),"node_id"=>boxer_mcp_property("integer","GRID/node ID."),
                "property_id"=>boxer_mcp_property("integer","Property ID.")));read_only=false),
        boxer_mcp_tool("get_parameters","Read values of the Study by parameter key: single values and whole tables (load cases, engines, planform points, airfoil sections, materials), in internal SI units. Give keys to narrow the answer: full keys, or a group such as loads for every key that starts with loads. Returns an operation to poll with get_operation.",
            merge(common,Dict("keys"=>boxer_mcp_property("string","Keys or groups separated by commas, for example: loads, planform.area, output.solution. Empty returns every parameter.")))),
        boxer_mcp_tool("run_analysis","Start the structural analysis (JFEM) of every enabled load case with the stated solution; the Study's Solution is set to it first. Use 101 for load cases, load factors or g cases, stresses, deflections and reserve factors, and for any run after load cases were generated or changed. Use 103 only for normal modes and 105 for buckling. It starts the job: poll get_operation, then get_state for analysis progress.",
            merge(mutation,Dict("solution"=>Dict("type"=>"string","enum"=>["101","103","105","106"],"description"=>"101 static, 103 normal modes, 105 buckling, 106 nonlinear static.")));required=["solution"],read_only=false),
        boxer_mcp_tool("read_view","Read what the current Boxer view shows (a report, summary, table, form or the log) as bounded text and paged tables. Navigate to the view first. Starts no calculation. Returns an operation to poll.",
            merge(common,Dict("offset"=>Dict("type"=>"integer","minimum"=>0),"limit"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>100)))),
        boxer_mcp_tool("read_reserve_factors","Read the reserve factors of the cached Stress Report with their assessment and stale/estimate flags. Never calculates them. Returns an operation to poll.",
            merge(common,Dict("offset"=>Dict("type"=>"integer","minimum"=>0),"limit"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>200),"only_below_one"=>boxer_mcp_property("boolean","List only reserve factors below 1.")))),
        boxer_mcp_tool("find_airfoils","Search the UIUC airfoil coordinate database (read by the Boxer program) by file name; returns the names that match or come nearest. Use it for every section that is not a NACA 4- or 5-digit code. Changes nothing. Returns an operation to poll.",
            merge(common,Dict("query"=>boxer_mcp_property("string","Name or a part of it, for example 64a410, naca642415, sc20714, rae2822, b737."),"limit"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>40)));required=["query"]),
        boxer_mcp_tool("set_airfoil","Set the airfoil of the root, the tip, both, or an intermediate section. Give exactly one of naca, uiuc or coordinates. Never type a designation that is not a NACA 4- or 5-digit code into the airfoil code input. The operation's result gives the measured thickness and camber.",
            merge(mutation,Dict("section"=>boxer_mcp_property("string","root, tip, both, or the eta of an intermediate section between 0 and 1."),
                "naca"=>boxer_mcp_property("string","NACA 4- or 5-digit code, for example 2412."),"uiuc"=>boxer_mcp_property("string","File name from find_airfoils, for example sc20714.dat."),
                "coordinates"=>boxer_mcp_property("string","x z pairs as fractions of the chord, one pair on each line, from the trailing edge over the upper surface to the leading edge and back; at least 12 points on each surface."),
                "name"=>boxer_mcp_property("string","Name of a profile given by coordinates."),
                "thickness"=>Dict("description"=>"Optional thickness in percent of the chord. Scales the section and keeps its camber; the other sections keep their thickness.")));required=["section"],read_only=false),
        boxer_mcp_tool("get_operation","Read the queued/delivered/completed/error state and exact result of a previous command. Menu dispatch is distinct from analysis completion; use get_state for analysis progress.",
            Dict("operation_id"=>boxer_mcp_property("string","Operation ID returned by a mutation or complete-catalog search."));required=["operation_id"]),
        boxer_mcp_tool("cancel_operation","Cancel a command that has not been delivered. A delivered action uses its existing Boxer Cancel control to stop an active calculation.",
            Dict("operation_id"=>boxer_mcp_property("string","Queued operation ID."));required=["operation_id"],read_only=false),
    ]
end

const BOXER_MCP_ACTION_TOOLS=Dict("run_analysis"=>"run_analysis","read_view"=>"read_panel","read_reserve_factors"=>"read_reserve_factors",
    "find_airfoils"=>"find_airfoils","set_airfoil"=>"set_airfoil")

function boxer_mcp_find_tool(name)
    index=findfirst(tool->tool["name"]==name,boxer_mcp_tools())
    index===nothing && throw(BoxerMCPProtocolError(-32602,"Unknown Boxer tool. Use tools/list."))
    boxer_mcp_tools()[index]
end

function boxer_mcp_validate_arguments(tool,args)
    args isa AbstractDict || throw(BoxerMCPProtocolError(-32602,"Tool arguments must be an object."))
    schema=tool["inputSchema"];properties=schema["properties"]
    for key in keys(args)
        haskey(properties,key) || throw(BoxerMCPProtocolError(-32602,"Unknown argument $key for $(tool["name"])."))
    end
    for key in schema["required"]
        haskey(args,key) || throw(BoxerMCPProtocolError(-32602,"Missing argument $key for $(tool["name"])."))
    end
    for (key,value) in args
        type=get(properties[key],"type",nothing)
        types=type isa AbstractVector ? type : [type]
        valid=any(types) do kind
            kind===nothing || kind=="string" && value isa AbstractString || kind=="boolean" && value isa Bool ||
                kind=="integer" && value isa Integer && !(value isa Bool) || kind=="object" && value isa AbstractDict
        end
        valid || throw(BoxerMCPProtocolError(-32602,"Invalid type for $key."))
        minimum=get(properties[key],"minimum",nothing);maximum=get(properties[key],"maximum",nothing)
        minimum===nothing || value>=minimum || throw(BoxerMCPProtocolError(-32602,"$key is below its minimum."))
        maximum===nothing || value<=maximum || throw(BoxerMCPProtocolError(-32602,"$key is above its maximum."))
    end
end

function boxer_mcp_interface_aliases(entry)
    aliases=get(entry,"aliases",Any[])
    aliases isa AbstractVector || (aliases=Any[aliases])
    [lowercase(strip(String(value))) for value in aliases if value isa AbstractString]
end

function boxer_mcp_interface_rank(entry,query)
    id=lowercase(string(get(entry,"id","")))
    label=lowercase(strip(string(get(entry,"label",""))))
    aliases=boxer_mcp_interface_aliases(entry)
    id==query || label==query || query in aliases ? 0 :
        startswith(label,query) || any(alias->startswith(alias,query),aliases) ? 1 :
        occursin(query,label) || any(alias->occursin(query,alias),aliases) ? 2 :
        occursin(query,id) ? 3 : 4
end

function boxer_mcp_list_interface(st,kind,args)
    snapshot=boxer_control_catalog(st;client_id=String(get(args,"client_id","")))
    catalog=snapshot["catalog"]
    if get(catalog,"truncated",false)===true || get(args,"force_browser",false)===true
        return boxer_control_enqueue!(st,"list_"*kind,Dict("query"=>get(args,"query",""),"offset"=>get(args,"offset",0),"limit"=>get(args,"limit",100));
            client_id=snapshot["client"]["client_id"])
    end
    query=lowercase(strip(String(get(args,"query",""))))
    entries=get(catalog,kind,Any[])
    matches=entries
    if !isempty(query)
        terms=split(query)
        matches=filter(entries) do entry
            fields=[lowercase(string(get(entry,key,""))) for key in ("id","label","description","context","parameter_key")]
            append!(fields,boxer_mcp_interface_aliases(entry))
            searchable=join(fields," ")
            all(term->occursin(term,searchable),terms)
        end
        # Rank before taking a page. A tab or parameter's exact name must not
        # disappear behind help controls that mention it only in their context.
        ranked=sort!(collect(enumerate(matches));by=pair->(boxer_mcp_interface_rank(pair[2],query),
            get(pair[2],"curated",false)===true ? 0 : 1,pair[1]))
        matches=[pair[2] for pair in ranked]
    end
    offset=Int(get(args,"offset",0));limit=Int(get(args,"limit",100));stop=min(length(matches),offset+limit)
    items=offset<length(matches) ? matches[offset+1:stop] : Any[]
    Dict("client"=>snapshot["client"],"revision"=>get(catalog,"revision",nothing),"items"=>items,
        "total"=>length(matches),"offset"=>offset,"next_offset"=>stop<length(matches) ? stop : nothing)
end

function boxer_mcp_call_tool(st,name::AbstractString,args=Dict{String,Any}())
    tool=boxer_mcp_find_tool(name);boxer_mcp_validate_arguments(tool,args)
    name=="list_clients" && return Dict("clients"=>boxer_control_clients(st))
    name=="get_state" && return boxer_control_snapshot(st;client_id=String(get(args,"client_id","")))
    name=="list_actions" && return boxer_mcp_list_interface(st,"actions",args)
    name=="list_inputs" && return boxer_mcp_list_interface(st,"inputs",args)
    name=="get_operation" && return boxer_control_operation(st,String(args["operation_id"]))
    name=="cancel_operation" && return boxer_control_cancel!(st,String(args["operation_id"]))
    payload=Dict{String,Any}(String(key)=>value for (key,value) in args if !(key in ("client_id","request_id","expected_revision")))
    # Tools that are actions of the application: the same handlers as the chat panel and the menus use.
    if haskey(BOXER_MCP_ACTION_TOOLS,name)
        return boxer_control_enqueue!(st,"invoke_action",Dict{String,Any}("action_id"=>BOXER_MCP_ACTION_TOOLS[name],"arguments"=>payload);
            client_id=String(get(args,"client_id","")),request_id=String(get(args,"request_id","")),expected_revision=get(args,"expected_revision",nothing))
    end
    name=="inspect" && count(haskey(payload,key) for key in ("element_id","node_id","property_id"))!=1 &&
        throw(BoxerMCPProtocolError(-32602,"Inspect exactly one element_id, node_id or property_id."))
    boxer_control_enqueue!(st,name,payload;client_id=String(get(args,"client_id","")),
        request_id=String(get(args,"request_id","")),expected_revision=get(args,"expected_revision",nothing))
end

function boxer_mcp_content(value;is_error=false)
    Dict{String,Any}("content"=>[Dict("type"=>"text","text"=>JSON.json(value))],"structuredContent"=>value,"isError"=>is_error)
end

function boxer_mcp_resources(st)
    resources=Any[Dict("uri"=>"boxer://clients","name"=>"Connected Boxer Studies","mimeType"=>"application/json")]
    for client in boxer_control_clients(st)
        client["connected"] || continue
        id=client["client_id"]
        title=get(client,"title",client["label"])
        push!(resources,Dict("uri"=>"boxer://client/$id/state","name"=>title*" current state","mimeType"=>"application/json"))
        push!(resources,Dict("uri"=>"boxer://client/$id/interface","name"=>title*" menu and input catalog","mimeType"=>"application/json"))
    end
    resources
end

function boxer_mcp_read_resource(st,uri)
    value=if uri=="boxer://clients"
        Dict("clients"=>boxer_control_clients(st))
    else
        match_uri=match(r"^boxer://client/([A-Za-z0-9_]+)/(?<kind>state|interface)$",uri)
        match_uri===nothing && throw(BoxerMCPProtocolError(-32602,"Unknown Boxer resource."))
        match_uri["kind"]=="state" ? boxer_control_snapshot(st;client_id=match_uri[1]) : boxer_control_catalog(st;client_id=match_uri[1])
    end
    Dict("contents"=>[Dict("uri"=>uri,"mimeType"=>"application/json","text"=>JSON.json(value))])
end

function boxer_mcp_response(id;result=nothing,error=nothing,status=200,session_id="")
    value=Dict{String,Any}("jsonrpc"=>"2.0","id"=>id)
    value[error===nothing ? "result" : "error"]=error===nothing ? result : error
    headers=["Content-Type"=>"application/json; charset=utf-8","Cache-Control"=>"no-store"]
    isempty(session_id) || push!(headers,"Mcp-Session-Id"=>session_id)
    HTTP.Response(status,headers,JSON.json(value))
end

function handle_boxer_mcp(st,req)
    id=nothing
    try
        broker=boxer_control_bearer_guard(st,req)
        method=String(req.method)
        method=="GET" && return HTTP.Response(405,["Allow"=>"POST, DELETE","Cache-Control"=>"no-store"],"")
        session_id=HTTP.header(req,"Mcp-Session-Id","")
        if method=="DELETE"
            return lock(BOXER_CONTROL_LOCK) do
                haskey(broker.sessions,session_id) || return HTTP.Response(404,"")
                delete!(broker.sessions,session_id);HTTP.Response(204,"")
            end
        end
        method=="POST" || return HTTP.Response(405,["Allow"=>"POST, DELETE"],"")
        startswith(lowercase(HTTP.header(req,"Content-Type","")),"application/json") ||
            return boxer_mcp_response(nothing;status=415,error=Dict("code"=>-32600,"message"=>"MCP requests require application/json."))
        length(req.body)<=1024^2 || return boxer_mcp_response(nothing;status=413,error=Dict("code"=>-32600,"message"=>"MCP request exceeds 1 MiB."))
        value=try JSON.parse(String(req.body)) catch; throw(BoxerMCPProtocolError(-32700,"Invalid JSON.")) end
        value isa AbstractDict && get(value,"jsonrpc",nothing)=="2.0" || throw(BoxerMCPProtocolError(-32600,"Expected one JSON-RPC 2.0 object."))
        id=get(value,"id",nothing)
        id===nothing || id isa Union{AbstractString,Integer} && !(id isa Bool) || throw(BoxerMCPProtocolError(-32600,"Invalid JSON-RPC request ID."))
        rpc=get(value,"method",nothing)
        rpc isa AbstractString || throw(BoxerMCPProtocolError(-32600,"JSON-RPC method is required."))
        parameters=get(value,"params",Dict{String,Any}())
        parameters isa AbstractDict || throw(BoxerMCPProtocolError(-32602,"JSON-RPC params must be an object."))
        header_version=HTTP.header(req,"MCP-Protocol-Version","")
        isempty(header_version) || header_version in BOXER_MCP_PROTOCOLS || return boxer_mcp_response(id;status=400,error=Dict("code"=>-32602,"message"=>"Unsupported MCP protocol version."))
        if rpc=="initialize"
            id===nothing && throw(BoxerMCPProtocolError(-32600,"Initialize requires a request ID."))
            requested=get(parameters,"protocolVersion","")
            requested isa AbstractString || throw(BoxerMCPProtocolError(-32602,"protocolVersion must be a string."))
            protocol=requested in BOXER_MCP_PROTOCOLS ? requested : first(BOXER_MCP_PROTOCOLS)
            session_id=lock(BOXER_CONTROL_LOCK) do
                boxer_control_prune!(broker)
                length(broker.sessions)<16 || throw(ArgumentError("Too many native MCP sessions are connected."))
                token=boxer_control_secret()
                broker.sessions[token]=Dict{String,Any}("protocol"=>protocol,"initialized"=>false,"last_seen"=>time(),"request_operations"=>Dict{String,String}())
                token
            end
            return boxer_mcp_response(id;session_id,result=Dict("protocolVersion"=>protocol,
                "serverInfo"=>Dict("name"=>"jfem-boxer","title"=>"JFEM-Boxer","version"=>"1.0.0"),
                "capabilities"=>Dict("tools"=>Dict("listChanged"=>false),"resources"=>Dict("subscribe"=>false,"listChanged"=>false),"prompts"=>Dict("listChanged"=>false)),
                "instructions"=>"Read list_clients and get_state before acting. Discover existing controls with list_actions/list_inputs. Values in set_input use displayed units; update_parameters uses internal SI units. Mutations return an operation ID: poll get_operation. Dispatched menu actions are not completed analyses. Every menu action, view and input is reachable: list_actions also gives the arguments an action takes, get_parameters reads any value or table, read_view reads the report or log that is shown. Start the structural analysis with run_analysis and state the solution: 101 for load cases, load factors, stresses, deflections and reserve factors, and for any run after load cases were generated or changed; 103 only for normal modes; 105 for buckling. Set airfoils with set_airfoil (find_airfoils searches the UIUC database); a designation that is not a NACA 4- or 5-digit code is never typed into the airfoil code input. Preserve existing save confirmations and check current progress with get_state. Never invent control IDs or assume an unsaved Study matches the last disk file."))
        end
        session=lock(BOXER_CONTROL_LOCK) do
            boxer_control_prune!(broker)
            item=get(broker.sessions,session_id,nothing)
            item===nothing && return nothing
            item["last_seen"]=time();item
        end
        session===nothing && return boxer_mcp_response(id;status=isempty(session_id) ? 400 : 404,error=Dict("code"=>-32001,"message"=>"Initialize the Boxer MCP session first."))
        isempty(header_version) || header_version==session["protocol"] || return boxer_mcp_response(id;status=400,error=Dict("code"=>-32602,"message"=>"MCP protocol header differs from the negotiated session."))
        if rpc=="notifications/initialized"
            lock(BOXER_CONTROL_LOCK) do;session["initialized"]=true;end
            return HTTP.Response(202,"")
        elseif rpc=="notifications/cancelled"
            operation_id=lock(BOXER_CONTROL_LOCK) do
                get(session["request_operations"],JSON.json(get(parameters,"requestId",nothing)),"")
            end
            isempty(operation_id) || boxer_control_cancel!(st,operation_id)
            return HTTP.Response(202,"")
        elseif startswith(rpc,"notifications/")
            return HTTP.Response(202,"")
        end
        id===nothing && return HTTP.Response(202,"")
        rpc=="ping" && return boxer_mcp_response(id;result=Dict{String,Any}())
        initialized=lock(BOXER_CONTROL_LOCK) do;session["initialized"]===true;end
        initialized || throw(BoxerMCPProtocolError(-32002,"Send notifications/initialized before using Boxer tools."))
        result=if rpc=="tools/list"
            Dict("tools"=>boxer_mcp_tools())
        elseif rpc=="tools/call"
            name=get(parameters,"name",nothing)
            name isa AbstractString || throw(BoxerMCPProtocolError(-32602,"Tool name is required."))
            arguments=get(parameters,"arguments",Dict{String,Any}())
            try
                if name in ("invoke_action","set_input","update_parameters","navigate","inspect") &&
                        arguments isa AbstractDict && !haskey(arguments,"request_id")
                    arguments=Dict{String,Any}(String(key)=>value for (key,value) in arguments)
                    arguments["request_id"]="rpc_"*bytes2hex(SHA.sha256(session_id*":"*JSON.json(id)))
                end
                outcome=boxer_mcp_call_tool(st,name,arguments)
                if outcome isa AbstractDict && haskey(outcome,"id") && haskey(outcome,"command")
                    lock(BOXER_CONTROL_LOCK) do
                        session["request_operations"][JSON.json(id)]=outcome["id"]
                        length(session["request_operations"])>256 && delete!(session["request_operations"],first(keys(session["request_operations"])))
                    end
                end
                boxer_mcp_content(outcome)
            catch error
                error isa BoxerMCPProtocolError && rethrow()
                boxer_mcp_content(Dict("error"=>sprint(showerror,error));is_error=true)
            end
        elseif rpc=="resources/list"
            Dict("resources"=>boxer_mcp_resources(st))
        elseif rpc=="resources/templates/list"
            Dict("resourceTemplates"=>[
                Dict("uriTemplate"=>"boxer://client/{client_id}/state","name"=>"Current Study state","mimeType"=>"application/json"),
                Dict("uriTemplate"=>"boxer://client/{client_id}/interface","name"=>"Current menu/input catalog","mimeType"=>"application/json")])
        elseif rpc=="resources/read"
            uri=get(parameters,"uri",nothing)
            uri isa AbstractString || throw(BoxerMCPProtocolError(-32602,"Resource URI is required."))
            boxer_mcp_read_resource(st,uri)
        elseif rpc=="prompts/list"
            Dict("prompts"=>[Dict("name"=>"boxer_workflow","description"=>"Operate the current JFEM-Boxer Study using its menu actions and validation.")])
        elseif rpc=="prompts/get"
            get(parameters,"name",nothing)=="boxer_workflow" || throw(BoxerMCPProtocolError(-32602,"Unknown Boxer prompt."))
            Dict("description"=>"JFEM-Boxer interactive engineering workflow","messages"=>[Dict("role"=>"user","content"=>Dict("type"=>"text","text"=>
                "Use JFEM-Boxer to help with the current Study. First list connected clients, select the intended Study and read its state. Discover labels and units before editing. Use existing menu controls, preserve unsaved-change confirmations, poll command results and distinguish dispatched actions from completed analyses. To run load cases use run_analysis with solution 101, never the normal modes that a new Study is set to; use 103 only when modes are asked for. Explain physical assumptions and report numerical values only when returned by the app."))])
        else
            throw(BoxerMCPProtocolError(-32601,"Unknown MCP method."))
        end
        boxer_mcp_response(id;result)
    catch error
        if error isa BoxerControlAuthError
            return boxer_mcp_response(id;status=403,error=Dict("code"=>-32000,"message"=>sprint(showerror,error)))
        end
        code=error isa BoxerMCPProtocolError ? error.code : -32603
        boxer_mcp_response(id;status=code in (-32700,-32600) ? 400 : 200,
            error=Dict("code"=>code,"message"=>sprint(showerror,error)))
    end
end
