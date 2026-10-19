# A tiny Julia child owns the native modal. The HTTP server remains responsive,
# cancellation is explicit, and no unsigned PowerShell script is executed.
function native_windows_dialog_command(mode;name="",initial="",format="auto")
    executable=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    script=joinpath(@__DIR__,"native_windows_dialog.jl")
    command=`$executable --startup-file=no --history-file=no --compile=min -O0 --project=@stdlib $script $(string(mode)) $name $initial $format`
    Sys.iswindows() ? Cmd(command;windows_hide=true) : command
end
function native_windows_dialog_result(output)
    value=strip(String(output))
    value=="CANCEL"&&return Dict("ok"=>true,"cancelled"=>true)
    startswith(value,"PATH\t")||throw(ErrorException("The native file dialog returned an invalid response"))
    path=value[6:end];isempty(path)&&throw(ErrorException("No file was selected"))
    Dict("ok"=>true,"path"=>path)
end
function native_windows_file_dialog(mode;name="",initial="",format="auto")
    Sys.iswindows()||throw(ArgumentError("This file dialog requires Windows"))
    command=native_windows_dialog_command(mode;name,initial,format)
    mktemp() do _,io
        errors=IOBuffer();process=run(pipeline(command;stdout=io,stderr=errors);wait=false)
        started=time()
        while process_running(process)&&time()-started<300;sleep(.1);end
        if process_running(process)
            kill(process);wait(process)
            throw(ErrorException("File selection timed out after five minutes. Choose the file command again."))
        end
        flush(io);seekstart(io);output=read(io,String);detail=String(take!(errors))
        success(process)||throw(ErrorException(isempty(detail) ? "Windows file selection failed" : detail))
        native_windows_dialog_result(output)
    end
end
