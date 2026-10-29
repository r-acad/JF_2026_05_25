"""Derive a build-only environment from existing locked packages; never resolve or install."""
module JFEMPreparedSysimageEnvironment
using Pkg, TOML, Artifacts

function _project_file(directory)
    path=Pkg.Types.projectfile_path(abspath(directory);strict=true)
    path===nothing && error("Prepared sysimage requires an existing Project.toml: $directory")
    return path
end

_uuid(value)=string(Base.UUID(String(value)))
function _write_toml(path,data)
    open(path,"w") do io; TOML.print(io,data;sorted=true); end
end

function _single_entries(manifest)
    startswith(string(get(manifest,"manifest_format","")),"2.") ||
        error("Prepared sysimage requires a format-2 Julia manifest; no metadata was changed.")
    entries=Dict{String,Any}()
    uuids=Dict{String,String}()
    for (name,records) in get(manifest,"deps",Dict())
        records isa Vector && length(records)==1 ||
            error("Ambiguous manifest package name $name; the prepared build requires one UUID per name.")
        record=deepcopy(only(records)); uuid=_uuid(record["uuid"])
        haskey(uuids,uuid) && error("Manifest UUID $uuid has multiple names: $(uuids[uuid]) and $name")
        uuids[uuid]=name; entries[name]=record
    end
    return entries
end

function _package_record(project,path=nothing)
    record=Dict{String,Any}("uuid"=>_uuid(project["uuid"]))
    for key in ("version","deps","weakdeps","extensions")
        haskey(project,key) && (record[key]=deepcopy(project[key]))
    end
    path===nothing || (record["path"]=abspath(path))
    return record
end

function _require_entry!(entries,name,uuid)
    expected=_uuid(uuid)
    if haskey(entries,name)
        _uuid(entries[name]["uuid"])==expected || error("Dependency UUID mismatch for $name; prepared metadata does not match the source project.")
        return
    end
    id=Base.UUID(expected)
    stdlibs=Pkg.Types.stdlibs()
    haskey(stdlibs,id) || error("Prepared manifest lacks $name ($expected). Supply its matching cached environment; no packages were installed or resolved.")
    stdlibs[id][1]==name || error("Standard-library name/UUID mismatch for $name")
    project=TOML.parsefile(_project_file(joinpath(Sys.STDLIB,name)))
    entries[name]=_package_record(project)
    for (dependency,dep_uuid) in get(project,"deps",Dict())
        _require_entry!(entries,dependency,dep_uuid)
    end
end

function _check_closure(entries)
    for (name,record) in entries
        deps=get(record,"deps",String[])
        if deps isa AbstractDict
            for (dependency,uuid) in deps
                haskey(entries,dependency) || error("Manifest dependency $name -> $dependency is missing")
                _uuid(entries[dependency]["uuid"])==_uuid(uuid) || error("Manifest dependency UUID mismatch: $name -> $dependency")
            end
        elseif deps isa AbstractVector
            for dependency in deps
                haskey(entries,dependency) || error("Manifest dependency $name -> $dependency is missing")
            end
        else
            error("Invalid manifest dependency list for $name")
        end
    end
end

function _check_compat(project,entries,label)
    deps=get(project,"deps",Dict())
    for (name,compat) in get(project,"compat",Dict())
        version=if name=="julia"
            VERSION
        elseif haskey(deps,name) && haskey(entries,name)
            value=get(entries[name],"version",nothing)
            value===nothing && continue
            VersionNumber(value)
        else
            continue
        end
        version in Pkg.Types.semver_spec(String(compat)) ||
            error("$label requires $name $compat, but the prepared environment supplies $version. No versions were changed; use compatible cached metadata.")
    end
end

