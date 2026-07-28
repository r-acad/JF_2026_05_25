# sol105_options.jl
#
# Typed SOL105 options object.
#
# The long-term direction is to move SOL105 away from scattered ENV reads and
# toward an explicit, reproducible options object. The buckling filters now
# consume this object directly; lower-level formulation switches are still
# being migrated in small, parity-safe steps.
#
# Backwards compatible: when no options are passed, callers can use
# `SOL105Options()` (= `from_env()`) which populates from the current ENV
# reads and exactly reproduces today's behavior. Python-driven optimization
# loops can build a SOL105Options once and pass it through every solve.
#
# This object intentionally mirrors `SOL105_CALIBRATED_CONSTANTS` so the two
# stay synchronized; the values default to the calibrated constants and the
# `from_env` constructor honors ENV overrides at the same keys.
#
# Migration policy: new code paths should accept this object directly. Existing
# low-level ENV switches remain available until their call sites are migrated.

"""
    SOL105Options

Typed bag of every option that drives the SOL 105 buckling pipeline. Built
from `SOL105Options()` (= `from_env()`) by default, or constructed
explicitly to override one or more fields.

Fields are grouped by concern:

  Filters
    raw_output                       bypass both localization + cluster filters
    cluster_filter_enabled           opt-in spectral-gap skip for known low-mode clutter
    cluster_filter_ratio             spectral-gap ratio (default 1.25)

  MITC4+phi2 shear formulation
    phi2_alpha                       global alpha in `min(1, alpha*h^2/L^2)`; default 10.0

  MacNeal RBF shear
    macneal_rbf_zb_scale             Zb residual-bending-flexibility scale; default 0.65
    macneal_warp_tol                 max warp_ratio for MacNeal eligibility; default 1e-4
    macneal_pcomp_thick_h_over_l_min h/L threshold for the thick+low-aspect route
    macneal_pcomp_thick_aspect_max   aspect upper threshold for the thick+low-aspect route
    macneal_pcomp_thick_kappa_l_min  optional kappa_L lower threshold for the thick route
    macneal_pcomp_thick_h_min        optional absolute-thickness lower threshold for the thick route

  AUTOSPC
    autospc_trans_rel                relative threshold for translational DOFs; default 1e-8
    autospc_rot_rel                  same for rotational; default 1e-8

  Other
    k6rot                            drilling DOF stiffness coefficient; default 100.0

These map 1:1 to entries in `SOL105_CALIBRATED_CONSTANTS`.
"""
struct SOL105Options
    # Filters
    raw_output::Bool
    cluster_filter_enabled::Bool
    cluster_filter_ratio::Float64
    # MITC4+phi2 shear
    phi2_alpha::Float64
    # MacNeal RBF
    macneal_rbf_zb_scale::Float64
    macneal_warp_tol::Float64
    macneal_pcomp_thick_h_over_l_min::Float64
    macneal_pcomp_thick_aspect_max::Float64
    macneal_pcomp_thick_kappa_l_min::Float64
    macneal_pcomp_thick_h_min::Float64
    # AUTOSPC
    autospc_trans_rel::Float64
    autospc_rot_rel::Float64
    # Other
    k6rot::Float64
end


# Helpers: central env parsing matching what the current call sites do.

function _env_bool(name::String, default::Bool)
    raw = lowercase(strip(get(ENV, name, "")))
    isempty(raw) && return default
    return raw in ("1", "true", "yes", "on")
end

function _env_float(name::String, default::Float64)
    raw = strip(get(ENV, name, ""))
    isempty(raw) && return default
    v = tryparse(Float64, raw)
    return v === nothing ? default : v
end


"""
    from_env() -> SOL105Options

Build a SOL105Options exactly matching the current ENV-driven behavior.
Equivalent to calling `SOL105Options()` (= the no-arg constructor).
"""
function from_env()
    return SOL105Options(
        # Filters
        _env_bool("JFEM_BUCKLING_RAW_OUTPUT", false),
        _env_bool("JFEM_BUCKLING_CLUSTER_FILTER", false),
        _env_float("JFEM_BUCKLING_CLUSTER_FILTER_RATIO", 1.25),
        # phi2
        10.0,  # phi2_alpha: currently a module Ref (FEM.PHI2_ALPHA), not env-driven
        # MacNeal
        _env_float("JFEM_Q4_MACNEAL_RBF_ZB_SCALE", 1.28),
        # 2026-07-27: raised (see assembly.jl for the measurement notes) —
        # the old bound sat orders of magnitude below any physical mesh scale.
        _env_float("JFEM_Q4_MACNEAL_WARP_TOL", 1e-2),
        _env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_H_OVER_L_MIN", 0.015),
        _env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_ASPECT_MAX", 3.5),
        _env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_KAPPA_L_MIN", 0.0),
        _env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_H_MIN", 0.0),
        # AUTOSPC
        _env_float("JFEM_AUTOSPC_TRANS_REL", 1e-8),
        _env_float("JFEM_AUTOSPC_ROT_REL", 1e-8),
        # Other
        _env_float("JFEM_PARAM_K6ROT", 100.0),
    )
end

"""
    SOL105Options() -> SOL105Options

Default constructor that calls `from_env()`. Lets callers write
`SOL105Options()` for the default behavior and `SOL105Options(...)` for
explicit overrides via positional args.
"""
SOL105Options() = from_env()

"""
    summary(opts::SOL105Options, io::IO=stdout)

Pretty-print the options for debugging/log inclusion. Used as a
reproducibility footer in long-running optimization runs.
"""
function summary(opts::SOL105Options, io::IO=stdout)
    println(io, "SOL105Options:")
    for fn in fieldnames(SOL105Options)
        println(io, "  $fn = $(getfield(opts, fn))")
    end
end
