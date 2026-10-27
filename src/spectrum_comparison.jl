"""Comparison of real spectra and modal subspaces without relying on output order."""
module SpectrumComparison

using LinearAlgebra
export compare_eigenvalue_spectra, compare_eigenspaces, eigenpair_diagnostics

function _nonnegative(name, value)
    isfinite(value) && value >= 0 || throw(ArgumentError("$name must be finite and nonnegative"))
    converted = Float64(value)
    isfinite(converted) && (value == 0 || converted != 0) ||
        throw(ArgumentError("$name must be representable as finite non-underflowing Float64"))
    converted
end

function _roots(values, lower, upper)
    kept = Tuple{Int,Float64}[]
    excluded = Dict{String,Any}[]
    invalid = Dict{String,Any}[]
    for (i, raw) in enumerate(values)
        if raw isa Bool || !(raw isa Number) || !isreal(raw) || !isfinite(raw)
            push!(invalid, Dict("index"=>i, "value"=>string(raw), "reason"=>"nonfinite_or_nonreal"))
            continue
        end
        value = Float64(real(raw))
        if !isfinite(value)
            push!(invalid, Dict("index"=>i, "value"=>string(raw), "reason"=>"not_representable_as_float64"))
        elseif real(raw) != value
            push!(invalid, Dict("index"=>i, "value"=>string(raw), "reason"=>"precision_loss_converting_to_float64"))
        elseif (lower !== nothing && value < lower) || (upper !== nothing && value > upper)
            push!(excluded, Dict("index"=>i, "value"=>value, "reason"=>"outside_explicit_interval"))
        else
            push!(kept, (i, value))
        end
    end
    kept, excluded, invalid
end

# Maximum-cardinality bipartite matching. Admissibility is separate from cost:
# infinite cost still represents a numerical gap between compatible root signs.
function _assignment(costs, admissible, ceiling; strict=false)
    nr, nc = size(costs)
    owner = zeros(Int, nc)
    order = [sortperm(1:nc; by=j -> (costs[i,j],abs(i-j),j)) for i in 1:nr]
    function augment(i, visited)
        for j in order[i]
            if !visited[j] && admissible[i,j] &&
                    (strict ? costs[i,j] < ceiling : costs[i,j] <= ceiling)
                visited[j] = true
                if owner[j] == 0 || augment(owner[j], visited)
                    owner[j] = i
                    return true
                end
            end
        end
        false
    end
    for i in 1:nr
        augment(i, falses(nc))
    end
    sort!([(owner[j], j) for j in 1:nc if owner[j] != 0]; by=first)
end

function _bottleneck(costs, admissible)
    complete = _assignment(costs, admissible, Inf)
    isempty(complete) && return complete
    levels = sort!(unique(costs[admissible]))
    lo, hi = 1, length(levels)
    while lo < hi
        mid = (lo + hi) >>> 1
        if length(_assignment(costs, admissible, levels[mid])) == length(complete)
            hi = mid
        else
            lo = mid + 1
        end
    end
    _assignment(costs, admissible, levels[lo])
end

_signclass(x, zero_tolerance) = abs(x) <= zero_tolerance ? 0 : (x < 0 ? -1 : 1)

function _match_rows(pairs, reference, candidate, costs)
    rows = Dict{String,Any}[]
    for (i,j) in pairs
        a,b = reference[i][2],candidate[j][2]
        absolute_error = abs(a-b)
        relative_error = a == 0 ? (b == 0 ? 0.0 : Inf) :
            isfinite(absolute_error) ? absolute_error/abs(a) : abs(1-b/a)
        push!(rows,Dict{String,Any}(
        "reference_index"=>reference[i][1], "candidate_index"=>candidate[j][1],
        "reference"=>a, "candidate"=>b,
        "absolute_error"=>isfinite(absolute_error) ? absolute_error : nothing,
        "relative_error"=>isfinite(relative_error) ? relative_error : nothing,
        "relative_error_unbounded_or_overflowed"=>!isfinite(relative_error),
        "normalized_error"=>isfinite(costs[i,j]) ? costs[i,j] : nothing,
        "within_tolerance"=>costs[i,j] < 1.0))
    end
    rows
end

