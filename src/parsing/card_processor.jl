# card_processor.jl — Card processing, INCLUDE resolution, and case control / bulk data splitting

"""
    resolve_includes(lines, base_dir; depth=0)

Recursively resolve INCLUDE cards in a Nastran BDF file.
Replaces each INCLUDE line with the contents of the referenced file.
Supports quoted filenames, relative and absolute paths, and nested includes (max 10 levels).
"""
function resolve_includes(lines::Vector{String}, base_dir::String; depth::Int=0,
                          _active_paths::Set{String}=Set{String}())
    depth > 10 && throw(ArgumentError("INCLUDE nesting exceeds 10 levels in $base_dir"))
    result = String[]
    sizehint!(result, length(lines))
    for line in lines
        stripped = strip(line)
        if occursin(r"^INCLUDE(?:\s|,|$)"i, stripped)
            # Extract filename: INCLUDE 'filename' or INCLUDE "filename" or INCLUDE filename
            spec = match(r"^INCLUDE\s*,?\s*(?:'([^']+)'|\"([^\"]+)\"|([^\s$]+))\s*(?:\$.*)?$"i, stripped)
            spec === nothing && throw(ArgumentError("Malformed or unsupported multiline INCLUDE in $base_dir: $stripped"))
            inc_file = something(spec.captures...)
            inc_file = strip(inc_file)
            # Resolve path: if not absolute, resolve relative to base_dir
            if !isabspath(inc_file)
                inc_file = joinpath(base_dir, inc_file)
            end
            inc_file = normpath(inc_file)
            if isfile(inc_file)
                canonical = realpath(inc_file)
                Sys.iswindows() && (canonical = lowercase(canonical))
                canonical in _active_paths && throw(ArgumentError("Cyclic INCLUDE dependency: $inc_file"))
                push!(_active_paths, canonical)
                inc_lines = readlines(inc_file)
                inc_dir = dirname(inc_file)
                resolved = try
                    resolve_includes(inc_lines, inc_dir; depth=depth+1, _active_paths=_active_paths)
                finally
                    delete!(_active_paths, canonical)
                end
                append!(result, resolved)
                println("[INFO] INCLUDE resolved: $(basename(inc_file)) ($(length(resolved)) lines, depth=$depth)")
            else
                throw(ArgumentError("INCLUDE file not found: $inc_file"))
            end
        else
            push!(result, line)
        end
    end
    return result
end

function process_cards(lines)
    processed = Dict{String, Vector{Any}}()
    i = 1
    while i <= length(lines)
        line = _nastran_without_comment(lines[i])
        clean_line = strip(line)
        if startswith(clean_line, '$') || isempty(clean_line)
            i += 1; continue
        end

        name = get_nastran_card_name(line)
        if startswith(name, "+") || name == "*"
             i += 1; continue
        end

        # Detect large-field format (card name ends with *)
        is_large = endswith(name, "*")
        base_name = strip(is_large ? name[1:end-1] : name)

        if !isnothing(base_name) && !isempty(base_name)
            fields = Any["SMALL"; String(base_name)]
            append!(fields, get_nastran_fields_from_line(line; large_field=is_large))

            steps = 1
            while i + steps <= length(lines)
                next_line = _nastran_without_comment(lines[i+steps])
                next_clean = strip(next_line)
                if isempty(next_clean)
                    steps += 1; continue
                end

                is_cont = false
                is_cont_large = false
                if startswith(next_clean, "*")
                    is_cont = true
                    is_cont_large = true
                elseif isempty(get_nastran_card_name(next_line)) || startswith(next_clean, "+")
                    is_cont = true
                elseif occursin(",", next_line) && startswith(next_clean, ",")
                    is_cont = true
                end

                if is_cont
                    append!(fields, get_nastran_fields_from_line(next_line; large_field=(is_large || is_cont_large)))
                    steps += 1
                else
                    break
                end
            end

            if !haskey(processed, base_name); processed[base_name] = []; end
            push!(processed[base_name], fields)
            i += steps
        else
            i += 1
        end
    end
    return processed
end