"""Write an isolated Project/Manifest with locked packages and local application paths.

Both original environments are read only. `preferences` and `preference_packages`
are the effective name=>values and name=>UUID dictionaries from image provenance.
"""
function prepare_environment(root,prepared,destination;preferences=Dict(),preference_packages=Dict(),
        local_packages=[root,joinpath(root,"APPS","JFEM-Boxer")])
    root=realpath(root); prepared=isfile(prepared) ? dirname(abspath(prepared)) : realpath(prepared)
    destination=abspath(destination)
    if isdir(destination)
        realpath(destination) in (root,realpath(prepared)) && error("Build metadata must not overwrite either original environment")
        isempty(readdir(destination)) || error("Build environment destination must be empty: $destination")
    end
    source_project=_project_file(prepared)
    original=TOML.parsefile(source_project)
    # EnvCache applies Julia's version-specific manifest selection and explicit
    # project manifest overrides. Never guess that Manifest.toml was selected.
    source_env=Pkg.Types.EnvCache(source_project)
    isfile(source_env.manifest_file) || error("The prepared environment has no existing manifest")
    manifest=TOML.parsefile(source_env.manifest_file)
    recorded=VersionNumber(get(manifest,"julia_version",string(VERSION)))
    (recorded.major,recorded.minor)==(VERSION.major,VERSION.minor) ||
        error("Prepared packages record Julia $recorded; build using its Julia release line. Running Julia: $VERSION")
    entries=_single_entries(manifest)
    for record in values(entries)
        if haskey(record,"path")
            record["path"]=abspath(dirname(source_env.manifest_file),expanduser(record["path"]))
        end
        if haskey(record,"repo-url")
            url=String(record["repo-url"])
            if !occursin(r"^[A-Za-z][A-Za-z0-9+.-]*://|^[^/@]+@[^:]+:",url)
                record["repo-url"]=abspath(dirname(source_env.manifest_file),expanduser(url))
            end
        end
    end
    deps=Dict{String,String}(name=>_uuid(uuid) for (name,uuid) in get(original,"deps",Dict()))
    sources=Dict{String,Any}()
    locals=Tuple{String,Any}[]
    for path in local_packages
        path=realpath(path); project=TOML.parsefile(_project_file(path))
        name=String(project["name"]);uuid=_uuid(project["uuid"])
        haskey(entries,name) && _uuid(entries[name]["uuid"])!=uuid && error("Prepared environment has an incompatible UUID for local package $name")
        for (other,record) in entries
            other!=name && _uuid(record["uuid"])==uuid && error("Local package $name has the same UUID as prepared package $other")
        end
        entries[name]=_package_record(project,path);deps[name]=uuid;sources[name]=Dict("path"=>path)
        push!(locals,(path,project))
    end
    # Dependencies of the injected source packages must already be recorded,
    # except for bundled standard libraries which come with this Julia runtime.
    for (_,project) in locals, (name,uuid) in get(project,"deps",Dict())
        _require_entry!(entries,name,uuid)
        expected=_uuid(uuid)
        haskey(deps,name) && deps[name]!=expected &&
            error("Prepared project has an incompatible UUID for dependency $name")
        # PackageCompiler requires each explicitly included package in the
        # build Project, even when it is already a transitive/stdlib dependency.
        # Expose local application dependencies (notably Pkg) using their same
        # recorded UUIDs. This changes only the derived project's visibility.
        deps[name]=expected
    end
    for (name,uuid) in deps; _require_entry!(entries,name,uuid); end
    for (name,uuid) in preference_packages
        _require_entry!(entries,String(name),uuid)
        deps[String(name)]=_uuid(uuid)
    end
    _check_closure(entries)
    _check_compat(original,entries,"Prepared project")
    for (path,project) in locals; _check_compat(project,entries,"Local package $(project["name"])"); end
    project=Dict{String,Any}("deps"=>deps,"sources"=>sources)
    haskey(original,"compat") && (project["compat"]=deepcopy(original["compat"]))
    manifest["deps"]=Dict(name=>[record] for (name,record) in entries)
    manifest["julia_version"]=string(VERSION)
    pop!(manifest,"project_hash",nothing)
    mkpath(destination)
    project_file=joinpath(destination,"Project.toml")
    manifest_file=joinpath(destination,"Manifest.toml")
    _write_toml(project_file,project);_write_toml(manifest_file,manifest)
    isempty(preferences) || _write_toml(joinpath(destination,"LocalPreferences.toml"),preferences)
    # Refresh the derived hash only. This computes metadata; it does not resolve.
    derived=Pkg.Types.EnvCache(project_file)
    manifest["project_hash"]=Pkg.Types.workspace_resolve_hash(derived)
    _write_toml(manifest_file,manifest)
    return destination
