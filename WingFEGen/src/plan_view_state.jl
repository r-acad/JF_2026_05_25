# Presentation-only metadata, excluded from FE geometry and mesh signatures.
const PLAN_VIEW_METADATA_KEY = "view.plan_view"
const DRAWINGS_METADATA_KEY = "view.drawings"
const PLAN_VIEW_IMAGE_BYTES = 8 * 1024 * 1024

function normalize_plan_view(value)
    value isa AbstractString || throw(ArgumentError("view.plan_view must be a JSON string"))
    isempty(strip(value)) && return ""
    sizeof(value) <= 12 * 1024 * 1024 || throw(ArgumentError("Plan-view metadata exceeds 12 MiB"))
    data = try JSON.parse(value) catch; throw(ArgumentError("Invalid plan-view JSON metadata")) end
    data isa AbstractDict || throw(ArgumentError("Plan-view metadata must be an object"))
    allowed = Set(["version", "theme", "mirror", "showSpars", "showRibs", "showRibLabels", "opacity", "image", "transform", "viewport", "grid", "snap", "measurements"])
    all(k -> k in allowed, keys(data)) || throw(ArgumentError("Unknown plan-view setting"))
    version = get(data, "version", 1)
    version isa Real && !(version isa Bool) && version == 1 || throw(ArgumentError("Unsupported plan-view version"))
    out = Dict{String,Any}("version" => 1)
    theme = get(data, "theme", "dark")
    theme in ("dark", "white") || throw(ArgumentError("Plan-view theme must be dark or white"))
    out["theme"] = theme
    for key in ("mirror", "showSpars", "showRibs", "showRibLabels")
        v = get(data, key, key != "mirror")
        v isa Bool || throw(ArgumentError("Plan-view $key must be true or false"))
        out[key] = v
    end
    finite_number(v) = v isa Real && !(v isa Bool) && isfinite(v)
    snap = get(data, "snap", Dict{String,Any}())
    snap isa AbstractDict && all(k -> k in ("enabled", "points", "lines"), keys(snap)) || throw(ArgumentError("Invalid plan-view snapping settings"))
    out["snap"] = Dict{String,Bool}()
    for key in ("enabled", "points", "lines")
        value = get(snap, key, key != "enabled")
        value isa Bool || throw(ArgumentError("Plan-view snap $key must be true or false"))
        out["snap"][key] = value
    end
    grid = get(data, "grid", Dict{String,Any}())
    grid isa AbstractDict && all(k -> k in ("enabled", "spacing", "color"), keys(grid)) || throw(ArgumentError("Invalid plan-view grid"))
    enabled, spacing, color = get(grid, "enabled", false), get(grid, "spacing", 1.0), get(grid, "color", "#526579")
    enabled isa Bool || throw(ArgumentError("Plan-view grid visibility must be true or false"))
    finite_number(spacing) && 1e-9 <= spacing <= 1e9 || throw(ArgumentError("Plan-view grid spacing must be between 1e-9 and 1e9 metres"))
    color isa AbstractString && occursin(r"^#[0-9a-fA-F]{6}$", color) || throw(ArgumentError("Plan-view grid color must be a six-digit hex color"))
    out["grid"] = Dict("enabled" => enabled, "spacing" => Float64(spacing), "color" => lowercase(color))
    measurements = get(data, "measurements", Any[])
    measurements isa AbstractVector && length(measurements) <= 500 || throw(ArgumentError("Plan view supports up to 500 dimensions"))
    dimensions = Any[]
    for measurement in measurements
        measurement isa AbstractDict && all(k -> k in ("type", "points", "label"), keys(measurement)) && all(k -> haskey(measurement, k), ("type", "points")) || throw(ArgumentError("Invalid plan-view dimension"))
        type, points = measurement["type"], measurement["points"]
        type in ("distance", "horizontal", "vertical", "angle") || throw(ArgumentError("Unknown plan-view dimension type"))
        points isa AbstractVector && length(points) == (type == "angle" ? 3 : 2) || throw(ArgumentError("Plan-view distances need two points; angles need endpoint, vertex, endpoint"))
        normalized = Any[]
        for point in points
            point isa AbstractDict && Set(keys(point)) == Set(["x", "y"]) && all(k -> finite_number(point[k]) && abs(point[k]) <= 1e9, ("x", "y")) || throw(ArgumentError("Invalid plan-view dimension point"))
            push!(normalized, Dict("x" => Float64(point["x"]), "y" => Float64(point["y"])))
        end
        if type == "angle"
            all(i -> hypot(normalized[i]["x"] - normalized[2]["x"], normalized[i]["y"] - normalized[2]["y"]) > 1e-12, (1, 3)) || throw(ArgumentError("Plan-view angle endpoints must differ from the vertex"))
        end
        dimension = Dict{String,Any}("type" => type, "points" => normalized)
        if haskey(measurement, "label")
            label = measurement["label"]
            label isa AbstractDict && Set(keys(label)) == Set(["x", "y"]) && all(k -> finite_number(label[k]) && abs(label[k]) <= 1e9, ("x", "y")) || throw(ArgumentError("Invalid plan-view dimension label position"))
            dimension["label"] = Dict("x" => Float64(label["x"]), "y" => Float64(label["y"]))
        end
        push!(dimensions, dimension)
    end
    out["measurements"] = dimensions
    opacity = get(data, "opacity", 0.55)
    finite_number(opacity) && 0 <= opacity <= 1 || throw(ArgumentError("Plan-view opacity must be between 0 and 1"))
    out["opacity"] = Float64(opacity)
    for transform_key in ("transform", "viewport")
        transform = get(data, transform_key, Dict{String,Any}())
        transform isa AbstractDict && all(k -> k in ("x", "y", "scale"), keys(transform)) || throw(ArgumentError("Invalid plan-view $transform_key"))
        t = Dict{String,Float64}()
        for (key, default) in (("x", 0.0), ("y", 0.0), ("scale", 1.0))
            v = get(transform, key, default)
            finite_number(v) && (key == "scale" ? 1e-6 <= v <= 1e4 : abs(v) <= 1e7) || throw(ArgumentError("Invalid plan-view $transform_key $key"))
            t[key] = Float64(v)
        end
        out[transform_key] = t
    end
    image = get(data, "image", nothing)
    if image !== nothing
        image isa AbstractDict && Set(keys(image)) == Set(["name", "dataUrl", "width", "height"]) || throw(ArgumentError("Invalid plan-view background image"))
        name = image["name"]
        name isa AbstractString && length(name) <= 512 || throw(ArgumentError("Invalid plan-view image name"))
        for key in ("width", "height")
            v = image[key]
            finite_number(v) && isinteger(v) && 1 <= v <= 32768 || throw(ArgumentError("Invalid plan-view image $key"))
        end
        image["width"] * image["height"] <= 134217728 || throw(ArgumentError("Plan-view image resolution is too large"))
        url = image["dataUrl"]
        url isa AbstractString || throw(ArgumentError("Plan-view image must be embedded PNG, JPEG or WebP"))
        parts = split(url, ','; limit=2)
        length(parts) == 2 && parts[1] in ("data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64") || throw(ArgumentError("Plan-view image must be embedded PNG, JPEG or WebP"))
        encoded = parts[2]
        !isempty(encoded) && length(encoded) % 4 == 0 && occursin(r"^[A-Za-z0-9+/]+={0,2}$", encoded) || throw(ArgumentError("Invalid plan-view image encoding"))
        bytes = 3 * (length(encoded) ÷ 4) - (endswith(encoded, "==") ? 2 : endswith(encoded, "=") ? 1 : 0)
        0 < bytes <= PLAN_VIEW_IMAGE_BYTES || throw(ArgumentError("Plan-view image exceeds 8 MiB"))
        out["image"] = Dict("name" => name, "dataUrl" => url, "width" => Int(image["width"]), "height" => Int(image["height"]))
    else
        out["image"] = nothing
    end
    return JSON.json(out)
