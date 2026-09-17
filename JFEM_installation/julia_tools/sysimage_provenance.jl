module JFEMSysimageProvenance
using SHA, TOML

const SCHEMA = 1
const SOURCE_DIRS = ("src", "JFEM_installation/julia_tools", "POST/PANDEATOR_APP")

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

"""Capture project code/lock files, including inventory additions and removals.

This checks the repository and dependency lock, not arbitrary edits inside an
installed package depot. It does not attest the operating system or native libraries.
"""
function input_hashes(root::AbstractString)
    base = abspath(root)
    isdir(fs_path(joinpath(base,"src"))) || error("missing source directory")
    paths = String[]
    for folder in SOURCE_DIRS
        dir = fs_path(joinpath(base,folder))
        isdir(dir) || continue
        for (d, _, names) in walkdir(dir), name in names
            endswith(name,".jl") || continue
            push!(paths,replace(relpath(joinpath(d,name),fs_path(base)), '\\'=>'/'))
        end
    end
    for name in readdir(fs_path(base))
        if name in ("Project.toml","JuliaProject.toml","LocalPreferences.toml") ||
                occursin(r"^(Julia)?Manifest(-v[0-9]+\.[0-9]+)?\.toml$",name)
            isfile(fs_path(joinpath(base,name))) && push!(paths,name)
        end
    end
    any(p -> p in ("Project.toml","JuliaProject.toml"),paths) || error("missing project file")
    return Dict(p=>digest(joinpath(base,p)) for p in sort!(unique!(paths)))
end

"""Write only after a successful build from unchanged inputs. No image is built here."""
workload_hashes(decks, flags::AbstractString) = Dict("flags"=>String(flags),
    "decks"=>Dict(abspath(p)=>digest(p) for p in decks))

function write_sidecar(root::AbstractString, image::AbstractString, before::AbstractDict,
        workload_before::AbstractDict)
    isfile(fs_path(image)) || error("sysimage build did not produce a file")
    now_inputs = input_hashes(root)
    before == now_inputs || error("project inputs changed while building the sysimage")
    workload_now = workload_hashes(keys(workload_before["decks"]),workload_before["flags"])
    workload_before == workload_now || error("requested workload changed while building the sysimage")
    data = Dict{String,Any}("schema"=>SCHEMA,"root"=>abspath(root),
        "runtime"=>runtime_identity(),"inputs"=>now_inputs,
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
function check_sysimage(root::AbstractString, image::AbstractString)
    try
        isfile(fs_path(image)) || return (false,"image_missing")
        isfile(fs_path(sidecar(image))) || return (false,"provenance_missing")
        saved = TOML.parsefile(fs_path(sidecar(image)))
        get(saved,"schema",nothing) == SCHEMA || return (false,"schema_mismatch")
        get(saved,"root",nothing) == abspath(root) || return (false,"project_moved")
        get(saved,"runtime",nothing) == runtime_identity() || return (false,"runtime_changed")
        get(saved,"inputs",nothing) == input_hashes(root) || return (false,"project_changed")
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
