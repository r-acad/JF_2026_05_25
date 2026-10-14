# extract_constraints.jl — SPC1, SPC, SPCADD, RBE2, RBE3, MPC, MPCADD

function extract_spc1(cards)
    spcs = []
    for c in cards
        sid = to_id(parse_reference_number(safe_get(c, 3)))
        comp = string(parse_reference_number(safe_get(c, 4), ""))
        raw_nodes = c[5:end]
        nodes = expand_reference_list(raw_nodes)
        push!(spcs, Dict("SID"=>sid, "C"=>comp, "NODES"=>nodes))
    end
    return spcs
end

function extract_spcadd(cards)
    d = Dict()
    for c in cards
        sid = to_id(parse_reference_number(safe_get(c, 3)))
        raw_sets = c[4:end]
        sets = expand_reference_list(raw_sets)
        d[sid] = sets
    end
    return d
end

function extract_spc(cards)
    spcs = []
    for c in cards
        sid = to_id(parse_reference_number(safe_get(c, 3)))
        gid = to_id(parse_reference_number(safe_get(c, 4)))
        comp = string(parse_reference_number(safe_get(c, 5), ""))
        d1 = Float64(parse_reference_number(safe_get(c, 6), 0.0))
        if gid > 0
            push!(spcs, Dict("SID"=>sid, "C"=>comp, "NODES"=>[gid], "D"=>d1))
        end
        gid2 = to_id(parse_reference_number(safe_get(c, 7), 0))
        if gid2 > 0
            comp2 = string(parse_reference_number(safe_get(c, 8), ""))
            d2 = Float64(parse_reference_number(safe_get(c, 9), 0.0))
            push!(spcs, Dict("SID"=>sid, "C"=>comp2, "NODES"=>[gid2], "D"=>d2))
        end
    end
    return spcs
end

function extract_rbe2(cards)
    d = Dict()
    for c in cards
        eid = to_id(parse_reference_number(safe_get(c, 3)))
        gn  = to_id(parse_reference_number(safe_get(c, 4)))  # master node
        cm  = to_id(parse_reference_number(safe_get(c, 5)))   # constrained components (e.g. 123456)
        # GRID IDs are integers; the first real field ends that list and
        # starts optional ALPHA, TREF. Never round a thermal field into a GRID.
        slave_grids = Int[]
        thermal = Float64[]
        for k in 6:length(c)
            field = strip(string(safe_get(c, k, "")))
            (isempty(field) || _is_continuation_marker(field)) && continue
            value = parse_reference_number(field, nothing)
            value isa Real && isfinite(value) ||
                throw(ArgumentError("RBE2 $eid has an invalid GRID or thermal field: $field"))
            if !isempty(thermal) || _is_reference_real(field)
                length(thermal) < 2 || throw(ArgumentError("RBE2 $eid has data after ALPHA and TREF"))
                push!(thermal, Float64(value))
            else
                value isa Integer && value > 0 ||
                    throw(ArgumentError("RBE2 $eid requires positive integer dependent GRID IDs"))
                push!(slave_grids, Int(value))
            end
        end
        if eid > 0 && gn > 0
            entry = Dict{String,Any}("ID"=>eid, "GN"=>gn, "CM"=>cm, "GM"=>slave_grids)
            if !isempty(thermal)
                entry["ALPHA"] = thermal[1]
                entry["TREF"] = length(thermal) == 2 ? thermal[2] : 0.0
            end
            d[string(eid)] = entry
        end
    end
    return d
end

function _is_continuation_marker(s::AbstractString)
    st = strip(s)
    isempty(st) && return false
    return st[1] == '*' || (st[1] == '+' && parse_reference_number(st, nothing) === nothing)
end

function _is_reference_real(s::AbstractString)
    # Detect if a field is a real number (weight) vs an integer (grid ID).
    # Reference reals have '.', 'E', 'e', 'D', 'd', or Reference-style +/- exponent.
    st = strip(s)
    isempty(st) && return false
    _is_continuation_marker(st) && return false
    return occursin('.', st) || occursin(r"[EeDd]", st) ||
           (length(st) > 1 && occursin(r"[\+\-]", st[2:end]))
end

