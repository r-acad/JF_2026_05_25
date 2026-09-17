# buckling_result.jl
#
# Structured SOL 105 buckling result types: one BucklingSubcaseResult per
# buckling subcase, aggregated into a BucklingResult. Replaces the prior
# pattern in _solve_sol105 of flattening all subcases' eigenvalues and mode
# shapes into single global arrays and retaining only the LAST subcase's K,
# Kg, u_static, and fixed_dofs.
#
# Motivation (architectural review 2026-05-24):
#   * Off-line MAC / Rayleigh-quotient parity needs per-subcase Kg.
#   * Filter trace must be observable for downstream diagnostics.
#   * Reports, HDF5 export, and substitution probes shouldn't have to
#     reconstruct subcase identity from flat arrays.
#
# `raw_*` currently mirrors the reported pairs, sharing their storage. The
# solver does not expand discarded candidate vectors. Candidate-only values
# and filter verdicts live in details["candidate_eigenvalues"] and
# details["candidate_filter_decisions"], separately from paired results.
#
# The container is held as `results["buckling"]` in the top-level results
# dict. Legacy keys ("eigenvalues", "_raw_mode_shapes", "Kg", "K_eig",
# "u_static", "fixed_dofs") remain populated for backwards compatibility,
# with flat eigenvalues/modes sorted across all subcases, while matrices and
# preload fields reflect only the LAST subcase. Use the structured API for
# calculations that combine modes and preload states.

"""
    BucklingSubcaseResult

One SOL 105 buckling subcase's complete result, including the per-subcase
matrices (K_eig, Kg) and static preload state (u_static, fixed_dofs) that
are needed for off-line MAC / Rayleigh-quotient parity analysis and for
substitution probes.

Fields:
  buckling_subcase_id   the BUCKLING SUBCASE id (e.g. 511002)
  static_subcase_id     the STATSUB id (e.g. 111002)
  reported_eigenvalues  post-filter eigenvalues (what the public API exposes)
  reported_mode_shapes  ndof x n_reported, post-filter shapes
  raw_eigenvalues       paired eigenvalues; currently the reported mirror
  raw_mode_shapes       ndof x n_raw, aligned with raw_eigenvalues
  filter_decisions      Vector{Symbol}, length = n_raw; currently all :kept
  K_eig                 the eigen-K passed to the eigensolver
  Kg                    the geometric stiffness for this subcase
  u_static              the static displacement field used to assemble Kg
  fixed_dofs            SPC-constrained DOF index set
  eigrl                 NamedTuple carrying bounds/count compatibility values,
                        blank-field flags, source card, METHOD id, and whether
                        the input requests every root in range. For EIGB the
                        numeric nd is only a compatibility count; authoritative
                        signed quotas and original NEP/NDP/NDN presence live in
                        details["eigenvalue_extraction"]. NEP is not an ND.
  solver_backend        which eigensolver actually ran
  timings               per-phase wall seconds
  details               full diagnostics dict from solve_buckling (legacy)
"""
struct BucklingSubcaseResult
    buckling_subcase_id::Int
    static_subcase_id::Int
    reported_eigenvalues::Vector{Float64}
    reported_mode_shapes::Matrix{Float64}
    raw_eigenvalues::Vector{Float64}
    raw_mode_shapes::Matrix{Float64}
    filter_decisions::Vector{Symbol}
    K_eig::Any
    Kg::Any
    u_static::Vector{Float64}
    fixed_dofs::Set{Int}
    eigrl::NamedTuple{
        (:v1, :v2, :nd, :v1_specified, :v2_specified, :nd_specified,
         :source, :method_id, :request_all_in_range),
        Tuple{Float64,Float64,Int,Bool,Bool,Bool,String,Int,Bool}}
    solver_backend::String
    timings::Dict{String,Float64}
    details::Dict{String,Any}
end

# Backward-compatible constructor for callers that created the public result
# container directly with the original `(v1, v2, nd)` metadata tuple. The
# richer tuple is additive for solver-produced results; legacy construction
# retains the pre-2026-09 assumption that ND was explicit.
function BucklingSubcaseResult(
    buckling_subcase_id,
    static_subcase_id,
    reported_eigenvalues,
    reported_mode_shapes,
    raw_eigenvalues,
    raw_mode_shapes,
    filter_decisions,
    K_eig,
    Kg,
    u_static,
    fixed_dofs,
    eigrl::NamedTuple{(:v1, :v2, :nd)},
    solver_backend,
    timings,
    details,
)
    expanded_eigrl = (
        v1=Float64(eigrl.v1),
        v2=Float64(eigrl.v2),
        nd=Int(eigrl.nd),
        v1_specified=Float64(eigrl.v1) != 0.0,
        v2_specified=Float64(eigrl.v2) != 0.0,
        nd_specified=true,
        source="EIGRL",
        method_id=0,
        request_all_in_range=false,
    )
    return BucklingSubcaseResult(
        buckling_subcase_id, static_subcase_id,
        reported_eigenvalues, reported_mode_shapes,
        raw_eigenvalues, raw_mode_shapes, filter_decisions,
        K_eig, Kg, u_static, fixed_dofs, expanded_eigrl,
        solver_backend, timings, details,
    )
end

"""
    BucklingResult

Aggregator: ordered Vector{BucklingSubcaseResult} indexed by buckling
subcase id. Use `result_for(br, sid)` to fetch by id.
"""
struct BucklingResult
    subcases::Vector{BucklingSubcaseResult}
end

"""
    result_for(br::BucklingResult, sid::Int) -> Union{BucklingSubcaseResult, Nothing}

Lookup helper by buckling subcase id.
"""
function result_for(br::BucklingResult, sid::Int)
    for sc in br.subcases
        sc.buckling_subcase_id == sid && return sc
    end
    return nothing
end

"""
    buckling_raw_output_enabled() -> Bool

Single env knob `JFEM_BUCKLING_RAW_OUTPUT` that, when set to a truthy value,
implies `JFEM_BUCKLING_CLUSTER_FILTER=false`. Replaces the two-knob pattern
from prior diagnostic scripts.

Returns true if the raw output is requested. Caller should treat this as
overriding the cluster-filter knob.
"""
function buckling_raw_output_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_BUCKLING_RAW_OUTPUT", "")))
    return raw in ("1", "true", "yes", "on")
end

function buckling_raw_output_enabled(opts)
    opts === nothing && return buckling_raw_output_enabled()
    return getfield(opts, :raw_output) === true
end