"""
    compare_eigenvalue_spectra(reference, candidate; relative_tolerance=0.005,
        absolute_tolerance=0, zero_tolerance=0, lower=nothing, upper=nothing)

Compare real eigenvalues as signed multisets. Keep every repeated root and its
original index. A deterministic maximum-cardinality, minimum-bottleneck
assignment pairs roots without assuming their order or using mode-shape MAC.
The independent `within_tolerance_matches` is a maximum-cardinality assignment
under the strict test `abs(candidate-reference) < absolute_tolerance +
relative_tolerance*abs(reference)`; exact equality always passes.

Values must be exactly representable as Float64 and use the same quantity and
units (SOL103 eigenvalues are squared
angular frequencies, not Hz). Both sides must have the same extraction request.
An explicit inclusive interval filters both sides and records every exclusion;
it never establishes that either spectrum is complete. No implicit sign filter,
large-root cutoff, rounding or multiplicity reduction is applied. Nonfinite or
nonreal entries prevent a pass. Exact zero is its own sign class by default;
use a dimensioned `zero_tolerance` only with independent rigid-mode evidence,
and an explicit `absolute_tolerance` to compare those near-zero values.

`pass` certifies only agreement of the supplied finite roots. It cannot certify
interval completeness, matching operators, mode shapes or physical correctness.
"""
function compare_eigenvalue_spectra(reference, candidate;
        relative_tolerance=0.005, absolute_tolerance=0.0, zero_tolerance=0.0,
        lower=nothing, upper=nothing)
    rtol = _nonnegative("relative_tolerance", relative_tolerance)
    atol = _nonnegative("absolute_tolerance", absolute_tolerance)
    ztol = _nonnegative("zero_tolerance", zero_tolerance)
    function bound(name,value)
        value === nothing && return nothing
        converted = Float64(value)
        isfinite(converted) && value == converted ||
            throw(ArgumentError("$name must be exactly representable as finite Float64"))
        converted
    end
    lower = bound("lower",lower)
    upper = bound("upper",upper)
    lower !== nothing && !isfinite(lower) && throw(ArgumentError("lower must be finite or nothing"))
    upper !== nothing && !isfinite(upper) && throw(ArgumentError("upper must be finite or nothing"))
    lower !== nothing && upper !== nothing && lower > upper && throw(ArgumentError("lower exceeds upper"))
    refs, rexcluded, rinvalid = _roots(reference, lower, upper)
    cands, cexcluded, cinvalid = _roots(candidate, lower, upper)
    nr, nc = length(refs), length(cands)
    costs = fill(Inf, nr, nc)
    admissible = falses(nr,nc)
    for i in 1:nr, j in 1:nc
        a, b = refs[i][2], cands[j][2]
        admissible[i,j] = _signclass(a,ztol) == _signclass(b,ztol)
        delta = abs(a-b)
        budget = atol + rtol*abs(a)
        # Preserve the strict boundary test in ordinary arithmetic. Rescale
        # only when a finite pair would overflow its difference or budget.
        if !isfinite(delta) || !isfinite(budget)
            scale = max(abs(a), abs(b))
            delta = abs(a/scale-b/scale)
            budget = atol/scale + rtol*(abs(a)/scale)
        end
        costs[i,j] = a == b ? 0.0 : (budget == 0 ? Inf : delta/budget)
    end
    pairs = _bottleneck(costs, admissible)
    tolerant_pairs = _assignment(costs, admissible, 1.0; strict=true)
    rows = _match_rows(pairs, refs, cands, costs)
    tolerant_rows = _match_rows(tolerant_pairs, refs, cands, costs)
    usedr = Set(first.(pairs)); usedc = Set(last.(pairs))
    tr = Set(first.(tolerant_pairs)); tc = Set(last.(tolerant_pairs))
    unmatched(roots, used) = [Dict("index"=>i, "value"=>x) for (k,(i,x)) in enumerate(roots) if !(k in used)]
    invalid = !isempty(rinvalid) || !isempty(cinvalid)
    coverage = length(pairs) == nr == nc
    agreement = coverage && length(tolerant_pairs) == nr
    passed = !invalid && nr > 0 && agreement
    status = invalid ? "invalid_data" : nr == nc == 0 ? "empty_spectra" :
        !coverage ? "coverage_or_sign_gap" : !agreement ? "numerical_gap" : "pass"
    Dict{String,Any}(
        "schema"=>"OpenJFEM.spectrum-comparison.v1", "pass"=>passed, "status"=>status,
        "reference_count"=>length(reference), "candidate_count"=>length(candidate),
        "eligible_reference_count"=>nr, "eligible_candidate_count"=>nc,
        "relative_tolerance"=>rtol, "absolute_tolerance"=>atol, "zero_tolerance"=>ztol,
        "interval"=>Dict("lower"=>lower, "upper"=>upper),
        "matches"=>rows, "within_tolerance_matches"=>tolerant_rows,
        "unmatched_reference"=>unmatched(refs,usedr), "unmatched_candidate"=>unmatched(cands,usedc),
        "outside_tolerance_reference"=>unmatched(refs,tr), "outside_tolerance_candidate"=>unmatched(cands,tc),
        "excluded_reference"=>rexcluded, "excluded_candidate"=>cexcluded,
        "invalid_reference"=>rinvalid, "invalid_candidate"=>cinvalid,
        "ordering_changed"=>coverage && any(i != j for (i,j) in pairs),
        "completeness"=>"not_certified_by_root_lists")