function extract_rbe3(cards)
    d = Dict()
    for c in cards
        eid = to_id(parse_reference_number(safe_get(c, 3)))
        refgrid = to_id(parse_reference_number(safe_get(c, 5)))
        refc = to_id(parse_reference_number(safe_get(c, 6)))

        # Parse multiple weight groups: WT1,C1,G1...,Gn, WT2,C2,G1...,Gm, ...
        # Continuation markers (+XX, *XX) are skipped as they are parser artifacts.
        # Optional UM entries redefine the dependent DOFs. The solver honors
        # this explicit set and uses REFGRID/REFC only when UM is absent.
        wt_groups = []
        um_pairs = []
        alpha = 0.0
        tref = 0.0
        um_idx = 0
        alpha_idx = 0
        for k in 7:length(c)
            marker = uppercase(strip(string(safe_get(c, k))))
            if marker == "UM" && um_idx == 0
                um_idx = k
            elseif marker == "ALPHA" && alpha_idx == 0
                alpha_idx = k
            end
        end
        wt_stop = length(c) + 1
        if um_idx > 0
            wt_stop = min(wt_stop, um_idx)
        end
        if alpha_idx > 0
            wt_stop = min(wt_stop, alpha_idx)
        end

        pos = 7
        while pos < wt_stop
            wt_str = strip(safe_get(c, pos))
            if isempty(wt_str) || _is_continuation_marker(wt_str); pos += 1; continue; end
            wt_val = parse_reference_number(wt_str, NaN)
            if isnan(wt_val); break; end
            pos += 1
            # Skip blanks/continuations before comps field
            while pos <= length(c)
                cs = strip(safe_get(c, pos))
                if !isempty(cs) && !_is_continuation_marker(cs); break; end
                pos += 1
            end
            if pos > length(c); break; end
            comps_val = to_id(parse_reference_number(safe_get(c, pos)))
            pos += 1
            grids = Int[]
            while pos <= length(c)
                g_str = strip(safe_get(c, pos))
                if isempty(g_str); pos += 1; continue; end
                if _is_continuation_marker(g_str); pos += 1; continue; end
                # New weight group starts if field looks like a real number
                if _is_reference_real(g_str); break; end
                gid = parse_reference_number(g_str, NaN)
                if isnan(gid); break; end
                push!(grids, Int(gid))
                pos += 1
            end
            if !isempty(grids)
                push!(wt_groups, (wt=wt_val, comps=comps_val, grids=grids))
            end
        end

        if um_idx > 0
            um_stop = alpha_idx > 0 ? alpha_idx : length(c) + 1
            pos = um_idx + 1
            while pos + 1 < um_stop
                g_str = strip(safe_get(c, pos))
                c_str = strip(safe_get(c, pos + 1))
                if isempty(g_str) || _is_continuation_marker(g_str)
                    pos += 1
                    continue
                end
                if uppercase(g_str) == "ALPHA"
                    break
                end
                gid = to_id(parse_reference_number(g_str, 0))
                comps_val = to_id(parse_reference_number(c_str, 0))
                if gid > 0 && comps_val > 0
                    push!(um_pairs, (grid=gid, comps=comps_val))
                end
                pos += 2
            end
        end

        if alpha_idx > 0
            alpha = Float64(parse_reference_number(safe_get(c, alpha_idx + 1), 0.0))
            tref = Float64(parse_reference_number(safe_get(c, alpha_idx + 2), 0.0))
        end

        d[string(eid)] = Dict("ID"=>eid, "REFGRID"=>refgrid, "REFC"=>refc,
                              "WT_GROUPS"=>wt_groups, "UM"=>um_pairs,
                              "ALPHA"=>alpha, "TREF"=>tref)
    end
    return d
end

function extract_rbar(cards)
    d = Dict()
    for c in cards
        eid = to_id(parse_reference_number(safe_get(c, 3)))
        ga  = to_id(parse_reference_number(safe_get(c, 4)))
        gb  = to_id(parse_reference_number(safe_get(c, 5)))
        cna = to_id(parse_reference_number(safe_get(c, 6), 0))
        cnb = to_id(parse_reference_number(safe_get(c, 7), 0))
        cma = to_id(parse_reference_number(safe_get(c, 8), 0))
        cmb = to_id(parse_reference_number(safe_get(c, 9), 0))
        if eid > 0 && ga > 0 && gb > 0
            d[string(eid)] = Dict("ID"=>eid, "GA"=>ga, "GB"=>gb, "CNA"=>cna, "CNB"=>cnb, "CMA"=>cma, "CMB"=>cmb)
        end
    end
    return d
end

function extract_rbe1(cards)
    d = Dict()
    for c in cards
        eid = to_id(parse_reference_number(safe_get(c, 3)))
        # Find "UM" marker — separates independent from dependent DOFs
        um_idx = 0
        for k in 3:length(c)
            s = strip(uppercase(string(safe_get(c, k))))
            if s == "UM"
                um_idx = k
                break
            end
        end
        if eid <= 0 || um_idx == 0; continue; end

        # Parse independent DOFs: pairs of (grid, component) before UM
        indep = Tuple{Int,Int}[]
        k = 4
        while k + 1 <= length(c) && k < um_idx
            g = to_id(parse_reference_number(safe_get(c, k), 0))
            cn = to_id(parse_reference_number(safe_get(c, k+1), 0))
            if g > 0 && cn > 0
                # Expand component digits (e.g. 123 → [1,2,3])
                for ch in string(cn)
                    if isdigit(ch)
                        push!(indep, (g, parse(Int, string(ch))))
                    end
                end
            end
            k += 2
        end

        # Parse dependent DOFs: pairs of (grid, component) after UM
        dep = Tuple{Int,Int}[]
        k = um_idx + 1
        while k + 1 <= length(c)
            g = to_id(parse_reference_number(safe_get(c, k), 0))
            cn = to_id(parse_reference_number(safe_get(c, k+1), 0))
            if g > 0 && cn > 0
                for ch in string(cn)
                    if isdigit(ch)
                        push!(dep, (g, parse(Int, string(ch))))
                    end
                end
            end
            k += 2
        end

        if !isempty(indep) && !isempty(dep)
            d[string(eid)] = Dict("ID"=>eid, "INDEP"=>indep, "DEP"=>dep)
        end
    end
    return d
