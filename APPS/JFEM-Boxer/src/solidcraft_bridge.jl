import Sockets

"""A concise native failure plus its complete MCP diagnostic payload."""
struct SolidCraftToolError <: Exception
    tool::String
    message::String
    details::Any
end

function Base.showerror(io::IO,error::SolidCraftToolError)
    text="SolidCraft $(error.tool) failed. $(error.message)"
    print(io,length(text)>1200 ? first(text,1199)*"…" : text)
end

function solidcraft_tool_error(tool::AbstractString,value)
    summary=value
    prefix=""
    if value isa AbstractDict
        failed=get(value,"failed",nothing)
        if failed isa AbstractDict
            command=String(get(failed,"command",tool))
            index=get(failed,"index",nothing)
            prefix="Command $command"*(index isa Integer ? " at step $(index+1)" : "")*". "
            summary=get(failed,"error",get(failed,"message","The native command was rejected."))
        else
            summary=get(value,"error",get(value,"message","The native command was rejected."))
        end
    end
    summary isa AbstractDict && (summary=get(summary,"message","The MCP server rejected the request."))
    text=prefix*replace(string(summary),r"\s+"=>" ")
    text=length(text)>1000 ? first(text,999)*"…" : text
    return SolidCraftToolError(String(tool),text,value)
end

"""One native MCP connection and the new SolidCraft window created for an export."""
mutable struct SolidCraftBridge
    process::Base.Process
    replies::Channel{Any}
    reader::Union{Nothing,Task}
    log_path::String
    log_io::IO
    temporary_log::Bool
    app_process::Union{Nothing,Base.Process}
    app_path::String
    cli_path::String
    address::String
    server_info::Dict{String,Any}
    timeout::Float64
    cancelled::Function
    request_lock::ReentrantLock
    sequence::Int
    closed::Bool
end

function solidcraft_executable(kind::Symbol, provided::AbstractString="")
    name = kind === :cli ? "solidcraft-cli" : "solidcraft"
    variable = kind === :cli ? "SOLIDCRAFT_CLI" : "SOLIDCRAFT_APP"
    value = strip(isempty(provided) ? get(ENV, variable, "") : String(provided))
    candidates = String[]
    isempty(value) || push!(candidates, value)
    if isempty(value)
        found = Sys.which(name)
        found === nothing || push!(candidates, found)
        if Sys.iswindows()
            for prefix in unique([get(ENV,"ProgramFiles","C:/Program Files"), get(ENV,"ProgramW6432","C:/Program Files")])
                push!(candidates,joinpath(prefix,"SolidCraft",name*".exe"))
                push!(candidates,joinpath(prefix,"ArtCraft","SolidCraft",name*".exe"))
            end
        elseif Sys.isapple()
            push!(candidates,joinpath("/Applications/SolidCraft.app/Contents/MacOS",name))
        else
            append!(candidates,[joinpath("/opt/solidcraft",name),joinpath("/usr/local/bin",name)])
        end
    end
    for path in candidates
        isfile(path) && return abspath(path)
        found = Sys.which(path)
        found === nothing || return found
    end
    label = kind === :cli ? "SolidCraft MCP command-line bridge" : "SolidCraft application"
    throw(ArgumentError("$label was not found. Install SolidCraft and put $name on PATH, or set $variable to its executable path before starting Boxer."))
end

function solidcraft_bridge_detail(bridge::SolidCraftBridge)
    flush(bridge.log_io)
    text = try read(bridge.log_path,String) catch; "" end
    return last(strip(text),2000)
end

function solidcraft_send!(bridge::SolidCraftBridge, message)
    bridge.closed && throw(ArgumentError("The SolidCraft connection is closed."))
    write(bridge.process,JSON.json(message)*"\n")
    flush(bridge.process)
end

solidcraft_timeout_context(bridge::SolidCraftBridge) = isempty(bridge.address) ?
    "The isolated construction session has not responded. No incomplete model has been opened in SolidCraft." :
    "The current CAD operation may still finish in the new SolidCraft window. Inspect that window before exporting again."

