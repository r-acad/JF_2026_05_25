"""Image selection shared by application launchers and isolated workers.

Every process starts with a bare executable and checks the shared repository
image receipt. Never inherit unchecked image flags from Base.julia_cmd().
"""
module JFEMRuntimeImages
include("sysimage_provenance.jl")
bare_julia()=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
image_path(repo,kind="solver")=joinpath(repo,"sysimage","OpenJFEM_sysimage."*(Sys.iswindows() ? "dll" : Sys.isapple() ? "dylib" : "so"))
function selected_image(repo;kind="solver",executable=bare_julia(),external=false)
    kind in ("solver","boxer","shared")||error("Unknown image environment: $kind")
    get(ENV,"JFEM_NO_SYSIMAGE","")=="1"&&return (nothing,"disabled")
    path=image_path(repo,kind)
    isfile(path)||return (nothing,"image_missing")
    if external
        checker=joinpath(repo,"utils","julia_tools","check_sysimage.jl")
        command=`$executable --startup-file=no --history-file=no --threads=1 $checker $repo $path $kind`
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        valid=try success(pipeline(command;stdout=devnull,stderr=devnull)) catch; false end
        return valid ? (path,"current") : (nothing,"receipt_not_current_for_worker")
    end
    valid,reason=JFEMSysimageProvenance.check_sysimage(repo,path;kind)
    valid ? (path,reason) : (nothing,reason)
end
image_arguments(image)=image===nothing ? String[] : ["--sysimage="*image]
end
