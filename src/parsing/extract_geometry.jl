# extract_geometry.jl — GRID, coordinate systems, shell elements, CBAR

function extract_grdset(cards)
    defaults = Dict{String,Any}(
        "CP" => 0,
        "CD" => 0,
        "PS" => "",
        "SEID" => 0,
    )

    for c in cards
        cp_raw = strip(string(safe_get(c, 4, "")))
        cd_raw = strip(string(safe_get(c, 8, "")))
        ps_raw = strip(string(safe_get(c, 9, "")))
        seid_raw = strip(string(safe_get(c, 10, "")))

        !isempty(cp_raw) && (defaults["CP"] = to_id(parse_nastran_number(cp_raw, 0)))
        !isempty(cd_raw) && (defaults["CD"] = to_id(parse_nastran_number(cd_raw, 0)))
        !isempty(ps_raw) && (defaults["PS"] = ps_raw == "0" ? "" : ps_raw)
        !isempty(seid_raw) && (defaults["SEID"] = to_id(parse_nastran_number(seid_raw, 0)))
    end

    return defaults
end

function extract_grid(cards; grdset=nothing)
    defaults = isnothing(grdset) ? Dict{String,Any}("CP"=>0, "CD"=>0, "PS"=>"", "SEID"=>0) : grdset
    d = Dict()
    for c in cards
        id = to_id(parse_nastran_number(safe_get(c, 3)))
        cp_raw = strip(string(safe_get(c, 4, "")))
        x = [parse_nastran_number(safe_get(c, 5), 0.0),
             parse_nastran_number(safe_get(c, 6), 0.0),
             parse_nastran_number(safe_get(c, 7), 0.0)]
        cd_raw = strip(string(safe_get(c, 8, "")))
        ps_raw = strip(string(safe_get(c, 9, "")))
        seid_raw = strip(string(safe_get(c, 10, "")))

        cp = isempty(cp_raw) ? Int(get(defaults, "CP", 0)) : to_id(parse_nastran_number(cp_raw, 0))
        cd = isempty(cd_raw) ? Int(get(defaults, "CD", 0)) : to_id(parse_nastran_number(cd_raw, 0))
        ps = isempty(ps_raw) ? string(get(defaults, "PS", "")) : (ps_raw == "0" ? "" : ps_raw)
        seid = isempty(seid_raw) ? Int(get(defaults, "SEID", 0)) : to_id(parse_nastran_number(seid_raw, 0))

        if id > 0
            d[string(id)] = Dict("ID"=>id, "CP"=>cp, "CD"=>cd, "X"=>x, "PS"=>ps, "SEID"=>seid)
        end
    end
    return d
end

function extract_coords(cards; coord_type::String="RECTANGULAR")
    d = Dict()
    for c in cards
        id = to_id(parse_nastran_number(safe_get(c, 3)))
        rid = to_id(parse_nastran_number(safe_get(c, 4), 0))
        A = [parse_nastran_number(safe_get(c, 5),0.0), parse_nastran_number(safe_get(c, 6),0.0), parse_nastran_number(safe_get(c, 7),0.0)]
        B = [parse_nastran_number(safe_get(c, 8),0.0), parse_nastran_number(safe_get(c, 9),0.0), parse_nastran_number(safe_get(c, 10),0.0)]
        C = [parse_nastran_number(safe_get(c, 11),0.0), parse_nastran_number(safe_get(c, 12),0.0), parse_nastran_number(safe_get(c, 13),0.0)]
        w = B - A
        if norm(w) < 1e-9; w=[0.0,0.0,1.0]; else; w=normalize(w); end
        v_t = C - A
        v = cross(w, v_t)
        if norm(v) < 1e-9; v=[0.0,1.0,0.0]; else; v=normalize(v); end
        u = normalize(cross(v, w))
        d[string(id)] = Dict("Origin"=>A, "U"=>u, "V"=>v, "W"=>w, "TYPE"=>coord_type,
                              "RID"=>rid, "A_raw"=>copy(A), "B_raw"=>copy(B), "C_raw"=>copy(C))
    end
    return d