function solidcraft_rpc!(bridge::SolidCraftBridge, method::AbstractString, params=Dict{String,Any}();timeout::Real=bridge.timeout)
    lock(bridge.request_lock) do
        bridge.cancelled() && throw(InterruptException())
        bridge.sequence += 1
        id = bridge.sequence
        solidcraft_send!(bridge,Dict("jsonrpc"=>"2.0","id"=>id,"method"=>method,"params"=>params))
        isfinite(timeout) && timeout>0 || throw(ArgumentError("SolidCraft request timeout must be positive."))
        deadline = time()+timeout
        while time()<deadline
            if bridge.cancelled()
                try
                    solidcraft_send!(bridge,Dict("jsonrpc"=>"2.0","method"=>"notifications/cancelled",
                        "params"=>Dict("requestId"=>id,"reason"=>"Boxer export cancelled")))
                catch
                end
                throw(InterruptException())
            end
            if isready(bridge.replies)
                reply = take!(bridge.replies)
                reply isa Exception && throw(ErrorException("SolidCraft MCP stopped reading responses. "*sprint(showerror,reply)))
                get(reply,"id",nothing)==id || continue
                haskey(reply,"error") && throw(solidcraft_tool_error("MCP "*method,reply["error"]))
                return get(reply,"result",Dict{String,Any}())
            end
            if !isopen(bridge.replies) || !process_running(bridge.process)
                throw(ErrorException("SolidCraft MCP connection ended. "*solidcraft_bridge_detail(bridge)))
            end
            sleep(.05)
        end
        throw(ErrorException("SolidCraft MCP timed out while processing $method. "*solidcraft_timeout_context(bridge)*" "*solidcraft_bridge_detail(bridge)))
    end
end

function solidcraft_decode(result)
    haskey(result,"structuredContent") && result["structuredContent"]!==nothing && return result["structuredContent"]
    texts = [String(item["text"]) for item in get(result,"content",Any[]) if get(item,"type","")=="text"]
    if length(texts)==1
        return try JSON.parse(only(texts);dicttype=Dict{String,Any}) catch; only(texts) end
    end
    return join(texts,"\n")
end

function solidcraft_tool!(bridge::SolidCraftBridge,name::AbstractString,args=Dict{String,Any}();timeout::Real=bridge.timeout)
    deadline=time()+timeout
    result = solidcraft_rpc!(bridge,"tools/call",Dict("name"=>name,"arguments"=>args);timeout)
    while true
        value = solidcraft_decode(result)
        message = value isa AbstractString ? value : ""
        waiting = get(result,"isError",false) && occursin("still running:",lowercase(message)) ||
            value isa AbstractDict && get(value,"done",true)===false
        if waiting
            # Poll the existing native operation instead of submitting it twice.
            remaining=deadline-time()
            remaining>0 || throw(ErrorException("SolidCraft $name timed out. "*solidcraft_timeout_context(bridge)))
            result=solidcraft_rpc!(bridge,"tools/call",Dict("name"=>"pending","arguments"=>Dict{String,Any}());timeout=remaining)
            continue
        end
        get(result,"isError",false) && throw(solidcraft_tool_error(name,value))
        value isa AbstractDict && get(value,"ok",true)===false && throw(solidcraft_tool_error(name,value))
        return value
    end
end

"""Open the native CLI protocol. Headless mode is also used by focused bridge tests."""
function solidcraft_mcp_session(cli_path::AbstractString,args::Vector{String};
        timeout::Real=180.,cancelled::Function=()->false,log_path::AbstractString="",
        app_process=nothing,app_path::AbstractString="",address::AbstractString="")
    isfinite(timeout) && timeout>0 || throw(ArgumentError("SolidCraft request timeout must be positive."))
    temporary_log = isempty(log_path)
    path,io = temporary_log ? mktemp() : (abspath(log_path),open(log_path,"w"))
    process = try
        open(pipeline(Cmd(vcat([String(cli_path),"mcp"],args));stderr=io),"r+")
    catch error
        close(io)
        temporary_log && try rm(path;force=true) catch end
        rethrow(error)
    end
    bridge = SolidCraftBridge(process,Channel{Any}(128),nothing,path,io,temporary_log,
        app_process,String(app_path),String(cli_path),String(address),Dict{String,Any}(),Float64(timeout),cancelled,ReentrantLock(),0,false)
    bridge.reader = @async begin
        try
            for line in eachline(process)
                isempty(strip(line)) && continue
                value=JSON.parse(line;dicttype=Dict{String,Any})
                put!(bridge.replies,value)
            end
        catch error
            bridge.closed || put!(bridge.replies,error)
        finally
            close(bridge.replies)
        end
    end
    try
        initialized=solidcraft_rpc!(bridge,"initialize",Dict("protocolVersion"=>"2024-11-05",
            "capabilities"=>Dict{String,Any}(),"clientInfo"=>Dict("name"=>"JFEM-Boxer wing export","version"=>"1.0")))
        server=get(initialized,"serverInfo",Dict{String,Any}())
        occursin("solidcraft",lowercase(String(get(server,"name","")))) || throw(ErrorException("The MCP server does not identify itself as SolidCraft."))
        bridge.server_info=Dict{String,Any}(string(k)=>v for (k,v) in server)
        solidcraft_send!(bridge,Dict("jsonrpc"=>"2.0","method"=>"notifications/initialized"))
        catalog=solidcraft_rpc!(bridge,"tools/list")
        names=Set(String(tool["name"]) for tool in get(catalog,"tools",Any[]))
        required=Set(["new_design","batch","inspect_design","save","execute"])
        missing=setdiff(required,names)
        isempty(missing) || throw(ErrorException("SolidCraft MCP is missing required tools: "*join(sort!(collect(missing)),", ")))
        return bridge
    catch
        close(bridge)
        rethrow()
    end