end

function _whiten_modes(vectors, metric)
    V = Matrix{Float64}(vectors)
    all(isfinite,V) || throw(ArgumentError("mode vectors must be finite and real"))
    _normalize_columns!(V)
    if metric !== nothing
        size(metric) == (size(V,1),size(V,1)) || throw(DimensionMismatch("metric and mode DOFs differ"))
        issymmetric(metric) || throw(ArgumentError("mode metric must be symmetric positive definite"))
        V = cholesky(Symmetric(metric)).U * V
    end
    all(isfinite,V) || throw(ArgumentError("metric transformation overflowed"))
    _normalize_columns!(V)
    V
end

function _normalize_columns!(V)
    for j in axes(V,2)
        largest = maximum(abs,view(V,:,j);init=0.0)
        if largest > 0
            V[:,j] ./= largest
            V[:,j] ./= norm(view(V,:,j))
        end
    end
    V
end

function _basis(V, rtol)
    isempty(V) && return zeros(size(V,1),0), 0
    F = svd(V; full=false)
    rank = count(s -> s > rtol*maximum(F.S), F.S)
    F.U[:,1:rank], rank
end

"""
    compare_eigenspaces(reference_vectors, candidate_vectors;
        metric=nothing, rank_tolerance=1e-10, angle_tolerance=1e-6)

Compare two bases of one spectral cluster using principal angles and rank.
Columns are modes in an identical physical DOF order. Sign, normalization,
ordering and rotation within a repeated eigenspace do not affect the result.
Different operators, DOF sets or nonmatching spectral clusters must be resolved
by the caller first. `angle_tolerance` bounds the sine of the largest angle.
An optional symmetric positive-definite metric supplies the physical inner
product; indefinite metrics are rejected. Rank loss or different multiplicities
prevents a pass even when the smaller space lies inside the larger one.
Singular mass matrices are not an admissible full-space metric: a separately
validated finite-mode coordinate representation is required first. If ND cuts
through a repeated cluster, two valid partial bases may span different subsets;
that requires a larger extraction, rather than calling it a formulation error.
"""
function compare_eigenspaces(reference_vectors, candidate_vectors;
        metric=nothing, rank_tolerance=1e-10, angle_tolerance=1e-6)
    size(reference_vectors,1) == size(candidate_vectors,1) || throw(DimensionMismatch("mode DOF rows differ"))
    ranktol = _nonnegative("rank_tolerance",rank_tolerance)
    angletol = _nonnegative("angle_tolerance",angle_tolerance)
    ranktol < 1 || throw(ArgumentError("rank_tolerance must be less than one"))
    angletol <= 1 || throw(ArgumentError("angle_tolerance must not exceed one"))
    A = _whiten_modes(reference_vectors,metric)
    B = _whiten_modes(candidate_vectors,metric)
    QA, ra = _basis(A,ranktol); QB, rb = _basis(B,ranktol)
    cosines = ra == 0 || rb == 0 ? Float64[] : clamp.(svdvals(QA'QB),0.0,1.0)
    defect = ra == rb == 0 ? 0.0 : ra == 0 || rb == 0 ? 1.0 :
        max(opnorm(QA-QB*(QB'QA)),opnorm(QB-QA*(QA'QB)))
    independent = ra == size(A,2) && rb == size(B,2)
    passed = ra > 0 && ra == rb && independent && defect <= angletol
    Dict{String,Any}("pass"=>passed,"reference_rank"=>ra,"candidate_rank"=>rb,
        "reference_multiplicity"=>size(A,2),"candidate_multiplicity"=>size(B,2),
        "principal_angles_radians"=>acos.(cosines), "maximum_sine_angle"=>defect,
        "independent_modes"=>independent,"metric"=>metric === nothing ? "euclidean" : "positive_definite")
end

"""
    eigenpair_diagnostics(A, B, values, vectors; residual_tolerance=1e-6)

Check each finite real pair against the original pencil `A*u = lambda*B*u`,
Report the action-relative residual and a backward residual with denominator
`norm(abs(A)*abs(u)+abs(lambda)*abs(B)*abs(u))`. The latter handles rotated rigid
modes where A*u is entirely roundoff; it controls acceptance. Rescale the pencil
and both actions to avoid overflow. A common-nullspace vector has an
indeterminate eigenvalue and is not accepted. Small residuals do not prove
eigenvalue accuracy for an ill-conditioned pencil or completeness.
"""
function eigenpair_diagnostics(A,B,values,vectors; residual_tolerance=1e-6)
    size(A) == size(B) || throw(DimensionMismatch("pencil matrices differ"))
    size(A,1) == size(A,2) == size(vectors,1) || throw(DimensionMismatch("pencil and mode DOFs differ"))
    length(values) == size(vectors,2) || throw(DimensionMismatch("root and mode counts differ"))
    tolerance = _nonnegative("residual_tolerance",residual_tolerance)
    all(isfinite,A) && all(isfinite,B) || throw(ArgumentError("pencil matrices must be finite"))
    sa = maximum(abs,A;init=0.0); sb = maximum(abs,B;init=0.0)
    An = sa == 0 ? A : A/sa; Bn = sb == 0 ? B : B/sb
    absA = abs.(An); absB = abs.(Bn)
    rows = Dict{String,Any}[]
    for (i,lambda) in enumerate(values)
        u = vectors[:,i]
        if !(lambda isa Real) || !isfinite(lambda) || !all(isfinite,u) || maximum(abs,u;init=0.0) == 0
            push!(rows,Dict("index"=>i,"pass"=>false,"reason"=>"invalid_eigenpair","relative_residual"=>nothing))
            continue
        end
        u = u/maximum(abs,u); u /= norm(u)
        Au = An*u; Bu = Bn*u
        action_bound_a = absA*abs.(u); action_bound_b = absB*abs.(u)
        gamma = (2*length(u)+2)*eps(Float64)
        gamma = gamma < 1 ? gamma/(1-gamma) : Inf
        resolved_a = norm(Au) > gamma*norm(action_bound_a)
        resolved_b = norm(Bu) > gamma*norm(action_bound_b)
        common_nullspace = !resolved_a && !resolved_b
        # frexp/ldexp avoids forming lambda*sb, which may overflow even when
        # both matrices and the root are finite. Only bounded weights result.
        ma,ea = sa == 0 ? (0.0,-10000) : frexp(sa)
        mb,eb = sb == 0 || lambda == 0 ? (0.0,-10000) : frexp(sb)
        ml,el = lambda == 0 ? (0.0,0) : frexp(abs(lambda))
        exponent = max(ea,eb+el)
        wa = ldexp(ma,ea-exponent); wb = ldexp(mb*ml,eb+el-exponent)
        defect = wa*Au-sign(lambda)*wb*Bu
        denominator = wa*norm(Au)+wb*norm(Bu)
        bound = norm(wa*action_bound_a+wb*action_bound_b)
        residual = common_nullspace ? Inf : denominator == 0 ? 0.0 : norm(defect)/denominator
        backward = common_nullspace ? Inf : bound == 0 ? 0.0 : norm(defect)/bound
        ok = resolved_b && isfinite(backward) && backward <= tolerance
        push!(rows,Dict("index"=>i,"pass"=>ok,
            "reason"=>common_nullspace ? "common_nullspace" : !resolved_b ? "unresolved_B_action" :
                ok ? "accepted" : "original_pencil_residual",
            "A_action_resolved"=>resolved_a,"B_action_resolved"=>resolved_b,
            "relative_residual"=>isfinite(residual) ? residual : nothing,
            "backward_residual"=>isfinite(backward) ? backward : nothing))
    end
    Dict{String,Any}("pass"=>!isempty(rows) && all(row["pass"] for row in rows),
        "pairs"=>rows,"residual_tolerance"=>tolerance,"completeness"=>"not_certified_by_residuals")
end

end # module SpectrumComparison
