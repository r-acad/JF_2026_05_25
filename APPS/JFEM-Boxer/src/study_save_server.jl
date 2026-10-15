# Native file access is restricted to paths selected in this server's OS dialog.
# Browser clients receive an opaque capability; no write endpoint accepts a path.
const STUDY_SAVE_DESTINATIONS = WeakKeyDict{Any,Dict{String,String}}()
const STUDY_SAVE_LOCK = ReentrantLock()

function study_save_request(req)
    startswith(lowercase(HTTP.header(req,"Content-Type","")),"application/json") ||
        throw(ArgumentError("Study file operations require JSON requests."))
    origin=HTTP.header(req,"Origin","")
    if !isempty(origin)
        uri=HTTP.URI(origin)
        authority=String(uri.host)*(isempty(uri.port) ? "" : ":"*String(uri.port))
        authority==HTTP.header(req,"Host","") || throw(ArgumentError("Study file operations require the app's own origin."))
    end
    JSON.parse(String(req.body))
end

function register_study_destination!(st,path)
    isabspath(path)&&isdir(dirname(path))&&!isdir(path) || throw(ArgumentError("Choose a file in an existing folder."))
    token=bytes2hex(SHA.sha256(tempname()*string(time_ns())*path))
    lock(STUDY_SAVE_LOCK) do
        paths=get!(STUDY_SAVE_DESTINATIONS,st,Dict{String,String}())
        paths[token]=abspath(path)
    end
    Dict("kind"=>"native-save","token"=>token,"name"=>basename(path),"path"=>abspath(path))
end

function study_destination(st,raw)
    token=String(get(raw,"token",""))
    path=lock(STUDY_SAVE_LOCK) do
        get(get(STUDY_SAVE_DESTINATIONS,st,Dict{String,String}()),token,"")
    end
    isempty(path)&&throw(ArgumentError("The selected file link expired or belongs to another app session. Use Save Study as to select the file again."))
    path
end

function native_study_dialog(name,initial)
    command=nothing
    if Sys.iswindows()
        script=joinpath(@__DIR__,"study_save_file.ps1")
        command=Cmd(`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $script -SuggestedName $name -InitialDirectory $initial`;windows_hide=true)
    elseif Sys.isapple()
        # argv is data, never interpolated into AppleScript source.
        script="on run argv\nreturn POSIX path of (choose file name with prompt \"Save JFEM-Boxer Study\" default name (item 1 of argv))\nend run"
        command=`osascript -e $script $name`
    elseif Sys.which("zenity")!==nothing
        command=`zenity --file-selection --save --confirm-overwrite --title=Save\ JFEM-Boxer\ Study --filename=$(joinpath(initial,name))`
    elseif Sys.which("kdialog")!==nothing
        command=`kdialog --getsavefilename $(joinpath(initial,name)) --title Save\ JFEM-Boxer\ Study`
    else
        return Dict("ok"=>true,"available"=>false,"reason"=>"No system Save dialog is installed (zenity or kdialog).")
    end
    mktemp() do _,io
        errors=IOBuffer();process=run(pipeline(command;stdout=io,stderr=errors);wait=false)
        started=time()
        while process_running(process)&&time()-started<300;sleep(.1);end
        if process_running(process)
            kill(process);wait(process)
            throw(ArgumentError("Save dialog timed out after five minutes. Choose Save Study again."))
        end
        flush(io);seekstart(io);output=strip(read(io,String));detail=String(take!(errors))
        if Sys.iswindows()
            success(process)||throw(ErrorException(isempty(detail) ? "System Save dialog failed." : detail))
            return JSON.parse(output)
        end
        if !success(process)
            (process.exitcode==1||Sys.isapple()&&occursin("-128",detail))&&return Dict("ok"=>true,"cancelled"=>true)
            throw(ErrorException("System Save dialog failed: "*detail))
        end
        isempty(output) ? Dict("ok"=>true,"cancelled"=>true) : Dict("ok"=>true,"path"=>output)
    end
end

function handle_study_pick(st,req;pick=native_study_dialog)
    try
        raw=study_save_request(req);name=String(get(raw,"name","Study.wingfem.json"))
        length(name)<=255&&!occursin(r"[\\/\x00]",name)&&!isempty(name)||throw(ArgumentError("Invalid suggested filename."))
        result=pick(name,dirname(st.input_path))
        get(result,"ok",false)||throw(ArgumentError(String(get(result,"error","Save dialog failed."))))
        (get(result,"cancelled",false)||get(result,"available",true)==false)&&return json_response(result)
        handle=register_study_destination!(st,String(result["path"]))
        json_response(Dict("ok"=>true,"handle"=>handle))
    catch err
        error_response("Save file dialog: "*describe_error(err))
    end
end

function handle_study_file(st,req;read_only=false)
    try
        raw=study_save_request(req);path=study_destination(st,raw)
        if read_only
            text=SensitivityFileIO.read_text(path)
            return json_response(Dict("ok"=>true,"name"=>basename(path),"text"=>text,"lastModified"=>round(Int,mtime(path)*1000)))
        end
        text=get(raw,"text",nothing);text isa AbstractString||throw(ArgumentError("Saved file content must be text."))
        ncodeunits(text)<=384*1024^2||throw(ArgumentError("Saved file exceeds the 384 MiB limit."))
        SensitivityFileIO.write_text(path,text) # strict atomic replacement, bounded Windows sharing retries
        json_response(Dict("ok"=>true,"name"=>basename(path),"path"=>path))
    catch err
        error_response("Study file: "*describe_error(err))
    end
end