end

"""Presentation-only states for the inline definition drawings; excluded from FE inputs."""
function normalize_drawings(value)
    value isa AbstractString || throw(ArgumentError("view.drawings must be a JSON string"))
    isempty(strip(value)) && return ""
    sizeof(value) <= 96 * 1024 * 1024 || throw(ArgumentError("Drawing metadata exceeds 96 MiB"))
    data = try JSON.parse(value) catch; throw(ArgumentError("Invalid drawing JSON metadata")) end
    data isa AbstractDict || throw(ArgumentError("Drawing metadata must be an object"))
    names = Set(["planform", "spars", "master-ribs", "leading-edge-ribs", "fuel-tank", "stringer-section",
        "spar-cap-section", "rib-stiffener-section", "rib-override-section", "airfoil-root", "airfoil-tip",
        ("material-" * name for name in ("upper_skin", "lower_skin", "spar_web", "rib_web", "leading_edge_skin", "leading_edge_rib"))...])
    fields = Set(["version", "theme", "opacity", "image", "transform", "viewport", "grid", "snap", "measurements"])
    out = Dict{String,Any}()
    for (name, state) in data
        name in names || occursin(r"^airfoil-station-([1-9]|[1-9][0-9]|100)$", name) || throw(ArgumentError("Unknown drawing metadata key: $name"))
        state isa AbstractDict && all(key -> key in fields, keys(state)) || throw(ArgumentError("Invalid $name drawing state"))
        canonical = try JSON.parse(normalize_plan_view(JSON.json(state))) catch error
            error isa ArgumentError || rethrow()
            throw(ArgumentError("Invalid $name drawing metadata: $(error.msg)"))
        end
        out[name] = Dict(key => canonical[key] for key in fields)
    end
    return JSON.json(out)
end
