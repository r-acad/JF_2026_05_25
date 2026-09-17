# Direct matrices are already expressed in GRID displacement coordinates.
# Select only a named K2GG/M2GG contribution; an unselected DMIG is inert.
function _direct_matrix_selector(raw, keyword)
    raw === nothing && return nothing
    value = uppercase(strip(string(raw)))
    value in ("", "NONE") && return nothing
    occursin(r"^[A-Z][A-Z0-9_]{0,7}$", value) ||
        throw(ArgumentError("$keyword supports a single DMIG name; selector '$value' is unsupported"))
    return value
end

function _selected_direct_matrix(model, keyword::String)
    cc = get(model, "CASE_CONTROL", Dict())
    selected = _direct_matrix_selector(get(cc, keyword, nothing), keyword)
    subcases = get(cc, "SUBCASES", Dict())
    first_subcase = true
    common = selected
    for subcase in values(subcases)
        effective = _direct_matrix_selector(get(subcase, keyword, selected), keyword)
        if first_subcase
            common = effective
            first_subcase = false
        elseif effective != common
            throw(ArgumentError("Different $keyword selections between subcases are unsupported by shared matrix assembly"))
        end
    end
    common === nothing && return nothing
    dmigs = get(model, "DMIGs", Dict())
    haskey(dmigs, common) || throw(ArgumentError("$keyword references missing DMIG $common"))
    return common, dmigs[common]
end

function append_direct_matrix_triplets!(rows, cols, vals, model, id_map; kind::Symbol=:stiffness)
    keyword = kind === :stiffness ? "K2GG" : kind === :mass ? "M2GG" :
        throw(ArgumentError("Unknown direct matrix kind: $kind"))
    selection = _selected_direct_matrix(model, keyword)
    selection === nothing && return 0
    name, matrix = selection
    form = get(matrix, "type", "square")
    form in ("symmetric", "square") || throw(ArgumentError("$keyword DMIG $name has unsupported type $form"))
    entries = get(matrix, "entries", [])
    # Validate before appending, so a bad GRID/DOF never partly modifies K/M.
    assembled = Dict{Tuple{Int,Int},Float64}()
    for (gi, ci, gj, cj, aij) in entries
        haskey(id_map, gi) && haskey(id_map, gj) ||
            throw(ArgumentError("$keyword DMIG $name references missing GRID $gi or $gj"))
        1 <= ci <= 6 && 1 <= cj <= 6 && isinteger(ci) && isinteger(cj) && isfinite(aij) ||
            throw(ArgumentError("$keyword DMIG $name has invalid components or nonfinite coefficient"))
        row = 6 * (id_map[gi] - 1) + Int(ci)
        col = 6 * (id_map[gj] - 1) + Int(cj)
        key = (row, col)
        assembled[key] = get(assembled, key, 0.0) + Float64(aij)
    end
    if form == "symmetric"
        for ((row, col), value) in assembled
            row == col && continue
            haskey(assembled, (col, row)) && throw(ArgumentError("$keyword DMIG $name supplies both triangles; symmetric DMIG input requires one triangle"))
        end
    else
        for ((row, col), value) in assembled
            reverse_value = get(assembled, (col, row), 0.0)
            isapprox(value, reverse_value; rtol=1e-12, atol=0.0) ||
                throw(ArgumentError("$keyword DMIG $name is nonsymmetric; this solver requires a symmetric matrix"))
        end
    end
    for ((row, col), value) in sort!(collect(assembled); by=first)
        push!(rows, row); push!(cols, col); push!(vals, value)
        if form == "symmetric" && row != col
            push!(rows, col); push!(cols, row); push!(vals, value)
        end
    end
    return length(entries)
end
