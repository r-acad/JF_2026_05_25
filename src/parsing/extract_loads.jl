# extract_loads.jl — FORCE, MOMENT, PLOAD4, PLOAD2, PLOAD1, GRAV, LOAD combos

function extract_loads(cards)
    f = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        gid = to_id(parse_nastran_number(safe_get(c, 4)))
        cid = to_id(parse_nastran_number(safe_get(c, 5), 0))
        mag = parse_nastran_number(safe_get(c, 6), 0.0)
        dir = [parse_nastran_number(safe_get(c, 7),0.0), parse_nastran_number(safe_get(c, 8),0.0), parse_nastran_number(safe_get(c, 9),0.0)]
        push!(f, Dict("TYPE"=>"FORCE", "SID"=>sid, "GID"=>gid, "CID"=>cid, "Mag"=>mag, "Dir"=>dir))
    end
    return f
end

function extract_moments(cards)
    m = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        gid = to_id(parse_nastran_number(safe_get(c, 4)))
        cid = to_id(parse_nastran_number(safe_get(c, 5), 0))
        mag = parse_nastran_number(safe_get(c, 6), 0.0)
        dir = [parse_nastran_number(safe_get(c, 7),0.0), parse_nastran_number(safe_get(c, 8),0.0), parse_nastran_number(safe_get(c, 9),0.0)]
        push!(m, Dict("TYPE"=>"MOMENT", "SID"=>sid, "GID"=>gid, "CID"=>cid, "Mag"=>mag, "Dir"=>dir))
    end
    return m
end

function extract_pload4(cards)
    p = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        eid = to_id(parse_nastran_number(safe_get(c, 4)))
        press = parse_nastran_number(safe_get(c, 5), 0.0)
        # P1..P4 occupy c[5:8]; G1/THRU and G3/EID2 follow at c[9:10].
        # The current load integrator supports uniform pressure only.
        for k in 6:8
            pk = parse_nastran_number(safe_get(c, k), press)
            pk == press || throw(ArgumentError("PLOAD4 SID=$sid EID=$eid: nonuniform P1-P4 pressure is not supported"))
        end
        thru = uppercase(strip(string(safe_get(c, 9, "")))) == "THRU"
        eid2 = thru ? to_id(parse_nastran_number(safe_get(c, 10), 0)) : 0
        thru && eid2 < eid && throw(ArgumentError("PLOAD4 SID=$sid: THRU end $eid2 precedes EID $eid"))
        g1 = thru ? 0 : to_id(parse_nastran_number(safe_get(c, 9), 0))
        g3 = thru ? 0 : to_id(parse_nastran_number(safe_get(c, 10), 0))
        # Continuation line: CID(field 10→c[11]), N1(c[12]), N2(c[13]), N3(c[14])
        cid = to_id(parse_nastran_number(safe_get(c, 11), 0))
        n1 = parse_nastran_number(safe_get(c, 12), nothing)
        n2 = parse_nastran_number(safe_get(c, 13), nothing)
        n3 = parse_nastran_number(safe_get(c, 14), nothing)
        eids = thru && eid2 > eid ? collect(eid:eid2) : [eid]
        for e in eids
            d = Dict{String,Any}("TYPE"=>"PLOAD4", "SID"=>sid, "EID"=>e, "P"=>press)
            if g1 > 0; d["G1"] = g1; end
            if g3 > 0; d["G3"] = g3; end
            if n1 !== nothing && n2 !== nothing && n3 !== nothing
                d["CID"] = cid
                d["N"] = [Float64(n1), Float64(n2), Float64(n3)]
            end
            push!(p, d)
        end
    end
    return p
end

function extract_pload2(cards)
    p = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        press = parse_nastran_number(safe_get(c, 4), 0.0)
        # EID list with optional THRU ranges: `EID1 THRU EID2` expands to the
        # inclusive range. The literal THRU previously parsed to 0 and was
        # skipped, silently loading only the two endpoint elements.
        eids = Int[]
        k = 5
        while k <= length(c)
            raw = uppercase(strip(string(safe_get(c, k, ""))))
            if raw == "THRU"
                e2 = to_id(parse_nastran_number(safe_get(c, k + 1), 0))
                if !isempty(eids) && e2 > eids[end]
                    append!(eids, (eids[end] + 1):e2)
                end
                k += 2
                continue
            end
            eid = to_id(parse_nastran_number(raw, 0))
            eid > 0 && push!(eids, eid)
            k += 1
        end
        for eid in eids
            push!(p, Dict("TYPE"=>"PLOAD4", "SID"=>sid, "EID"=>eid, "P"=>press))
        end
    end
    return p
end