end

function extract_rspline(cards)
    d = Dict()
    for raw in cards
        c = Any[x for x in raw if !(x isa AbstractString && _is_continuation_marker(x))]
        eid = to_id(parse_reference_number(safe_get(c, 3)))
        # D/L controls the elastic interpolation tube, not physical stiffness.
        dl = Float64(parse_reference_number(safe_get(c, 4), 0.1))
        # Field 5: first independent grid
        g1 = to_id(parse_reference_number(safe_get(c, 5), 0))
        if eid <= 0 || g1 <= 0; continue; end

        # Gi/Ci are positional pairs. A blank Ci denotes an independent GRID;
        # GRID identifiers must never be guessed from component-like digits.
        grids = [g1]
        components = [0]
        indep_grids = [g1]
        dep_list = Tuple{Int,Int}[]  # (grid, component)
        k = 6
        while k <= length(c)
            g = to_id(parse_reference_number(safe_get(c, k), 0))
            if g <= 0
                all(v -> isnothing(v) || isempty(strip(string(v))), c[k:end]) && break
                throw(ArgumentError("RSPLINE $eid requires a positive GRID in each Gi/Ci pair"))
            end
            raw = safe_get(c, k+1)
            blank = isnothing(raw) || isempty(strip(string(raw)))
            ci = blank ? 0 : to_id(parse_reference_number(raw, 0))
            if !blank
                chars = collect(string(ci))
                ci > 0 && all(ch -> ch in '1':'6', chars) && length(unique(chars)) == length(chars) ||
                    throw(ArgumentError("RSPLINE $eid requires distinct component digits 1 through 6, or a blank Ci"))
                append!(dep_list, [(g, Int(ch-'0')) for ch in chars])
            else
                push!(indep_grids, g)
            end
            push!(grids, g)
            push!(components, ci)
            k += 2
        end
        isfinite(dl) && dl > 0 || throw(ArgumentError("RSPLINE $eid D/L must be finite and positive"))
        components[end] == 0 || throw(ArgumentError("RSPLINE $eid last GRID must be independent (blank Ci)"))
        if !isempty(dep_list) && length(indep_grids) >= 2
            d[string(eid)] = Dict("ID"=>eid, "DL"=>dl, "GRIDS"=>grids, "COMPONENTS"=>components,
                                  "INDEP_GRIDS"=>indep_grids, "DEP"=>dep_list)
        end
    end
    return d
end

function extract_mpc(cards)
    mpcs = []
    for raw in cards
        c = Any[x for x in raw if !(x isa AbstractString && _is_continuation_marker(x))]
        sid = to_id(parse_reference_number(safe_get(c, 3)))
        terms = []
        # Each eight-field record reserves its first and last slots (SID
        # replaces the first slot on the parent), leaving two G/C/A triplets.
        for block in 3:8:length(c)
            first_term = block + 1
            if block > 3 && !isempty(strip(string(safe_get(c, block, ""))))
                first_term = block  # historical compact free-field continuation
            end
            for k in (first_term, first_term + 3)
                k + 1 <= length(c) || continue
                gid   = to_id(parse_reference_number(safe_get(c, k), 0))
                comp  = to_id(parse_reference_number(safe_get(c, k+1), 0))
                coeff = Float64(parse_reference_number(safe_get(c, k+2), 0.0))
                if gid > 0
                    1 <= comp <= 6 || throw(ArgumentError("MPC $sid: only GRID components 1 through 6 are supported"))
                    push!(terms, Dict("G"=>gid, "C"=>comp, "A"=>coeff))
                end
            end
        end
        if length(terms) >= 2
            push!(mpcs, Dict("SID"=>sid, "TERMS"=>terms))
        end
    end
    return mpcs
end

function extract_mpcadd(cards)
    d = Dict()
    for c in cards
        sid = to_id(parse_reference_number(safe_get(c, 3)))
        subs = Int[]
        for k in 4:length(c)
            s = to_id(parse_reference_number(safe_get(c, k), 0))
            if s > 0; push!(subs, s); end
        end
        if sid > 0 && !isempty(subs)
            d[sid] = subs
        end
    end
    return d
end