end

function extract_shells(cards)
    d = Dict()
    for c in cards
        id = to_id(parse_nastran_number(safe_get(c, 3)))
        pid = to_id(parse_nastran_number(safe_get(c, 4)))
        # Determine node count from card name suffix: CTRIA3 -> 3,
        # CQUAD4 -> 4, CTRIA6 -> 6, CQUAD8 -> 8. CQUADR has no suffix
        # but shares the four-corner shell field layout.
        card_name = uppercase(strip(string(safe_get(c, 2, ""))))
        m = match(r"(\d+)$", card_name)
        n_nodes = m !== nothing ? parse(Int, m.captures[1]) : (startswith(card_name, "CTRIA") ? 3 : 4)
        # Collect node IDs, skipping continuation markers
        nodes = _collect_node_ids(c, 5, n_nodes)
        # THETA/MCID field: immediately after node fields (approximate position)
        theta_pos = 5 + n_nodes
        # For 8-node elements, theta might be after a continuation marker
        theta_raw = safe_get(c, theta_pos, "")
        theta_str = strip(string(theta_raw))
        if !isempty(theta_str) && (startswith(theta_str, "+") || startswith(theta_str, "*"))
            theta_pos += 1  # skip continuation marker
            theta_str = strip(string(safe_get(c, theta_pos, "")))
        end
        theta = 0.0
        mcid = 0
        if !isempty(theta_str)
            theta_upper = uppercase(theta_str)
            is_mcid =
                tryparse(Int, theta_str) !== nothing &&
                !occursin('.', theta_str) &&
                !occursin('E', theta_upper) &&
                !occursin('D', theta_upper)
            if is_mcid
                mcid = to_id(parse_nastran_number(theta_str, 0))
            else
                theta = Float64(parse_nastran_number(theta_str, 0.0))
            end
        end
        if id > 0 && length(nodes) >= 3
            d[string(id)] = Dict("ID"=>id, "PID"=>pid, "NODES"=>nodes, "THETA"=>theta, "MCID"=>mcid, "TYPE"=>card_name)
        end
    end
    return d
end

"""
    _bar_continuation_base(c) -> Int

Index after which a CBAR/CBEAM's continuation data begins.

Fields 3..10 of the processed card hold the parent line's data (MSC fields
2..9). MSC field 10 is the continuation marker, and a free-field deck may or may
not emit one: `CBAR,...,1.0` produces no marker, while `CBAR,...,1.0, ,+CB1`
produces `"+CB1"` at index 11. When the marker IS present it occupies a slot and
shifts every continuation field by one.

That shift used to be silent and harmful. `PA` was read from index 11, so on a
deck with an explicit marker it read the marker itself -- and
`parse_nastran_number` does not reject `"+CB1"`, it returns a number. The result
was a pin release the deck never requested, applied to whatever DOF that number
happened to name, with no warning. On the T5 validation bar it made the tip
displacement wrong by five orders of magnitude while the solve still reported a
clean residual.
"""
@inline function _bar_continuation_base(c)
    tok = strip(string(safe_get(c, 11, "")))
    return (startswith(tok, "+") || startswith(tok, "*")) ? 11 : 10
end