end

"""Start an isolated native CAD session; headless construction opens no CAD window."""
function solidcraft_start_session(;cli_path::AbstractString="",app_path::AbstractString="",
        timeout::Real=180.,progress::Function=message->nothing,cancelled::Function=()->false,
        allow_path=String[],log_path::AbstractString="",headless::Bool=false)
    isfinite(timeout) && timeout>0 || throw(ArgumentError("SolidCraft request timeout must be positive."))
    cli=solidcraft_executable(:cli,cli_path)
    sibling=joinpath(dirname(cli),Sys.iswindows() ? "solidcraft.exe" : "solidcraft")
    preferred=isempty(app_path) && isempty(get(ENV,"SOLIDCRAFT_APP","")) && isfile(sibling) ? sibling : app_path
    app=solidcraft_executable(:app,preferred)
    cancelled() && throw(InterruptException())
    paths=allow_path isa AbstractString ? [allow_path] : allow_path
    if headless
        progress("Starting isolated SolidCraft construction")
        args=["--headless"]
        for path in paths
            append!(args,["--allow-path",abspath(path)])
        end
        return solidcraft_mcp_session(cli,args;timeout,cancelled,log_path,app_path=app)
    end
    listener=Sockets.listen(Sockets.IPv4("127.0.0.1"),0)
    port=last(Sockets.getsockname(listener))
    close(listener)
    address="127.0.0.1:$port"
    progress("Opening a new SolidCraft window")
    owned=run(pipeline(Cmd([app,"--control",string(port)]);stdout=devnull,stderr=devnull);wait=false)
    deadline=time()+min(Float64(timeout),60.)
    ready=false
    while time()<deadline
        cancelled() && throw(InterruptException())
        if !process_running(owned) && owned.exitcode!=0
            throw(ErrorException("The new SolidCraft application exited before its MCP bridge was available."))
        end
        ready=try
            socket=Sockets.connect("127.0.0.1",port)
            close(socket)
            true
        catch
            false
        end
        ready && break
        sleep(.1)
    end
    ready || throw(ErrorException("The new SolidCraft window did not open its MCP bridge within 60 seconds. Inspect the SolidCraft window and try the export again."))
    progress("Connecting to the SolidCraft MCP bridge")
    args=["--connect",address]
    for path in paths
        append!(args,["--allow-path",abspath(path)])
    end
    return solidcraft_mcp_session(cli,args;timeout,cancelled,log_path,app_process=owned,app_path=app,address)
end

