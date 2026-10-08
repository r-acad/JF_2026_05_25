# Independent load definitions share one structural geometry and property set.
const LOAD_CASE_FIELDS = Dict(
    "method" => "loads.method", "lift_total" => "loads.lift_total",
    "load_factor" => "loads.load_factor", "distribution" => "loads.distribution",
    "torque_y" => "loads.torque_y", "speed" => "aero.speed",
    "density" => "aero.density", "alpha" => "aero.alpha",
    "follower_forces" => "loads.follower_forces",
    "fuel_percent" => "loads.fuel_percent",
    "structure_inertia" => "loads.structure_inertia",
    "fuel_accel_x" => "loads.fuel_accel_x", "fuel_accel_y" => "loads.fuel_accel_y",
    "fuel_accel_z" => "loads.fuel_accel_z",
)
const CASE_LOAD_CACHE_LOCK = ReentrantLock()
const CASE_LOAD_CACHE = Ref{Any}(nothing) # latest model only, bounded by case count

"""Read explicit extra cases, preserving omitted values as inherited inputs."""
function normalize_load_cases(value)
    value isa AbstractVector || throw(ArgumentError("loads.cases must be an array of load-case tables"))
    length(value) <= 64 || throw(ArgumentError("loads.cases supports at most 64 additional cases"))
    out = Dict{String,Any}[]
    used = Set([1])
    for (i, raw) in enumerate(value)
        raw isa AbstractDict || throw(ArgumentError("loads.cases entry $i must be a table"))
        row = Dict{String,Any}(String(k) => v for (k, v) in raw)
        unknown = setdiff(keys(row), union(keys(LOAD_CASE_FIELDS), ["id", "label", "enabled"]))
        isempty(unknown) || throw(ArgumentError("unknown load-case fields: " * join(unknown, ", ")))
        id_raw = get(row, "id", i + 1)
        id_num = id_raw isa AbstractString ? parse(Float64, id_raw) : Float64(id_raw)
        isfinite(id_num) && isinteger(id_num) && 2 <= id_num <= 49999999 ||
            throw(ArgumentError("extra load case id must be an integer between 2 and 49999999"))
        id = Int(id_num)
        id in used && throw(ArgumentError("duplicate load case id $id"))
        push!(used, id)
        row["id"] = id
        label = strip(String(get(row, "label", "Load case $id")))
        isempty(label) && throw(ArgumentError("load case $id needs a label"))
        any(iscntrl, label) && throw(ArgumentError("load case $id label must be a single line"))
        row["label"] = label
        enabled = get(row, "enabled", true)
        enabled isa Bool || throw(ArgumentError("load case $id enabled must be true or false"))
        row["enabled"] = enabled
        for (field, key) in LOAD_CASE_FIELDS
            haskey(row, field) || continue
            row[field] = coerce_value(SCHEMA_BY_KEY[key], row[field])
            row[field] isa Number && !isfinite(row[field]) &&
                throw(ArgumentError("load case $id field $field must be finite"))
        end
        push!(out, row)
    end
    return out
end

"""Base case 1 plus enabled extras, with each case's inherited effective inputs."""
function load_case_specs(p::AbstractDict)
    base = copy(p)
    base["loads.cases"] = Any[]
    label = strip(String(get(p, "loads.label", "Load case 1")))
    isempty(label) && throw(ArgumentError("load case 1 needs a name"))
    any(iscntrl, label) && throw(ArgumentError("load case 1 name must be a single line"))
    specs = [(id = 1, label = label, params = base)]
    for row in normalize_load_cases(get(p, "loads.cases", Any[]))
        row["enabled"] || continue
        effective = copy(base)
        for (field, key) in LOAD_CASE_FIELDS
            haskey(row, field) && (effective[key] = row[field])
        end
        push!(specs, (id = row["id"], label = row["label"], params = effective))
    end
    return specs
end

"""Shallow structural view: case inputs differ, all FE topology is shared."""
function model_for_load_case(m::Model, spec)
    # Reuse the original object in the common single-case/default case, keeping
    # the aerodynamic cache effective across mesh display and deck export.
    spec.id == 1 && isempty(get(m.params, "loads.cases", Any[])) && return m
    return Model((field === :params ? spec.params : getfield(m, field)
                  for field in fieldnames(Model))...)
end

function case_loads(m::Model)
    fingerprint = hash(m.params)
    return lock(CASE_LOAD_CACHE_LOCK) do
        cached = CASE_LOAD_CACHE[]
        if cached !== nothing && cached.model === m && cached.fingerprint == fingerprint
            return cached.cases
        end
        cases = [(id = spec.id, label = spec.label, params = spec.params,
                  loads = aerodynamic_loads(model_for_load_case(m, spec)))
                 for spec in load_case_specs(m.params)]
        CASE_LOAD_CACHE[] = (model = m, fingerprint = fingerprint, cases = cases)
        return cases
    end
end

"""Normalized tributary weights for lift and prescribed global-y torque."""
function station_load_shares(m::Model)
    etas = [sp.eta for sp in m.rbe3]
    kind = String(m.params["loads.distribution"])
    return [begin
        lo = i == 1 ? 0.0 : (etas[i-1] + eta) / 2
        hi = i == length(etas) ? 1.0 : (eta + etas[i+1]) / 2
        lift_fraction(kind, m.wing, hi) - lift_fraction(kind, m.wing, lo)
    end for (i, eta) in enumerate(etas)]
end

static_subcase_id(id::Integer, sol::AbstractString) = sol == "105" ? 2id - 1 : id
buckling_subcase_id(id::Integer) = 2id