function extract_cbar(cards)
    d = Dict()
    for c in cards
        id = to_id(parse_nastran_number(safe_get(c, 3)))
        pid = to_id(parse_nastran_number(safe_get(c, 4)))
        ga = to_id(parse_nastran_number(safe_get(c, 5)))
        gb = to_id(parse_nastran_number(safe_get(c, 6)))

        # Detect G0 (grid point) vs X1,X2,X3 (vector) format
        x1_raw = strip(string(safe_get(c, 7, "")))
        x2_raw = strip(string(safe_get(c, 8, "")))
        x3_raw = strip(string(safe_get(c, 9, "")))

        g0 = 0
        v = [0.0, 0.0, 0.0]
        if !isempty(x1_raw) && !occursin(".", x1_raw) && (isempty(x2_raw) || x2_raw == "0")
            # G0 format: integer grid ID, X2/X3 blank
            g0 = to_id(parse_nastran_number(x1_raw, 0))
        else
            v = [parse_nastran_number(safe_get(c, 7),0.0), parse_nastran_number(safe_get(c, 8),0.0), parse_nastran_number(safe_get(c, 9),0.0)]
        end
        if g0 == 0 && norm(v) < 1e-6; v = [0.0, 0.0, 1.0]; end

        # Parse PA/PB pin flags and WA/WB offsets from the continuation line,
        # skipping the continuation marker when the deck emits one. See
        # _bar_continuation_base.
        b = _bar_continuation_base(c)
        pa = to_id(parse_nastran_number(safe_get(c, b + 1), 0))
        pb = to_id(parse_nastran_number(safe_get(c, b + 2), 0))
        wa = [parse_nastran_number(safe_get(c, b + 3), 0.0), parse_nastran_number(safe_get(c, b + 4), 0.0), parse_nastran_number(safe_get(c, b + 5), 0.0)]
        wb = [parse_nastran_number(safe_get(c, b + 6), 0.0), parse_nastran_number(safe_get(c, b + 7), 0.0), parse_nastran_number(safe_get(c, b + 8), 0.0)]

        d[string(id)] = Dict("ID"=>id, "PID"=>pid, "GA"=>ga, "GB"=>gb, "V"=>v, "G0"=>g0, "PA"=>pa, "PB"=>pb, "WA"=>wa, "WB"=>wb, "TYPE"=>"CBAR")
    end
    return d
end

function extract_cbeam(cards)
    d = Dict()
    for c in cards
        id = to_id(parse_nastran_number(safe_get(c, 3)))
        pid = to_id(parse_nastran_number(safe_get(c, 4)))
        ga = to_id(parse_nastran_number(safe_get(c, 5)))
        gb = to_id(parse_nastran_number(safe_get(c, 6)))

        x1_raw = strip(string(safe_get(c, 7, "")))
        x2_raw = strip(string(safe_get(c, 8, "")))
        x3_raw = strip(string(safe_get(c, 9, "")))

        g0 = 0
        v = [0.0, 0.0, 0.0]
        if !isempty(x1_raw) && !occursin(".", x1_raw) && (isempty(x2_raw) || x2_raw == "0")
            g0 = to_id(parse_nastran_number(x1_raw, 0))
        else
            v = [parse_nastran_number(safe_get(c, 7),0.0), parse_nastran_number(safe_get(c, 8),0.0), parse_nastran_number(safe_get(c, 9),0.0)]
        end
        if g0 == 0 && norm(v) < 1e-6; v = [0.0, 0.0, 1.0]; end

        # Same continuation-marker shift as CBAR; see _bar_continuation_base.
        b = _bar_continuation_base(c)
        pa = to_id(parse_nastran_number(safe_get(c, b + 1), 0))
        pb = to_id(parse_nastran_number(safe_get(c, b + 2), 0))
        wa = [parse_nastran_number(safe_get(c, b + 3), 0.0), parse_nastran_number(safe_get(c, b + 4), 0.0), parse_nastran_number(safe_get(c, b + 5), 0.0)]
        wb = [parse_nastran_number(safe_get(c, b + 6), 0.0), parse_nastran_number(safe_get(c, b + 7), 0.0), parse_nastran_number(safe_get(c, b + 8), 0.0)]

        d[string(id)] = Dict("ID"=>id, "PID"=>pid, "GA"=>ga, "GB"=>gb, "V"=>v, "G0"=>g0, "PA"=>pa, "PB"=>pb, "WA"=>wa, "WB"=>wb, "TYPE"=>"CBEAM")
    end
    return d
end