function extract_pload(cards)
    p = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        press = parse_nastran_number(safe_get(c, 4), 0.0)
        g1 = to_id(parse_nastran_number(safe_get(c, 5), 0))
        g2 = to_id(parse_nastran_number(safe_get(c, 6), 0))
        g3 = to_id(parse_nastran_number(safe_get(c, 7), 0))
        g4 = to_id(parse_nastran_number(safe_get(c, 8), 0))
        nodes = filter(x -> x > 0, [g1, g2, g3, g4])
        if length(nodes) >= 3
            push!(p, Dict("TYPE"=>"PLOAD", "SID"=>sid, "P"=>press, "NODES"=>nodes))
        end
    end
    return p
end

function extract_pload1(cards)
    p = []
    for c in cards
        sid   = to_id(parse_nastran_number(safe_get(c, 3)))
        eid   = to_id(parse_nastran_number(safe_get(c, 4)))
        # TYPE field: can be integer (1-6) or string ("FX","FY","FZ","MX","MY","MZ")
        ltype_raw = strip(string(safe_get(c, 5, "0")))
        ltype_map = Dict("FX"=>1,"FY"=>2,"FZ"=>3,"MX"=>4,"MY"=>5,"MZ"=>6)
        ltype = get(ltype_map, uppercase(ltype_raw), to_id(parse_nastran_number(ltype_raw, 0)))
        scale_str = strip(string(safe_get(c, 6, "")))
        x1    = Float64(parse_nastran_number(safe_get(c, 7), 0.0))
        p1    = Float64(parse_nastran_number(safe_get(c, 8), 0.0))
        x2    = Float64(parse_nastran_number(safe_get(c, 9), 1.0))
        p2    = Float64(parse_nastran_number(safe_get(c, 10), 0.0))
        if sid > 0 && eid > 0
            push!(p, Dict("TYPE"=>"PLOAD1", "SID"=>sid, "EID"=>eid,
                          "LOAD_TYPE"=>ltype, "SCALE"=>scale_str,
                          "X1"=>x1, "P1"=>p1, "X2"=>x2, "P2"=>p2))
        end
    end
    return p
end

function extract_grav(cards)
    g = []
    for c in cards
        sid   = to_id(parse_nastran_number(safe_get(c, 3)))
        cid   = to_id(parse_nastran_number(safe_get(c, 4), 0))
        accel = Float64(parse_nastran_number(safe_get(c, 5), 0.0))
        n1    = Float64(parse_nastran_number(safe_get(c, 6), 0.0))
        n2    = Float64(parse_nastran_number(safe_get(c, 7), 0.0))
        n3    = Float64(parse_nastran_number(safe_get(c, 8), 0.0))
        if sid > 0
            push!(g, Dict("TYPE"=>"GRAV", "SID"=>sid, "CID"=>cid,
                           "A"=>accel, "N"=>[n1, n2, n3]))
        end
    end
    return g
end

function extract_rforce(cards)
    r = []
    for c in cards
        sid    = to_id(parse_nastran_number(safe_get(c, 3)))
        g_node = to_id(parse_nastran_number(safe_get(c, 4), 0))  # rotation center grid (0=origin)
        cid    = to_id(parse_nastran_number(safe_get(c, 5), 0))
        A_val  = Float64(parse_nastran_number(safe_get(c, 6), 0.0))  # angular velocity scale
        r1     = Float64(parse_nastran_number(safe_get(c, 7), 0.0))
        r2     = Float64(parse_nastran_number(safe_get(c, 8), 0.0))
        r3     = Float64(parse_nastran_number(safe_get(c, 9), 0.0))
        method = to_id(parse_nastran_number(safe_get(c, 10), 1))
        racc   = Float64(parse_nastran_number(safe_get(c, 11), 0.0))
        mb     = to_id(parse_nastran_number(safe_get(c, 12), 0))
        idrf   = to_id(parse_nastran_number(safe_get(c, 13), 0))
        if sid > 0
            push!(r, Dict("TYPE"=>"RFORCE", "SID"=>sid, "G"=>g_node, "CID"=>cid,
                           "A"=>A_val, "R"=>[r1, r2, r3], "METHOD"=>method,
                           "RACC"=>racc, "MB"=>mb, "IDRF"=>idrf))
        end
    end
    return r
end

function extract_load_combos(cards)
    combos = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        s = parse_nastran_number(safe_get(c, 4), 1.0)
        comps = []
        for i in 5:2:length(c)-1
            s_i = parse_nastran_number(safe_get(c, i), nothing)
            l_i = to_id(parse_nastran_number(safe_get(c, i+1), nothing))
            if !isnothing(s_i) && l_i > 0
                push!(comps, Dict("S"=>s_i, "LID"=>l_i))
            end
        end
        push!(combos, Dict("SID"=>sid, "S"=>s, "COMPS"=>comps))
    end
    return combos
end