function read_bulk_and_case(lines::Vector{String})
    case_control = Dict{String, Any}("SUBCASES" => Dict{Int, Dict{String, Any}}())
    bulk_lines = String[]
    in_bulk = false
    past_cend = false
    global_load, global_spc, global_mpc = nothing, nothing, nothing
    current_sub = 0

    # Check if BEGIN BULK exists anywhere in the file (case-insensitive
    # regex avoids allocating an uppercased copy of every line — measured
    # 42 ms + 53 MB per pass on a CRM-class deck)
    has_begin_bulk = any(occursin(r"^\s*BEGIN\s+BULK\s*$"i, _nastran_without_comment(l)) for l in lines)

    # Default SOL type
    case_control["SOL"] = 101

    function _store_case_control_entry!(target::Dict{String, Any}, key_raw::AbstractString, value)
        key_clean = strip(key_raw)
        modifier = nothing
        modifier_match = match(r"^([^(]+)\(([^)]*)\)$", key_clean)
        if modifier_match !== nothing
            key_clean = strip(modifier_match.captures[1])
            modifier = strip(modifier_match.captures[2])
        end

        if key_clean in ("TEMP", "TEMPERATURE")
            thermal_modifier = isnothing(modifier) ? "BOTH" : uppercase(modifier)
            thermal_modifier in ("LOAD", "BOTH") || throw(ArgumentError(
                "$key_clean($thermal_modifier) is unsupported; only same-set LOAD, BOTH, or the default BOTH selection is implemented"))
            for alias in ("TEMP", "TEMPERATURE")
                haskey(target, alias) || continue
                prior_modifier = get(target, alias * "_MODIFIER", "BOTH")
                (target[alias] == value && prior_modifier == thermal_modifier) ||
                    throw(ArgumentError("Conflicting temperature selections in one Case Control scope; independent temperature sets/modifiers are not implemented"))
            end
        end

        target[key_clean] = value
        if !isnothing(modifier) && !isempty(modifier)
            target["$(key_clean)_MODIFIER"] = uppercase(modifier)
        end
        return key_clean
    end

    for line in lines
        cl = uppercase(_nastran_without_comment(line))
        if occursin(r"^\s*BEGIN\s+BULK\s*$", cl); in_bulk=true; continue; end
        # If no BEGIN BULK in file, treat everything after CEND as bulk
        if !has_begin_bulk && past_cend && !in_bulk
            in_bulk = true
        end
        if strip(cl) == "ENDDATA"; break; end

        if !in_bulk
            stripped_cl = strip(cl)

            # Parse SOL type (executive control)
            if startswith(stripped_cl, "SOL ")
                m = match(r"SOL\s+(\d+)", stripped_cl)
                if m !== nothing
                    case_control["SOL"] = parse(Int, m.captures[1])
                end
                continue
            end

            # Skip MYSTRAN-specific case control keywords
            if startswith(stripped_cl, "ELDATA"); continue; end
            if startswith(stripped_cl, "LABEL"); continue; end
            if startswith(stripped_cl, "ECHO"); continue; end
            if startswith(stripped_cl, "SET "); continue; end
            if startswith(stripped_cl, "GPFORCE"); continue; end
            if startswith(stripped_cl, "MPCFORCE"); continue; end
            if startswith(stripped_cl, "OLOAD"); continue; end
            if startswith(stripped_cl, "TITLE"); continue; end
            if startswith(stripped_cl, "SUBTI"); continue; end
            if startswith(stripped_cl, "CEND"); past_cend = true; continue; end

            if startswith(stripped_cl, "SUBCASE")
                parts = split(cl)
                if length(parts) >= 2
                    val = try parse(Int, parts[2]) catch; 0 end
                    if val > 0
                        current_sub = val
                        case_control["SUBCASES"][current_sub] = Dict{String, Any}("LOAD"=>global_load, "SPC"=>global_spc, "MPC"=>global_mpc)
                    end
                end
            elseif occursin("=", cl)
                # Parse key = value, handling parenthetical modifiers like DISP(PRINT,PLOT) = ALL
                eq_parts = split(cl, "="; limit=2)
                k_raw = strip(eq_parts[1])
                v_raw = strip(eq_parts[2])
                val = try parse(Int, v_raw) catch; v_raw end
                if current_sub > 0
                    _store_case_control_entry!(case_control["SUBCASES"][current_sub], k_raw, val)
                else
                    k = _store_case_control_entry!(case_control, k_raw, val)
                    if k == "LOAD"; global_load = val; end
                    if k == "SPC"; global_spc = val; end
                    if k == "MPC"; global_mpc = val; end
                end
            end
        else
            if length(strip(cl)) > 1
                push!(bulk_lines, String(rstrip(cl)))
            end
        end
    end

    # Create default subcase if none defined but global load/spc exists
    if isempty(case_control["SUBCASES"]) && (!isnothing(global_load) || !isnothing(global_spc))
        case_control["SUBCASES"][1] = Dict{String, Any}("LOAD"=>global_load, "SPC"=>global_spc, "MPC"=>global_mpc)
        println("[INFO] No SUBCASE defined. Created default SUBCASE 1 with LOAD=$global_load, SPC=$global_spc")
    end

    return case_control, bulk_lines
end
