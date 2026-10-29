module JFEMSysimageProvenance
using SHA, TOML

const SCHEMA = 4
const SOURCE_DIRS = ("src", "utils/julia_tools", "APPS/PANDEATOR_APP", "APPS/JFEM-Boxer/src")

function fs_path(path::AbstractString)
    p = abspath(path)
    !Sys.iswindows() && return p
    startswith(p, "\\\\?\\") && return p
    return startswith(p, "\\\\") ? "\\\\?\\UNC\\" * p[3:end] : "\\\\?\\" * p
end
digest(path) = open(io -> bytes2hex(sha256(io)), fs_path(path), "r")
sidecar(image) = abspath(image) * ".jfem.toml"
runtime_identity() = Dict("julia_version"=>string(VERSION), "machine"=>Sys.MACHINE,
    "word_size"=>Sys.WORD_SIZE, "cpu_name"=>Sys.CPU_NAME)

function project_file(directory::AbstractString)
    for name in ("JuliaProject.toml", "Project.toml")
        file = joinpath(directory, name)
        isfile(fs_path(file)) && return file
    end
    error("missing project file in $directory")
end

function environment_directory(root::AbstractString, environment)
    configured = environment === nothing ? strip(get(ENV,"JFEM_PACKAGE_ENV","")) : String(environment)
    selected = isempty(configured) ? abspath(root) : abspath(expanduser(configured))
    isfile(fs_path(selected)) && (selected = dirname(selected))
    selected = realpath(selected)
    project_file(selected)
    return selected
end

metadata_name(name) = name in ("Project.toml", "JuliaProject.toml",
    "LocalPreferences.toml", "JuliaLocalPreferences.toml") ||
    occursin(r"^(Julia)?Manifest(-v[0-9]+\.[0-9]+)?\.toml$", name)

# Read freshly rather than using Julia's TOML cache: callers also use this to
# detect inputs edited while a lengthy compilation was in progress.
function preference_stack(selected, root)
    primary = project_file(selected)
    stack = String[primary]
    if isdefined(Base, :get_projects_workspace_to_root)
        stack = Base.get_projects_workspace_to_root(primary)
    end
    selected == realpath(root) || push!(stack, project_file(root))
    return unique(abspath.(stack))
end

function effective_preferences(stack)
    projects = [TOML.parsefile(fs_path(file)) for file in stack]
    packages = Dict{Base.UUID,String}()
    for project in projects
        if haskey(project,"name") && haskey(project,"uuid")
            get!(packages,Base.UUID(project["uuid"]),project["name"])
        end
        for section in ("deps","extras","weakdeps"), (name,uuid) in get(project,section,Dict())
            get!(packages,Base.UUID(uuid),name)
        end
    end
    locals = Dict{String,Any}[]
    inputs = Dict{String,String}()
    for file in stack
        inputs[file] = digest(file)
        values = Dict{String,Any}()
        for name in ("JuliaLocalPreferences.toml","LocalPreferences.toml")
            path = joinpath(dirname(file),name)
            if isfile(fs_path(path))
                inputs[path] = digest(path)
                values = TOML.parsefile(fs_path(path))
                break
            end
        end
        push!(locals,values)
    end
    preferences = Dict{String,Any}()
    identities = Dict{String,String}()
    for (uuid,name) in packages
        merged = Dict{String,Any}()
        for index in reverse(eachindex(stack))
            project = projects[index]
            localname = Base.get_uuid_name(project,uuid)
            localname === nothing && continue
            exported = get(get(project,"preferences",Dict()),localname,Dict{String,Any}())
            localprefs = get(locals[index],localname,Dict{String,Any}())
            merged = Base.recursive_prefs_merge(merged,Dict{String,Any}[exported,localprefs])
        end
        isempty(merged) && continue
        haskey(identities,name) && identities[name] != string(uuid) &&
            error("conflicting package identities for preference name $name")
        preferences[name] = merged
        identities[name] = string(uuid)
    end
    return preferences,identities,inputs
end

"""Identify the intended runtime graph without depending on a temporary build project.

The explicit prepared/repository stack supplies effective per-package preferences.
The builder copies `preferences` into its derived project, declaring any entries
in `preference_packages` that are not already dependencies as extras. Existing
artifact override files are included because they can redirect native libraries.
"""
function environment_identity(root::AbstractString; environment=nothing)
    selected = environment_directory(root,environment)
    metadata = Dict(name=>digest(joinpath(selected,name)) for name in readdir(fs_path(selected))
        if metadata_name(name) && isfile(fs_path(joinpath(selected,name))))
    external = selected != realpath(root)
    # Julia may select a versioned manifest, an explicit manifest path, or a
    # workspace parent's lock file. Fingerprint the graph actually selected.
    manifest = Base.project_file_manifest_path(project_file(selected))
    external && manifest === nothing &&
        error("prepared environment has no recorded manifest: $selected")
    graph = manifest === nothing ? Dict{String,String}() :
        Dict("path"=>abspath(manifest),"sha256"=>digest(manifest))
    preferences,packages,inputs = effective_preferences(preference_stack(selected,root))
    overrides = Dict{String,String}()
    override_order = String[]
    for depot in DEPOT_PATH
        path = abspath(joinpath(depot,"artifacts","Overrides.toml"))
        if isfile(fs_path(path))
            overrides[path] = digest(path)
            push!(override_order,path)
        end
    end
    return Dict{String,Any}("directory"=>selected,"mode"=>external ? "prepared" : "repository",
        "metadata"=>metadata,"manifest"=>graph,"preferences"=>preferences,"preference_packages"=>packages,
        "preference_inputs"=>inputs,"artifact_overrides"=>overrides,"artifact_override_order"=>override_order)