end

"""Check every cached package and host artifact before PackageCompiler can run.

Selects the build environment for the caller and children. This function never
installs, resolves, builds packages, downloads artifacts or updates registries.
"""
function cache_preflight(builddir;io=stdout)
    builddir=abspath(builddir)
    ENV["JULIA_PKG_OFFLINE"]="true";ENV["JULIA_PKG_SERVER"]=""
    ENV["JULIA_PKG_PRECOMPILE_AUTO"]="0";ENV["JFEM_AUTO_INSTALL"]="0"
    Pkg.offline(true)
    Pkg.activate(builddir;io=devnull)
    empty!(LOAD_PATH);append!(LOAD_PATH,[builddir,"@stdlib"])
    ENV["JULIA_LOAD_PATH"]=join(LOAD_PATH,Sys.iswindows() ? ';' : ':')
    dependencies=Pkg.dependencies()
    roots=Tuple{String,Union{Nothing,Base.UUID},String}[(builddir,nothing,"build project")]
    missing=String[]
    for (uuid,info) in dependencies
        source=info.source
        if !(source isa AbstractString && isdir(source))
            push!(missing,"package $(info.name): $(something(source,"no source tree recorded"))")
        else
            push!(roots,(String(source),uuid,info.name))
        end
    end
    isempty(missing) || error("Prepared sysimage cache is incomplete:\n  "*join(sort!(missing),"\n  ")*"\nNo image build, package installation or resolution was started.")
    Artifacts.load_overrides(;force=true)
    artifacts=Set{String}()
    platform=Base.BinaryPlatforms.HostPlatform()
    for (path,uuid,label) in roots
        metadata=Dict{String,Any}()
        artifact_file=nothing
        for filename in ("JuliaArtifacts.toml","Artifacts.toml")
            candidate=joinpath(path,filename)
            if isfile(candidate)
                artifact_file=candidate
                metadata=Artifacts.load_artifacts_toml(candidate;pkg_uuid=uuid)
                break
            end
        end
        artifact_file===nothing && continue
        selected=try
            Pkg.Operations.collect_artifacts(path;platform,include_lazy=true)
        catch failure
            error("Cannot inspect cached artifacts for $label: $(sprint(showerror,failure)). No image build was started.")
        end
        chosen=Dict{String,Any}()
        for (_,records) in selected;merge!(chosen,records);end
        # Pkg's downloadable-artifact selector excludes local-only artifacts.
        for name in keys(metadata)
            meta=Artifacts.artifact_meta(name,metadata,artifact_file;platform)
            meta===nothing || haskey(meta,"download") || (chosen[name]=meta)
        end
        for (name,meta) in chosen
            hash=String(meta["git-tree-sha1"]);push!(artifacts,hash)
            Artifacts.artifact_exists(Base.SHA1(hash)) || push!(missing,"artifact $label/$name ($hash): $(Artifacts.artifact_path(Base.SHA1(hash)))")
        end
    end
    isempty(missing) || error("Prepared sysimage cache is incomplete:\n  "*join(sort!(missing),"\n  ")*"\nCopy the matching cached artifacts before retrying; no download or image build was started.")
    ctx=Pkg.Types.Context(env=Pkg.Types.EnvCache(joinpath(builddir,"Project.toml")))
    Pkg.Operations.is_instantiated(ctx.env;platform) ||
        error("Prepared build environment is not fully cached; refusing to invoke PackageCompiler.")
    println(io,"Offline cache check: ",length(dependencies)," packages and ",length(artifacts)," selected host artifacts available.")
    return Dict("packages"=>length(dependencies),"artifacts"=>length(artifacts),"project"=>ctx.env.project_file,"manifest"=>ctx.env.manifest_file)
end
end
