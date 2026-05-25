# buckling_result.jl
#
# Structured SOL 105 buckling result types — one BucklingSubcaseResult per
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
# Both `reported_*` (post-filter, what JFEM publishes today) and `raw_*`
# (pre-filter, what the eigensolver actually returned) are stored when the
# raw output flag is set; otherwise raw_* == reported_*. `filter_decisions`
# documents per-raw-mode why each mode was kept or dropped.
#
# The container is held as `results["buckling"]` in the top-level results
# dict. Legacy keys ("eigenvalues", "_raw_mode_shapes", "Kg", "K_eig",
# "u_static", "fixed_dofs") remain populated for backwards compatibility,
# but they now reflect only the LAST subcase as before — production scripts
# should migrate to the structured API.

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
  reported_mode_shapes  ndof × n_reported, post-filter shapes
  raw_eigenvalues       pre-filter eigenvalues (only populated when raw mode is on)
  raw_mode_shapes       ndof × n_raw, pre-filter shapes (raw mode only)
  filter_decisions      Vector{Symbol}, length = n_raw; values like
                        :kept | :dropped_localization | :dropped_cluster |
                        :dropped_nonpositive | :dropped_outofrange
  K_eig                 the eigen-K passed to the eigensolver
  Kg                    the geometric stiffness for this subcase
  u_static              the static displacement field used to assemble Kg
  fixed_dofs            SPC-constrained DOF index set
  eigrl                 NamedTuple (v1, v2, nd) from the EIGRL card
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
    eigrl::NamedTuple{(:v1, :v2, :nd), Tuple{Float64,Float64,Int}}
    solver_backend::String
    timings::Dict{String,Float64}
    details::Dict{String,Any}
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
implies BOTH `JFEM_BUCKLING_LOCALIZATION_FILTER=false` and
`JFEM_BUCKLING_CLUSTER_FILTER=false`. Replaces the two-knob pattern from
prior diagnostic scripts.

Returns true if the raw output is requested. Caller should treat this as
overriding the two individual filter knobs.
"""
function buckling_raw_output_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_BUCKLING_RAW_OUTPUT", "")))
    return raw in ("1", "true", "yes", "on")
end
