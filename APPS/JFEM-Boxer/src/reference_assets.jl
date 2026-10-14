# Reference geometry is browser-viewer metadata, never an FE model parameter.
const REFERENCE_METADATA_KEY = "references.items"
const REFERENCE_EXTENSIONS = (".stl", ".obj", ".glb")

function normalize_references(items)
    items isa AbstractVector || throw(ArgumentError("references.items must be an array"))
    result = Dict{String,Any}[]
    ids = Set{String}()
    allowed = Set(("version", "id", "asset_path", "source_name", "units", "axis", "position_m",
        "rotation_deg", "scale", "visible", "opacity", "wireframe", "locked"))
    for (i, raw) in enumerate(items)
        raw isa AbstractDict || throw(ArgumentError("reference $i must be a table"))
        row = Dict{String,Any}(String(k) => v for (k,v) in raw)
        isempty(setdiff(keys(row), allowed)) || throw(ArgumentError("reference $i has unknown metadata fields"))
        get(row, "version", 0) == 1 || throw(ArgumentError("reference $i has an unsupported metadata version"))
        id = String(get(row, "id", ""))
        isempty(id) || any(iscntrl, id) ? throw(ArgumentError("reference $i needs a valid id")) : nothing
        id in ids && throw(ArgumentError("duplicate saved reference id: $id"))
        push!(ids, id)
        asset = replace(String(get(row, "asset_path", "")), '\\' => '/')
        pieces = split(asset, '/'; keepempty=true)
        length(pieces) == 2 && endswith(pieces[1], ".reference_assets") &&
            !any(p -> isempty(p) || p in (".", "..") || occursin(':', p), pieces) &&
            occursin(r"^[a-f0-9]{64}\.(stl|obj|glb)$", pieces[2]) ||
            throw(ArgumentError("reference $i has an invalid portable asset path"))
        row["asset_path"] = asset
        name = String(get(row, "source_name", ""))
        !isempty(name) && !any(iscntrl, name) && !(occursin('/', name) || occursin('\\', name)) ||
            throw(ArgumentError("reference $i needs a source filename without directories"))
        lowercase(splitext(name)[2]) in REFERENCE_EXTENSIONS || throw(ArgumentError("unsupported reference format"))
        String(get(row, "units", "")) in ("m", "mm", "cm", "inch") || throw(ArgumentError("invalid reference units"))
        String(get(row, "axis", "")) in ("fe", "yup") || throw(ArgumentError("invalid reference source axes"))
        for key in ("position_m", "rotation_deg", "scale")
            values = get(row, key, nothing)
            values isa AbstractVector && length(values) == 3 && all(v -> v isa Real && isfinite(v), values) ||
                throw(ArgumentError("reference $i $key needs three finite numbers"))
            key == "scale" && !all(>(0), values) && throw(ArgumentError("reference scales must be positive"))
            row[key] = Float64.(values)
        end
        for key in ("visible", "wireframe")
            get(row, key, nothing) isa Bool || throw(ArgumentError("reference $i $key must be Boolean"))
        end
        get(row, "locked", false) isa Bool || throw(ArgumentError("reference $i locked must be Boolean"))
        row["locked"] = get(row, "locked", false)
        opacity = get(row, "opacity", nothing)
        opacity isa Real && isfinite(opacity) && 0 <= opacity <= 1 || throw(ArgumentError("invalid reference opacity"))
        row["opacity"] = Float64(opacity)
        push!(result, row)
    end
    return result
end

reference_asset_dir(st) = joinpath(dirname(st.input_path), splitext(basename(st.input_path))[1] * ".reference_assets")

function reference_asset_path(st, asset::AbstractString; must_exist::Bool=true)
    dir = reference_asset_dir(st)
    parts = split(replace(asset, '\\' => '/'), '/'; keepempty=true)
    length(parts) == 2 && parts[1] == basename(dir) && occursin(r"^[a-f0-9]{64}\.(stl|obj|glb)$", parts[2]) ||
        throw(ArgumentError("reference asset must be inside this input's reference_assets directory"))
    # A junction/symlink must not turn this endpoint into a generic file reader.
    if ispath(dir)
        dirname(realpath(dir)) == realpath(dirname(st.input_path)) && basename(realpath(dir)) == basename(dir) ||
            throw(ArgumentError("reference asset directory cannot redirect outside the input folder"))
    end
    full = joinpath(dir, parts[2])
    if ispath(full)
        dirname(realpath(full)) == realpath(dir) && basename(realpath(full)) == parts[2] ||
            throw(ArgumentError("reference asset cannot redirect to another file"))
    end
    must_exist && !isfile(full) && throw(ArgumentError("saved reference file is missing: $asset"))
    return full
end

function handle_upload_reference(st, req)
    try
        query = HTTP.queryparams(HTTP.URI(req.target))
        name = last(split(replace(get(query, "name", ""), '\\' => '/'), '/'))
        isempty(name) && throw(ArgumentError("a reference source filename is required"))
        extension = lowercase(splitext(name)[2])
        extension in REFERENCE_EXTENSIONS || throw(ArgumentError("only STL, OBJ and GLB references can be saved"))
        any(iscntrl, name) && throw(ArgumentError("invalid reference filename"))
        bytes = Vector{UInt8}(req.body)
        isempty(bytes) && throw(ArgumentError("the reference file is empty"))
        filename = bytes2hex(SHA.sha256(bytes)) * extension
        relative = basename(reference_asset_dir(st)) * "/" * filename
        full = reference_asset_path(st, relative; must_exist=false)
        mkpath(dirname(full))
        # Identical imports share immutable copies. Existing assets are retained.
        if !isfile(full)
            write(full, bytes)
        elseif read(full) != bytes
            throw(ArgumentError("saved reference content does not match its asset hash"))
        end
        return json_response(Dict("ok"=>true, "asset_path"=>relative,
            "absolute_path"=>abspath(full), "source_name"=>name, "bytes"=>length(bytes)))
    catch e
        return error_response(describe_error(e))
    end
end

function handle_reference_asset(st, req)
    try
        query = HTTP.queryparams(HTTP.URI(req.target))
        full = reference_asset_path(st, get(query, "asset", ""))
        return HTTP.Response(200, ["Content-Type"=>"application/octet-stream", "Cache-Control"=>"no-store"], read(full))
    catch e
        return error_response(describe_error(e); status=404)
    end
end

function handle_save_references(st, req)
    try
        raw = JSON.parse(String(req.body))
        raw isa AbstractDict || throw(ArgumentError("expected reference metadata"))
        items = normalize_references(get(raw, "items", nothing))
        for item in items
            reference_asset_path(st, item["asset_path"]; must_exist=false)
        end
        # Only metadata is changed: unsaved/invalid FE form edits are untouched.
        disk = TOML.parsefile(st.input_path)
        section = get!(disk, "references", Dict{String,Any}())
        section["items"] = items
        io = IOBuffer(); TOML.print(io, disk); contents = String(take!(io))
        write(st.input_path, contents)
        st.params[REFERENCE_METADATA_KEY] = deepcopy(items)
        return json_response(Dict("ok"=>true, "path"=>st.input_path, "items"=>items))
    catch e
        return error_response(describe_error(e))
    end
end
