# Standard nonlinear-static controls. Keep explicit fields so unsupported
# requests can be rejected when selected instead of silently using defaults.
const _nlparm_defaults = (
    ("SID", nothing), ("NINC", 10), ("DT", 0.0), ("KMETHOD", "AUTO"),
    ("KSTEP", 5), ("MAXITER", 25), ("CONV", "PW"), ("INTOUT", "NO"),
    ("EPSU", 0.01), ("EPSP", 0.01), ("EPSW", 0.01), ("MAXDIV", 3),
    ("MAXQN", nothing), ("MAXLS", 4), ("FSTRESS", 0.2), ("LSTOL", 0.5),
    ("MAXBIS", 5), (nothing, nothing), (nothing, nothing), (nothing, nothing),
    ("MAXR", 20.0), (nothing, nothing), ("RTOLB", 20.0),
)
const _nlparm_integer_fields = Set(("SID", "NINC", "KSTEP", "MAXITER", "MAXDIV", "MAXQN", "MAXLS", "MAXBIS"))
const _nlparm_string_fields = Set(("KMETHOD", "CONV", "INTOUT"))

function normalize_nlparm(raw::AbstractDict)
    input = Dict{String,Any}(uppercase(string(k)) => v for (k,v) in raw)
    supplied = get(input, "EXPLICIT_FIELDS", nothing)
    explicit = supplied === nothing ? Set(keys(input)) : Set(uppercase.(string.(supplied)))
    entry = Dict{String,Any}()
    for (name, default) in _nlparm_defaults
        name === nothing && continue
        value = get(input, name, default)
        if value === nothing || (value isa AbstractString && isempty(strip(value)))
            value = default
        end
        if name in _nlparm_string_fields
            entry[name] = uppercase(strip(string(value)))
        elseif value === nothing
            entry[name] = nothing
        else
            parsed = parse_reference_number(value, nothing)
            parsed isa Real && isfinite(parsed) || throw(ArgumentError("NLPARM $name must be a finite number; received $value"))
            if name in _nlparm_integer_fields
                isinteger(parsed) && typemin(Int) <= parsed <= typemax(Int) ||
                    throw(ArgumentError("NLPARM $name must be an integer; received $value"))
                entry[name] = Int(parsed)
            else
                entry[name] = Float64(parsed)
            end
        end
    end
    sid = entry["SID"]
    sid isa Integer && sid > 0 || throw(ArgumentError("NLPARM requires a positive SID"))
    entry["MAXQN"] === nothing && (entry["MAXQN"] = entry["MAXITER"])
    known = Set(name for (name,_) in _nlparm_defaults if name !== nothing)
    unknown = setdiff(explicit, union(known, Set(("TYPE", "EXPLICIT_FIELDS"))))
    isempty(unknown) || throw(ArgumentError("NLPARM $sid contains unknown fields $(join(sort!(collect(unknown)), ", "))"))
    entry["EXPLICIT_FIELDS"] = sort!(collect(intersect(explicit, known)))
    entry["TYPE"] = "NLPARM"
    return entry
end

function extract_nlparm(cards)
    result = Dict{String,Any}()
    for card in cards
        raw = Dict{String,Any}()
        for index in 1:max(length(_nlparm_defaults), length(card)-2)
            value = safe_get(card, index+2, nothing)
            (value === nothing || (value isa AbstractString && isempty(strip(value)))) && continue
            name = index <= length(_nlparm_defaults) ? _nlparm_defaults[index][1] : nothing
            name === nothing && throw(ArgumentError("NLPARM has nonblank reserved/unsupported field $index: $value"))
            raw[name] = value
        end
        entry = normalize_nlparm(raw)
        key = string(entry["SID"])
        haskey(result, key) && throw(ArgumentError("Duplicate NLPARM SID=$key"))
        result[key] = entry
    end
    return result
end