"""Publish a completed native file into a fresh window without replacing an existing design.

The construction session remains isolated. Only after the native file exists do we
open a separate owned GUI, check that it is blank, and load and verify that file.
Closing the auxiliary MCP connection leaves the completed SolidCraft window open.
"""
function solidcraft_show_model!(bridge::SolidCraftBridge,path::AbstractString;
        expected_names=String[],expected_inspection=nothing,
        progress::Function=message->nothing,cancelled::Function=bridge.cancelled,
        timeout::Real=bridge.timeout)
    source=abspath(path)
    verification_path=source
    if Sys.iswindows() && !startswith(source,"\\\\?\\")
        verification_path=startswith(source,"\\\\") ? "\\\\?\\UNC\\"*source[3:end] : "\\\\?\\"*source
    end
    isfile(verification_path) && filesize(verification_path)>0 ||
        throw(ArgumentError("The completed SolidCraft model file does not exist: $source"))
    names=String.(expected_names)
    reference=Dict{String,Any}()
    if expected_inspection isa AbstractDict
        reference=Dict(String(body["name"])=>body for body in get(expected_inspection,"bodies",Any[]))
        isempty(names) && (names=collect(keys(reference)))
    end
    isempty(names) && throw(ArgumentError("Expected body names are required before publishing a SolidCraft model."))
    length(unique(names))==length(names) || throw(ArgumentError("Expected SolidCraft body names must be unique."))
    publication=nothing
    try
        progress("Opening the completed model in a new SolidCraft window")
        publication=solidcraft_start_session(;cli_path=bridge.cli_path,app_path=bridge.app_path,
            timeout,progress,cancelled,allow_path=dirname(source),
            log_path=joinpath(dirname(source),"publication_bridge.log"))
        initial=solidcraft_tool!(publication,"inspect_design",Dict("measure"=>false,"sketches"=>true))
        isempty(get(initial,"bodies",Any[])) && isempty(get(initial,"sketches",Any[])) ||
            throw(ErrorException("The new SolidCraft window restored an existing design; it was left unchanged. The completed export is saved at $source"))
        cancelled() && throw(InterruptException())
        solidcraft_tool!(publication,"execute",Dict("command"=>"doc.open","params"=>Dict("path"=>source)))
        progress("Verifying the completed SolidCraft window")
        inspection=solidcraft_tool!(publication,"inspect_design",Dict("measure"=>true,"sketches"=>false))
        get(inspection,"units","")=="mm" || throw(ErrorException("The reopened SolidCraft model has unexpected units."))
        timeline_errors=String[]
        for feature in get(inspection,"timeline",Any[])
            diagnostic=get(feature,"error",nothing)
            empty=diagnostic===nothing || diagnostic===false ||
                diagnostic isa AbstractString && isempty(strip(diagnostic)) ||
                diagnostic isa Union{AbstractVector,AbstractDict} && isempty(diagnostic)
            empty || push!(timeline_errors,string(get(feature,"name",get(feature,"id","Feature"))))
        end
        isempty(timeline_errors) || throw(ErrorException("The reopened SolidCraft model contains failed features: "*join(first(timeline_errors,5),", ")))
        bodies=get(inspection,"bodies",Any[])
        actual=Dict(String(body["name"])=>body for body in bodies)
        length(actual)==length(bodies)==length(names) && Set(keys(actual))==Set(names) ||
            throw(ErrorException("The reopened SolidCraft model does not contain every expected body. The completed native file is saved at $source"))
        for name in names
            body=actual[name]
            volume=get(body,"volume_mm3",nothing)
            get(body,"closed",false)===true && volume isa Real && isfinite(volume) && volume>0 ||
                throw(ErrorException("The reopened SolidCraft body $name is not a closed positive-volume solid."))
            expected=get(reference,name,nothing)
            expected isa AbstractDict || continue
            expected_volume=get(expected,"volume_mm3",nothing)
            expected_volume isa Real && isapprox(volume,expected_volume;rtol=1.e-6,atol=1.e-6) ||
                throw(ErrorException("The reopened SolidCraft body $name has a different volume from the validated export."))
            for corner in ("min","max")
                bounds=get(get(body,"bbox",Dict{String,Any}()),corner,nothing)
                expected_bounds=get(get(expected,"bbox",Dict{String,Any}()),corner,nothing)
                bounds isa AbstractVector && expected_bounds isa AbstractVector &&
                    length(bounds)==length(expected_bounds)==3 &&
                    all(isapprox(a,b;rtol=1.e-8,atol=1.e-5) for (a,b) in zip(bounds,expected_bounds)) ||
                    throw(ErrorException("The reopened SolidCraft body $name has different bounds from the validated export."))
            end
        end
        return Dict{String,Any}("address"=>publication.address,"path"=>source,
            "bodies"=>length(actual),"server"=>publication.server_info,"inspection"=>inspection)
    finally
        publication===nothing || close(publication)
    end
end

"""Disconnect the export bridge while leaving its SolidCraft window available."""
function Base.close(bridge::SolidCraftBridge)
    bridge.closed && return nothing
    bridge.closed=true
    try closewrite(bridge.process) catch end
    timedwait(()->!process_running(bridge.process),2.;pollint=.05)
    if process_running(bridge.process)
        try kill(bridge.process) catch end
    end
    try close(bridge.process) catch end
    try wait(bridge.process) catch end
    try close(bridge.log_io) catch end
    if bridge.temporary_log
        try rm(bridge.log_path;force=true) catch end
    end
    return nothing
end
