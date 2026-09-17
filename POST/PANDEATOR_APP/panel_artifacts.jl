# Pure artifact/path helpers shared by the panel service and its focused tests.

function _panel_default_run_root(app_dir)
    workspace = normpath(joinpath(app_dir, "..", "..", "..", ".."))
    private_root = joinpath(workspace, "02_PROJECT_DEVELOPMENT", "02.3_PRIVATE_VALIDATION")
    if isdir(private_root)
        stamp = Dates.now()
        return joinpath(private_root, "RUN_OUTPUTS", "SOL105", "$(Dates.year(stamp))Q$(cld(Dates.month(stamp),3))", "PANDEATOR")
    end
    return joinpath(homedir(), ".openjfem", "panel_runs")
end

function _panel_case_id(value)
    id = string(value)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", id) && id != "." && id != ".." ||
        throw(ArgumentError("case_id must contain 1-128 letters, digits, underscores, hyphens or dots and start with a letter or digit"))
    return id
end

function _panel_contained_path(root, name)
    root_abs = normpath(abspath(root))
    path = normpath(abspath(joinpath(root_abs, String(name))))
    rel = relpath(path, root_abs)
    (first(splitpath(rel)) == ".." || isabspath(rel)) &&
        throw(ArgumentError("Path escapes the artifact directory"))
    # Resolve existing files through symlinks/junctions before reading them.
    if ispath(path)
        resolved = realpath(path)
        realroot = realpath(root_abs)
        realrel = relpath(resolved, realroot)
        (first(splitpath(realrel)) == ".." || isabspath(realrel)) &&
            throw(ArgumentError("Path resolves outside the artifact directory"))
    end
    return path
end

function _eigenvalues_from_jfem(buf::Vector{UInt8})
    length(buf) >= 32 && buf[1:4] == UInt8['J','F','E','M'] || return Float64[]
    u32(pos) = UInt32(buf[pos]) | UInt32(buf[pos+1])<<8 | UInt32(buf[pos+2])<<16 | UInt32(buf[pos+3])<<24
    version = Int(u32(5))
    version in 1:5 || return Float64[]
    count = Int(u32(29))
    # The static trailer length follows directly from the shared fixed counts,
    # independently of the legacy/corrected v5 solid-header interpretation.
    trailer = version == 5 ? 4 + 24*Int(u32(9)) + 12*(Int(u32(13))+Int(u32(17))) : 0
    marker = length(buf) - trailer - 8*count - 7
    marker >= 33 && marker+7 <= length(buf) || return Float64[]
    buf[marker:marker+3] == UInt8['E','V','A','L'] && Int(u32(marker+4)) == count || return Float64[]
    if version == 5
        stat = length(buf)-trailer+1
        buf[stat:stat+3] == UInt8['S','T','A','T'] || return Float64[]
    end
    out = Vector{Float64}(undef,count)
    for i in 1:count
        pos = marker+8+8*(i-1)
        bits = zero(UInt64)
        for d in 0:7; bits |= UInt64(buf[pos+d]) << (8d); end
        out[i] = reinterpret(Float64,bits)
        isfinite(out[i]) || return Float64[]
    end
    return out
end

function _panel_binary_artifacts(out_dir, stem)
    manifest = _panel_contained_path(out_dir, stem * ".BUCKLING_FILES.JSON")
    entries = isfile(manifest) ? get(JSON.parsefile(manifest), "subcases", Any[]) : Any[]
    artifacts = Dict{String,Any}[]
    if isempty(entries)
        path = _panel_contained_path(out_dir, stem * ".jfem")
        isfile(path) && push!(artifacts, Dict("file"=>basename(path), "path"=>path, "bytes"=>read(path)))
    else
        for entry in entries
            path = _panel_contained_path(out_dir, entry["file"])
            isfile(path) || error("Missing binary result $(entry["file"])")
            push!(artifacts, Dict("file"=>basename(path), "path"=>path, "bytes"=>read(path),
                "buckling_subcase_id"=>entry["buckling_subcase_id"], "static_subcase_id"=>entry["static_subcase_id"]))
        end
    end
    for artifact in artifacts
        artifact["eigenvalues"] = _eigenvalues_from_jfem(artifact["bytes"])
    end
    return artifacts
end
