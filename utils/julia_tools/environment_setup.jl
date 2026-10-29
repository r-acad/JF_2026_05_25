module JFEMEnvironmentSetup
using Pkg,TOML

function recorded_version(project)
    path=joinpath(project,"Manifest.toml")
    isfile(path) || return nothing
    value=get(TOML.parsefile(path),"julia_version",nothing)
    value===nothing ? nothing : VersionNumber(value)
end

function check_runtime(project;version=VERSION)
    recorded=recorded_version(project)
    recorded===nothing && return nothing
    (version.major,version.minor)==(recorded.major,recorded.minor) && return nothing
    channel="$(recorded.major).$(recorded.minor)"
    error("This checkout records Julia $recorded dependencies; the running Julia is $version. "*
        "Install the latest patch in that release line with `juliaup add $channel`, then run "*
        "`julia +$channel --startup-file=no \"utils/julia_tools/install_julia_packages.jl\"`. "*
        "Alternatively select an installed matching executable with JFEM_JULIA/WINGFEGEN_JULIA. "*
        "The manifests were not changed.")
end

function missing_sources(dependencies=Pkg.dependencies())
    missing=String[]
    for info in values(dependencies)
        source=info.source
        (source isa AbstractString && isdir(source)) || push!(missing,info.name)
    end
    sort!(missing)
end

"""Choose package metadata separately from solver source when explicitly set.

JFEM_PACKAGE_ENV is an already prepared Project/Manifest directory. It never
triggers installation and must not be confused with the package depot.
"""
function package_environment(project)
    root=abspath(project)
    configured=strip(get(ENV,"JFEM_PACKAGE_ENV",""))
    isempty(configured)&&return (root,false)
    selected=abspath(expanduser(configured))
    isfile(selected)&&(selected=dirname(selected))
    isfile(joinpath(selected,"Project.toml"))||error("JFEM_PACKAGE_ENV must contain an existing Project.toml: $selected")
    isfile(joinpath(selected,"Manifest.toml"))||error("JFEM_PACKAGE_ENV must contain its prepared Manifest.toml: $selected")
    return (selected,true)
end

"""Check dependencies before app imports, without changing prepared metadata.
Legacy opt-in JFEM_AUTO_INSTALL=1 installs missing sources only; explicit setup
also repairs artifacts and builds the shared image. An explicit JFEM_PACKAGE_ENV
uses its recorded versions and existing depot exclusively, even if automatic
installation was enabled elsewhere."""
function ensure_environment(project;io=stderr)
    project=abspath(project)
    isfile(joinpath(project,"Project.toml")) || error("Project.toml missing from $project")
    selected,prepared=package_environment(project)
    check_runtime(selected)
    Pkg.activate(selected;io=devnull)
    if prepared
        # The prepared graph supplies cached dependency versions. The source
        # checkout remains on the stack for OpenJFEM and bundled local apps.
        # Pkg.activate alone would not make the source package discoverable.
        empty!(LOAD_PATH)
        append!(LOAD_PATH,unique([selected,project,"@stdlib"]))
        ENV["JULIA_LOAD_PATH"]=join(LOAD_PATH,Sys.iswindows() ? ';' : ':')
    end
    missing=try missing_sources() catch; ["uninstalled project environment"] end
    if isempty(missing)
        prepared&&println(io,"JFEM: using existing package environment ",selected)
        return false
    end
    if prepared
        error("The prepared environment at $selected requests package source trees absent from the active depots: "*
            join(missing,", ")*". Depots: "*join(DEPOT_PATH,", ")*
            ". Use its matching hydrated depot/Manifest; nothing was installed, resolved or updated.")
    end
    if lowercase(get(ENV,"JFEM_AUTO_INSTALL","0")) in ("0","false","no","off")
        error("Missing Julia packages: $(join(missing,", ")). Run setup.cmd (Windows), bash setup.sh (Linux), or "*
            "bash setup.command (macOS) at the repository root first.")
    end
    println(io,"Installing missing Julia dependencies for ",project," (first launch; network access may be needed).")
    flush(io)
    try
        Pkg.instantiate(;allow_autoprecomp=false,io)
    catch failure
        error("Automatic package installation failed: $(sprint(showerror,failure)). "*
            "Check network/proxy access and folder permissions, then rerun setup.cmd, setup.sh or setup.command at the repository root. "*
            "Offline setup requires an already populated matching Julia depot.")
    end
    return true
end
end
