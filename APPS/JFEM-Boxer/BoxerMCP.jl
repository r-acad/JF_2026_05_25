#!/usr/bin/env julia
# MCP stdio transport for the running Boxer application. Stdout is JSON-RPC only.
module BoxerMCP
import HTTP, JSON

function settings(args)
    result=Dict{String,Any}("discovery"=>get(ENV,"BOXER_MCP_DISCOVERY",joinpath(@__DIR__,"output",".wingfegen","boxer_mcp.json")),
        "url"=>get(ENV,"BOXER_MCP_URL",""),"token_env"=>"BOXER_MCP_TOKEN",
        "timeout"=>get(ENV,"BOXER_MCP_TIMEOUT_SECONDS","300"))
    index=1
    while index<=length(args)
        key=args[index]
        if key in ("--help","-h")
            println(stderr,"JFEM-Boxer MCP stdio bridge. Start Boxer and keep its browser open. Options: --discovery FILE, --url http://127.0.0.1:PORT/api/mcp, --token-env NAME, --timeout SECONDS (default 300, or BOXER_MCP_TIMEOUT_SECONDS). Uses the repository's shared Julia project.")
            return nothing
        end
        key in ("--discovery","--url","--token-env","--timeout") || error("Unknown bridge option $key")
        index+=1;index<=length(args) || error("$key requires a value")
        result[replace(key[3:end],'-'=>'_')]=args[index]
        index+=1
    end
    timeout=tryparse(Float64,String(result["timeout"]))
    timeout!==nothing && isfinite(timeout) && timeout>0 || error("The MCP timeout must be a finite positive number of seconds.")
    result["timeout"]=timeout
    result
end

function connection(options)
    config=if isempty(options["url"])
        path=abspath(expanduser(options["discovery"]))
        isfile(path) || error("Start JFEM-Boxer first. Its connection file is unavailable. Use the configuration copied from Chat settings for another server.")
        try
            JSON.parsefile(path)
        catch
            error("The Boxer connection file could not be read. Restart Boxer and copy its current MCP configuration.")
        end
    else
        Dict("url"=>options["url"],"token"=>get(ENV,options["token_env"],""))
    end
    config isa AbstractDict || error("The Boxer connection file must contain a connection object.")
    url=get(config,"url","");token=get(config,"token","")
    url isa AbstractString && token isa AbstractString || error("The Boxer connection file has invalid URL or token fields.")
    url,token=String(url),String(token)
    uri=try HTTP.URI(url) catch; error("The Boxer connection URL is invalid. Restart Boxer and copy its current MCP configuration.") end
    String(uri.scheme)=="http" && lowercase(String(uri.host)) in ("127.0.0.1","localhost","::1","[::1]") &&
        isempty(uri.userinfo) && isempty(uri.query) && isempty(uri.fragment) && String(uri.path)=="/api/mcp" ||
        error("The MCP bridge only connects to Boxer's local /api/mcp endpoint.")
    isempty(token) && error("The Boxer connection has no authentication token. Restart Boxer or set the selected token environment variable.")
    (url,token)
end

function request_boxer(endpoint,headers,request,timeout,emit)
    parameters=get(request,"params",nothing)
    metadata=parameters isa AbstractDict ? get(parameters,"_meta",nothing) : nothing
    token=metadata isa AbstractDict ? get(metadata,"progressToken",nothing) : nothing
    reports_progress=token isa AbstractString || token isa Real && !(token isa Bool) && isfinite(token)
    started=time_ns()
    waiting=@async try
        (response=HTTP.post(endpoint,headers,JSON.json(request);status_exception=false,redirect=false,retry=false,
            connect_timeout=min(5.,timeout),request_timeout=timeout,read_idle_timeout=timeout),failed=false)
    catch
        # Native HTTP exceptions may contain request headers. Never echo them.
        (response=nothing,failed=true)
    end
    next_report=2.0
    while !istaskdone(waiting)
        elapsed=(time_ns()-started)/1.e9
        if reports_progress && elapsed>=next_report
            emit(Dict("jsonrpc"=>"2.0","method"=>"notifications/progress","params"=>Dict(
                "progressToken"=>token,"progress"=>round(elapsed;digits=1),
                "message"=>"Waiting for Boxer. The command has not been repeated.")))
            next_report=elapsed+2.0
        end
        sleep(.05)
    end
    outcome=fetch(waiting)
    outcome.failed && error("Boxer did not confirm a response within the configured $(timeout)-second wait, or its connection ended. It may still be working. The command was not retried; check the current app state before retrying.")
    outcome.response
end

function main(args=ARGS;input=stdin,output=stdout)
    options=settings(args);options===nothing && return 0
    session="";protocol="2025-11-25";previous_connection=nothing
    output_lock=ReentrantLock()
    emit=value->lock(output_lock) do
        println(output,JSON.json(value));flush(output)
    end
    for line in eachline(input)
        isempty(strip(line)) && continue
        request=nothing
        try
            ncodeunits(line)<=4_000_000 || error("MCP message is too large")
            request=try JSON.parse(line;dicttype=Dict{String,Any}) catch; error("Invalid JSON-RPC JSON.") end
            request isa AbstractDict && get(request,"jsonrpc","")=="2.0" || error("Expected a JSON-RPC 2.0 object")
            endpoint=connection(options)
            if previous_connection!==nothing && endpoint!=previous_connection
                session=""
            end
            previous_connection=endpoint
            headers=["Content-Type"=>"application/json","Accept"=>"application/json, text/event-stream",
                "Authorization"=>"Bearer "*endpoint[2],"MCP-Protocol-Version"=>protocol]
            isempty(session) || push!(headers,"Mcp-Session-Id"=>session)
            response=request_boxer(endpoint[1],headers,request,options["timeout"],emit)
            new_session=HTTP.header(response,"Mcp-Session-Id","")
            isempty(new_session) || (session=new_session)
            if isempty(response.body)
                response.status in (202,204) || error("Boxer returned an empty HTTP $(response.status) response")
                continue
            end
            result=try
                JSON.parse(String(response.body);dicttype=Dict{String,Any})
            catch
                error("Boxer returned an unreadable MCP response (HTTP $(response.status)). The command was not retried; check the current app state before retrying.")
            end
            if get(request,"method","")=="initialize" && haskey(result,"result")
                protocol=String(get(result["result"],"protocolVersion",protocol))
            end
            if haskey(request,"id")
                emit(result)
            end
        catch error
            if request isa AbstractDict && !haskey(request,"id")
                println(stderr,"Boxer MCP notification failed. ",sprint(showerror,error))
            else
                id=request isa AbstractDict ? get(request,"id",nothing) : nothing
                code=request===nothing ? -32700 : -32000
                emit(Dict("jsonrpc"=>"2.0","id"=>id,"error"=>Dict("code"=>code,"message"=>sprint(showerror,error))))
            end
        end
    end
    0
end
end

if abspath(PROGRAM_FILE)==@__FILE__
    exit(BoxerMCP.main())
end
