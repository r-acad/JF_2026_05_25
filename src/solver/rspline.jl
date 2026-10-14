# RSPLINE is an elastic interpolation tube, not a rigid or linear tie.
# The ordered path and D/L determine its minimum-energy deflection.  Its
# arbitrary elastic scale cancels in static condensation.  The conventional
# thin circular interpolation tube has I/A = D^2/8 and GJ = EI; these are
# interpolation constants, unrelated to the model's physical materials.

function _rspline_segment_stiffness(a, b, inertia)
    dx = b - a
    L = norm(dx)
    isfinite(L) && L > 0 || throw(ArgumentError("RSPLINE has a zero-length or nonfinite path segment"))
    e1 = dx / L
    seed = abs(e1[3]) < 0.9 ? [0., 0., 1.] : [0., 1., 0.]
    e2 = normalize(cross(seed, e1))
    R = vcat(e1', e2', cross(e1, e2)')
    T = kron(Matrix{Float64}(I, 4, 4), R)
    K = zeros(12, 12)
    K[[1, 7], [1, 7]] = [1. -1.; -1. 1.] / L
    K[[4, 10], [4, 10]] = (inertia / L) * [1. -1.; -1. 1.]
    B = (inertia / L^3) * [12. 6L -12. 6L;
                              6L 4L^2 -6L 2L^2;
                             -12. -6L 12. -6L;
                              6L 2L^2 -6L 4L^2]
    K[[2, 6, 8, 12], [2, 6, 8, 12]] = B
    signs = Diagonal([1., -1., 1., -1.])
    K[[3, 5, 9, 11], [3, 5, 9, 11]] = signs * B * signs
    return T' * K * T
end

"""
    _rspline_interpolation(coords, independent, diameter_ratio)

Return `(map, dependent_positions)` in BASIC components. Every non-independent
path station is condensed with all six tube DOFs, even when only some of its
components are subsequently constrained. Interior independent stations retain
all six DOFs. The tube follows all path segments, including folds and offsets.
Coordinates are normalized before condensation for length-unit independence.
"""
function _rspline_interpolation(coords::AbstractMatrix, independent, diameter_ratio)
    n = size(coords, 1)
    size(coords, 2) == 3 && n >= 2 || throw(ArgumentError("RSPLINE needs an ordered path of at least two three-dimensional points"))
    all(isfinite, coords) || throw(ArgumentError("RSPLINE coordinates must be finite"))
    isfinite(diameter_ratio) && diameter_ratio > 0 || throw(ArgumentError("RSPLINE D/L must be finite and positive"))
    ind = Int.(independent)
    issorted(ind) && length(unique(ind)) == length(ind) && !isempty(ind) &&
        first(ind) == 1 && last(ind) == n ||
        throw(ArgumentError("RSPLINE independent positions must be ordered and include both path endpoints"))
    dep = setdiff(1:n, ind)
    isempty(dep) && return zeros(0, 6length(ind)), dep
    # Distinct GRID IDs can occupy the same consecutive tube station. The
    # exact zero-length elastic limit equates their six physical DOFs. Merge
    # such stations before condensation rather than adding an artificial
    # short segment. Two independent coincident stations would prescribe
    # incompatible arbitrary states and are rejected explicitly.
    groups = ones(Int, n)
    representatives = [1]
    for i in 2:n
        if coords[i, :] != coords[i-1, :]
            push!(representatives, i)
        end
        groups[i] = length(representatives)
    end
    if length(representatives) != n
        compact_ind = groups[ind]
        length(unique(compact_ind)) == length(compact_ind) ||
            throw(ArgumentError("RSPLINE has coincident independent stations with incompatible arbitrary DOFs"))
        compact_M, compact_dep = _rspline_interpolation(coords[representatives, :], compact_ind, diameter_ratio)
        M = zeros(6length(dep), 6length(ind))
        for (j, p) in enumerate(dep)
            independent_column = findfirst(==(groups[p]), compact_ind)
            r = 6(j-1)+1:6j
            if independent_column !== nothing
                k = independent_column
                M[r, 6(k-1)+1:6k] = Matrix{Float64}(I, 6, 6)
            else
                k = findfirst(==(groups[p]), compact_dep)
                M[r, :] = compact_M[6(k-1)+1:6k, :]
            end
        end
        return M, dep
    end
    L = sum(norm(coords[i+1, :] - coords[i, :]) for i in 1:n-1)
    isfinite(L) && L > 0 || throw(ArgumentError("RSPLINE path length must be finite and positive"))
    x = (coords .- coords[1:1, :]) / L
    inertia = Float64(diameter_ratio)^2 / 8
    isfinite(inertia) && inertia > 0 || throw(ArgumentError("RSPLINE D/L is outside the representable positive range"))
    K = zeros(6n, 6n)
    for i in 1:n-1
        dofs = 6(i-1)+1:6(i+1)
        K[dofs, dofs] += _rspline_segment_stiffness(x[i, :], x[i+1, :], inertia)
    end
    idofs = [6(i-1)+c for i in ind for c in 1:6]
    ddofs = [6(i-1)+c for i in dep for c in 1:6]
    Kdd = K[ddofs, ddofs]
    # Congruent diagonal equilibration improves the thin-tube solve without
    # adding stiffness, regularization, or changing its nullspace.
    scale = 1 ./ sqrt.(diag(Kdd))
    all(isfinite, scale) || throw(ArgumentError("RSPLINE interpolation tube has singular internal stiffness"))
    S = Diagonal(scale)
    M = -S * (cholesky(Symmetric(S * Kdd * S)) \ (S * K[ddofs, idofs]))
    # The normalized unknown is (u/L, theta); return dimensional (u, theta).
    ds = [c <= 3 ? L : 1. for _ in dep for c in 1:6]
    is = [c <= 3 ? L : 1. for _ in ind for c in 1:6]
    return Diagonal(ds) * M * Diagonal(1 ./ is), dep
end

function _rspline_constraint_rows(rsp, id, id_map, node_coords, node_R)
    label = "RSPLINE $id"
    haskey(rsp, "GRIDS") && haskey(rsp, "COMPONENTS") ||
        throw(ArgumentError("$label needs ordered GRIDS and COMPONENTS metadata; reimport legacy models to retain the Gi/Ci path"))
    grids = Int.(rsp["GRIDS"])
    comps = rsp["COMPONENTS"]
    length(grids) == length(comps) || throw(ArgumentError("$label GRIDS and COMPONENTS lengths differ"))
    length(unique(grids)) == length(grids) || throw(ArgumentError("$label repeats a GRID in its path"))
    indices = [_constraint_grid_index(id_map, g, label) for g in grids]
    # Zero denotes a blank Ci: this whole station is independent.
    ind = findall(c -> c == 0 || c == "" || c === nothing, comps)
    M, dep = _rspline_interpolation(node_coords[indices, :], ind, Float64(get(rsp, "DL", 0.1)))
    result = Dict{Int,Vector{Tuple{Int,Float64}}}()
    for (j, p) in enumerate(dep)
        Ri = node_R[indices[p]]
        rows = _constraint_grid_components(comps[p], label)
        for (k, q) in enumerate(ind), a in (1:3, 4:6), b in (1:3, 4:6)
            blockrows = 6(j-1) .+ a
            blockcols = 6(k-1) .+ b
            M[blockrows, blockcols] = Ri' * M[blockrows, blockcols] * node_R[indices[q]]
        end
        for c in rows
            pairs = Tuple{Int,Float64}[]
            for (k, q) in enumerate(ind), b in 1:6
                value = M[6(j-1)+c, 6(k-1)+b]
                # Retain every nonzero coefficient: a dimensional absolute
                # cutoff would make interpolation depend on the length unit.
                iszero(value) || push!(pairs, (6(indices[q]-1)+b, value))
            end
            result[6(indices[p]-1)+c] = pairs
        end
    end
    return result
end