function extract_temp(cards)
    temps = Dict{Int, Dict{Int,Float64}}()  # SID => {GID => T}
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        if sid <= 0; continue; end
        if !haskey(temps, sid); temps[sid] = Dict{Int,Float64}(); end
        # Read every grid-temperature pair carried by the flattened card,
        # including continuation fields beyond the first three pairs.
        for i in 4:2:length(c)-1
            gid = to_id(parse_nastran_number(safe_get(c, i), 0))
            t_val = parse_nastran_number(safe_get(c, i + 1), nothing)
            if gid > 0 && t_val !== nothing
                temps[sid][gid] = Float64(t_val)
            end
        end
    end
    return temps
end

function extract_tempd(cards)
    tempd = Dict{Int, Float64}()  # SID => default temperature
    for c in cards
        for k in 3:2:min(length(c) - 1, 9)
            sid = to_id(parse_nastran_number(safe_get(c, k)))
            t_val = parse_nastran_number(safe_get(c, k + 1), 0.0)
            if sid > 0
                tempd[sid] = Float64(t_val)
            end
        end
    end
    return tempd
end

"""
Parse DMIG cards into sparse matrix entries.
Returns Dict{String, Dict}: name => {"type"=>symmetric/square, "entries"=>[(row_grid, row_dof, col_grid, col_dof, value), ...]}
"""
function extract_dmig(cards)
    matrices = Dict{String, Dict{String,Any}}()
    # The header is DMIG,NAME,0,IFO,TIN,TOUT,POLAR,,NCOL. Resolve all
    # headers first, since a column card may precede its header in an INCLUDE.
    for c in cards
        name = strip(string(safe_get(c, 3, "")))
        isempty(name) && continue
        parse_nastran_number(safe_get(c, 4), nothing) == 0 || continue
        haskey(matrices, name) && throw(ArgumentError("Duplicate DMIG header: $name"))
        ifo = to_id(parse_nastran_number(safe_get(c, 5), 0))
        tin = to_id(parse_nastran_number(safe_get(c, 6), 0))
        tin in (1, 2) || throw(ArgumentError("DMIG $name requires real TIN=1 or 2; TIN=$tin is unsupported"))
        ifo in (1, 6) || throw(ArgumentError("DMIG $name requires square IFO=1 or symmetric IFO=6; IFO=$ifo is unsupported"))
        matrices[name] = Dict{String,Any}("type" => ifo == 6 ? "symmetric" : "square",
            "IFO"=>ifo, "TIN"=>tin, "entries" => Tuple{Int,Int,Int,Int,Float64}[])
    end
    for raw in cards
        c = Any[x for x in raw if !(x isa AbstractString && _is_continuation_marker(x))]
        name = strip(string(safe_get(c, 3, "")))
        isempty(name) && continue
        gj = to_id(parse_nastran_number(safe_get(c, 4), 0))
        gj == 0 && continue
        haskey(matrices, name) || throw(ArgumentError("DMIG $name has column data without a header"))
        cj = to_id(parse_nastran_number(safe_get(c, 5), 0))
        gj > 0 && 1 <= cj <= 6 || throw(ArgumentError("DMIG $name has invalid column GRID/component $gj/$cj"))
        entries = matrices[name]["entries"]
        # Each row is G,C,A,B, even for a real matrix where B is blank.
        for k in 7:4:length(c)
            all(j -> isempty(strip(string(safe_get(c, j, "")))), k:min(k + 3, length(c))) && continue
            gi = to_id(parse_nastran_number(safe_get(c, k), 0))
            ci = to_id(parse_nastran_number(safe_get(c, k + 1), 0))
            ai = parse_nastran_number(safe_get(c, k + 2), nothing)
            bi = parse_nastran_number(safe_get(c, k + 3), 0.0)
            gi > 0 && 1 <= ci <= 6 && ai isa Real && isfinite(ai) && bi == 0 ||
                throw(ArgumentError("DMIG $name has an invalid or unsupported complex row at field $k"))
            push!(entries, (gi, ci, gj, cj, Float64(ai)))
        end
    end
    return matrices
end

function extract_spcd(cards)
    out = []
    for c in cards
        sid = to_id(parse_nastran_number(safe_get(c, 3)))
        for base in (4, 7)
            g = to_id(parse_nastran_number(safe_get(c, base), 0))
            g == 0 && continue
            comps = string(to_id(parse_nastran_number(safe_get(c, base + 1), 0)))
            val = parse_nastran_number(safe_get(c, base + 2), 0.0)
            for ch in comps
                d = ch - '0'
                1 <= d <= 6 || continue
                push!(out, Dict("TYPE"=>"SPCD", "SID"=>sid, "GID"=>g, "C"=>d, "D"=>val))
            end
        end
    end
    return out
end
