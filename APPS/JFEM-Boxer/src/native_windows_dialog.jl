# Windows common dialogs called directly from Julia. No PowerShell, execution
# policy changes, downloaded binaries or application packages are needed.
module JFEMWindowsDialog

# Stable OPENFILENAMEW ABI supported by Windows 7 and later (152 bytes on x64).
# New optional SDK tail members are unnecessary for this interface.
struct OpenFileNameW
    size::UInt32
    owner::Ptr{Cvoid}
    instance::Ptr{Cvoid}
    filter::Ptr{UInt16}
    custom_filter::Ptr{UInt16}
    max_custom_filter::UInt32
    filter_index::UInt32
    file::Ptr{UInt16}
    max_file::UInt32
    file_title::Ptr{UInt16}
    max_file_title::UInt32
    initial_directory::Ptr{UInt16}
    title::Ptr{UInt16}
    flags::UInt32
    file_offset::UInt16
    file_extension::UInt16
    default_extension::Ptr{UInt16}
    custom_data::Int
    hook::Ptr{Cvoid}
    template_name::Ptr{UInt16}
    reserved::Ptr{Cvoid}
    reserved_word::UInt32
    extra_flags::UInt32
end

wide(text)=transcode(UInt16,String(text)*"\0")

# The dialog runs in a hidden Julia helper, so it has no browser HWND owner.
# Promote the real Explorer dialog (the hook belongs to its child) once after
# initialization. Only this dialog is topmost, and Windows removes that state
# when it closes; no unrelated browser or application window is changed.
struct NotifyHeader
    window::Ptr{Cvoid}
    id::UInt
    code::UInt32
end
function bring_dialog_forward(child::Ptr{Cvoid})
    parent=ccall((:GetParent,"user32"),Ptr{Cvoid},(Ptr{Cvoid},),child)
    window=parent==C_NULL ? child : parent
    ccall((:SetWindowPos,"user32"),Cint,
        (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Cint,UInt32),
        window,Ptr{Cvoid}(typemax(UInt)),0,0,0,0,UInt32(0x0001|0x0002|0x0040))
    ccall((:SetForegroundWindow,"user32"),Cint,(Ptr{Cvoid},),window)
    nothing
end
function foreground_hook(window::Ptr{Cvoid},message::UInt32,wparam::UInt,lparam::Int)::UInt
    try
        initialized=message==0x0110 # WM_INITDIALOG
        if message==0x004e && lparam!=0 # WM_NOTIFY / CDN_INITDONE
            initialized=unsafe_load(Ptr{NotifyHeader}(lparam)).code==0xfffffda7
        end
        initialized && bring_dialog_forward(window)
    catch
        # Exceptions must never unwind through the native Windows callback.
        # Failure to activate must not prevent normal file selection/cancel.
    end
    return UInt(0)
end

function choices(mode,name,format)
    if mode===:save
        extension=endswith(lowercase(name),".toml") ? "toml" : "json"
        label=extension=="toml" ? "JFEM-Boxer parameters (*.toml)" : "JFEM-Boxer Study (*.wingfem.json;*.json)"
        pattern=extension=="toml" ? "*.toml" : "*.wingfem.json;*.json"
        return (filter=label*"\0"*pattern*"\0All files (*.*)\0*.*\0",extension=extension,
            title="Save JFEM-Boxer file - choose a folder and filename")
    end
    format in ("auto","reference","abaqus")||throw(ArgumentError("Unknown input format"))
    filter=format=="abaqus" ? "Abaqus inputs (*.inp;*.inp.gz)\0*.inp;*.inp.gz\0All files (*.*)\0*.*\0" :
        "Model inputs (*.bdf;*.dat;*.nas;*.inp;*.inp.gz)\0*.bdf;*.dat;*.nas;*.bulk;*.blk;*.inp;*.inp.gz\0All files (*.*)\0*.*\0"
    (filter=filter,extension="",title="Open model deck - INCLUDE files are read automatically")
end
function request(mode::Symbol;name="Study.wingfem.json",initial="",format="auto")
    mode in (:save,:open)||throw(ArgumentError("Choose open or save"))
    !occursin('\0',name)&&!occursin('\0',initial)||throw(ArgumentError("Invalid filename"))
    info=choices(mode,name,format)
    folder=isdir(initial) ? abspath(initial) : isfile(initial) ? dirname(abspath(initial)) : ""
    selected=mode===:open ? (isfile(initial) ? basename(initial) : "") : basename(name)
    text=wide(selected);length(text)<=32768||throw(ArgumentError("Filename is too long"))
    file=zeros(UInt16,32768);copyto!(file,1,text,1,length(text))
    filter=wide(info.filter);directory=wide(folder);title=wide(info.title);extension=wide(info.extension)
    # NOCHANGEDIR, HIDEREADONLY, EXPLORER, ENABLESIZING, PATHMUSTEXIST.
    flags=UInt32(0x00000008|0x00000004|0x00080000|0x00800000|0x00000800|0x00000020)
    # Save selection never creates/truncates a file. App serialization and its
    # atomic write happen only after the user has chosen the destination.
    flags|=mode===:save ? UInt32(0x00000002|0x00010000) : UInt32(0x00001000)
    hook=@cfunction(foreground_hook,UInt,(Ptr{Cvoid},UInt32,UInt,Int))
    ref=Ref(OpenFileNameW(UInt32(sizeof(OpenFileNameW)),C_NULL,C_NULL,pointer(filter),C_NULL,0,1,
        pointer(file),UInt32(length(file)),C_NULL,0,pointer(directory),pointer(title),flags,0,0,
        pointer(extension),0,hook,C_NULL,C_NULL,0,0))
    (record=ref,file=file,filter=filter,directory=directory,title=title,extension=extension)
end
function choose(mode::Symbol;name="Study.wingfem.json",initial="",format="auto",invoke=nothing,extended_error=nothing)
    Sys.iswindows()||invoke!==nothing||throw(ArgumentError("Windows dialog requested on another platform"))
    buffers=request(mode;name,initial,format)
    record,file,filter,directory,title,extension=buffers
    answer=GC.@preserve record file filter directory title extension begin
        if invoke!==nothing
            invoke(mode,record)
        elseif mode===:save
            ccall((:GetSaveFileNameW,"comdlg32"),Cint,(Ref{OpenFileNameW},),record)
        else
            ccall((:GetOpenFileNameW,"comdlg32"),Cint,(Ref{OpenFileNameW},),record)
        end
    end
    if answer==0
        code=extended_error===nothing ? ccall((:CommDlgExtendedError,"comdlg32"),UInt32,()) : UInt32(extended_error())
        code==0&&return nothing
        throw(ErrorException("Windows file dialog failed (code $(string(code;base=16))). Use the browser download alternative if this computer blocks native dialogs."))
    end
    stop=findfirst(iszero,file);stop===nothing&&throw(ErrorException("Windows returned an unterminated filename"))
    path=transcode(String,file[1:stop-1]);isempty(path)&&throw(ErrorException("Windows returned an empty filename"))
    path
end
function main(args)
    length(args)==4||throw(ArgumentError("Expected mode, name, initial path and format"))
    mode=Symbol(args[1]);path=choose(mode;name=args[2],initial=args[3],format=args[4])
    println(path===nothing ? "CANCEL" : "PATH\t"*path)
end
end

if abspath(PROGRAM_FILE)==abspath(@__FILE__)
    try
        JFEMWindowsDialog.main(ARGS)
    catch err
        showerror(stderr,err);println(stderr);exit(1)
    end
end