end

"""Capture project code/lock files, including inventory additions and removals.

This checks the repository and dependency lock, not arbitrary edits inside an
installed package depot. It does not attest the operating system or native libraries.
"""
function input_hashes(root::AbstractString;kind="solver")
    base = abspath(root)
    isdir(fs_path(joinpath(base,"src"))) || error("missing source directory")
    paths = String[]
    folders=SOURCE_DIRS
    for folder in folders
        dir = fs_path(joinpath(base,folder))
        isdir(dir) || continue
        for (d, _, names) in walkdir(dir), name in names
            endswith(name,".jl") || continue
            push!(paths,replace(relpath(joinpath(d,name),fs_path(base)), '\\'=>'/'))
        end
    end
    for name in readdir(fs_path(base))
        if name in ("Project.toml","JuliaProject.toml","LocalPreferences.toml","JuliaLocalPreferences.toml") ||
                occursin(r"^(Julia)?Manifest(-v[0-9]+\.[0-9]+)?\.toml$",name)
            isfile(fs_path(joinpath(base,name))) && push!(paths,name)
        end
    end
    # The application package contract and entry point also invalidate old code.
    for folder in ("APPS/JFEM-Boxer",)
        dir=joinpath(base,folder);isdir(dir)||continue
        for name in readdir(fs_path(dir))
            if metadata_name(name) || name == "JFEM-Boxer.jl"
                isfile(fs_path(joinpath(dir,name)))&&push!(paths,folder*"/"*name)
            end
        end
    end
    any(p -> p in ("Project.toml","JuliaProject.toml"),paths) || error("missing project file")
    return Dict(p=>digest(joinpath(base,p)) for p in sort!(unique!(paths)))
end

"""Write only after a successful build from unchanged inputs. No image is built here."""
workload_hashes(decks, flags::AbstractString) = Dict("flags"=>String(flags),
    "decks"=>Dict(abspath(p)=>digest(p) for p in decks))

function write_sidecar(root::AbstractString, image::AbstractString, before::AbstractDict,
        workload_before::AbstractDict;kind="solver",environment=nothing,environment_before=nothing)
    isfile(fs_path(image)) || error("sysimage build did not produce a file")
    now_inputs = input_hashes(root;kind)
    before == now_inputs || error("project inputs changed while building the sysimage")
    workload_now = workload_hashes(keys(workload_before["decks"]),workload_before["flags"])
    workload_before == workload_now || error("requested workload changed while building the sysimage")
    current_environment = environment_identity(root;environment)
    environment_before === nothing || environment_before == current_environment ||
        error("package environment changed while building the sysimage")
    kind in ("solver","boxer","shared")||error("unknown image environment: $kind")
    data = Dict{String,Any}("schema"=>SCHEMA,"root"=>realpath(root),"kind"=>"shared",
        "runtime"=>runtime_identity(),"inputs"=>now_inputs,"package_environment"=>current_environment,
        "image"=>Dict("sha256"=>digest(image),"bytes"=>filesize(fs_path(image))),
        "workload"=>workload_now)
    destination = sidecar(image)
    # A crash while writing cannot create a valid partial TOML receipt.
    tmp = destination * ".tmp"
    open(fs_path(tmp),"w") do io
        TOML.print(io,data;sorted=true)
    end
    mv(fs_path(tmp),fs_path(destination);force=true)
    return destination
end

"""Return eligibility/reason for automatic selection; never load a custom image."""
function check_sysimage(root::AbstractString, image::AbstractString;kind="solver",environment=nothing)
    try
        isfile(fs_path(image)) || return (false,"image_missing")
        isfile(fs_path(sidecar(image))) || return (false,"provenance_missing")
        saved = TOML.parsefile(fs_path(sidecar(image)))
        get(saved,"schema",nothing) == SCHEMA || return (false,"schema_mismatch")
        get(saved,"kind",nothing) == "shared" || return (false,"environment_mismatch")
        get(saved,"root",nothing) == realpath(root) || return (false,"project_moved")
        get(saved,"runtime",nothing) == runtime_identity() || return (false,"runtime_changed")
        get(saved,"inputs",nothing) == input_hashes(root;kind) || return (false,"project_changed")
        get(saved,"package_environment",nothing) == environment_identity(root;environment) ||
            return (false,"package_environment_changed")
        img = saved["image"]
        get(img,"bytes",nothing) == filesize(fs_path(image)) || return (false,"image_changed")
        get(img,"sha256",nothing) == digest(image) || return (false,"image_changed")
        workload = saved["workload"]
        workload["flags"] isa String || return (false,"invalid_provenance")
        for (path,expected) in workload["decks"]
            isfile(fs_path(path)) && digest(path) == expected || return (false,"workload_changed")
        end
        return (true,"current")
    catch
        # Unreadable/malformed metadata is a safe fallback, not an auto-load.
        return (false,"invalid_provenance")
    end
end
end
