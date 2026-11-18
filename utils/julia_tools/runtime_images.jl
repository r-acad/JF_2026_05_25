"""Image selection shared by application launchers and isolated workers.

Every process starts with a bare executable and checks the shared repository
image receipt. Never inherit unchecked image flags from Base.julia_cmd().
"""
module JFEMRuntimeImages
include("compilation_defaults.jl")
include("sysimage_provenance.jl")
bare_julia()=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
image_path(repo,kind="solver")=joinpath(repo,"sysimage","OpenJFEM_sysimage."*(Sys.iswindows() ? "dll" : Sys.isapple() ? "dylib" : "so"))
_start_image_probe(command)=run(pipeline(ignorestatus(command);stdout=devnull,stderr=devnull);wait=false)

# Start with Julia's standard image so Windows error handling is configured
# before the candidate DLL reaches the native loader. A -J candidate would be
# loaded before an entry script could suppress its Windows error dialog.
const IMAGE_LIBRARY_PROBE_SCRIPT = raw"""
using Libdl
if Sys.iswindows()
    required_flags = UInt32(0x0001 | 0x0002 | 0x8000)
    previous_mode = ccall((:GetErrorMode, "kernel32"), UInt32, ())
    ccall((:SetErrorMode, "kernel32"), UInt32, (UInt32,), previous_mode | required_flags)
    current_mode = ccall((:GetErrorMode, "kernel32"), UInt32, ())
    current_mode & required_flags == required_flags || exit(2)
end
function probe_image(path)
    handle = Libdl.dlopen_e(path)
    (handle === nothing || handle == C_NULL) && return false
    try
        data = Libdl.dlsym_e(handle, :jl_system_image_data)
        size = Libdl.dlsym_e(handle, :jl_system_image_size)
        return data != C_NULL && size != C_NULL
    finally
        Libdl.dlclose(handle)
    end
end
exit(probe_image(only(ARGS)) ? 0 : 1)
"""
function image_loadable(path;executable=bare_julia(),environment=nothing,project=nothing,timeout=15.,runner=_start_image_probe)
    # Reject obvious invalid payloads without invoking a platform loader that
    # may display a native error dialog for a corrupt library.
    header=try open(io->read(io,4),path) catch; UInt8[] end
    valid_header=Sys.iswindows() ? length(header)>=2&&header[1:2]==UInt8[0x4d,0x5a] :
        Sys.isapple() ? header in (UInt8[0xcf,0xfa,0xed,0xfe],UInt8[0xfe,0xed,0xfa,0xcf],UInt8[0xca,0xfe,0xba,0xbe],UInt8[0xbe,0xba,0xfe,0xca]) :
        header==UInt8[0x7f,0x45,0x4c,0x46]
    valid_header||return false
    project_args=project===nothing ? String[] : ["--project="*String(project)]
    command=`$executable --startup-file=no --history-file=no --threads=1 $project_args -e $IMAGE_LIBRARY_PROBE_SCRIPT $path`
    environment===nothing || (command=addenv(command,"JFEM_PACKAGE_ENV"=>String(environment)))
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    process=nothing
    try
        process=runner(command)
        timedwait(()->process_exited(process),timeout;pollint=.05)==:ok||return false
        success(process)
    catch
        false
    finally
        if process!==nothing&&process_running(process)
            # This is only the probe we just created, never an app/solver job.
            try kill(process) catch;end
            try wait(process) catch;end
        end
    end
end
function selected_image(repo;kind="solver",executable=bare_julia(),external=false,environment=nothing,probe=false)
    kind in ("solver","boxer","shared")||error("Unknown image environment: $kind")
    lowercase(strip(get(ENV,"JFEM_NO_SYSIMAGE",""))) in ("1","true","yes","on")&&return (nothing,"disabled")
    path=image_path(repo,kind)
    isfile(path)||return (nothing,"image_missing")
    if external
        checker=joinpath(repo,"utils","julia_tools","check_sysimage.jl")
        command=`$executable --startup-file=no --history-file=no --threads=1 $checker $repo $path $kind`
        environment===nothing || (command=addenv(command,"JFEM_PACKAGE_ENV"=>String(environment)))
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        valid=try success(pipeline(command;stdout=devnull,stderr=devnull)) catch; false end
        valid || return (nothing,"receipt_not_current_for_worker")
        project=probe ? JFEMSysimageProvenance.environment_directory(repo,environment) : nothing
        return probe&&!image_loadable(path;executable,environment,project) ? (nothing,"image_load_failed") : (path,"current")
    end
    valid,reason=JFEMSysimageProvenance.check_sysimage(repo,path;kind,environment)
    valid || return (nothing,reason)
    project=probe ? JFEMSysimageProvenance.environment_directory(repo,environment) : nothing
    probe&&!image_loadable(path;executable,environment,project) ? (nothing,"image_load_failed") : (path,reason)
end
image_arguments(image)=image===nothing ? String[] : ["--sysimage="*image]
function loading_message(reason;name="JFEM")
    detail=reason in ("image_missing","disabled") ? "" : " (local image skipped: $reason)"
    "$name: running with normal Julia package loading$detail. A custom sysimage is optional; first use may compile and cache packages."
end
end
