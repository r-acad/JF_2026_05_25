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

"""Check the shared environment before app imports. Run root setup first.
Legacy opt-in JFEM_AUTO_INSTALL=1 installs missing sources only; explicit setup
also repairs artifacts and builds the shared image."""
function ensure_environment(project;io=stderr)
    project=abspath(project)
    isfile(joinpath(project,"Project.toml")) || error("Project.toml missing from $project")
    check_runtime(project)
    Pkg.activate(project;io=devnull)
    missing=try missing_sources() catch; ["uninstalled project environment"] end
    isempty(missing) && return false
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
