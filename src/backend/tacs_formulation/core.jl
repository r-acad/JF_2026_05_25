# core.jl -- TACS-formulation contracts used by the Julia solver core.
#
# This file provides a small typed layer for element kernels, constitutive
# kernels, response contracts, and sensitivity contracts. It is deliberately
# lightweight: the existing shell numerical kernels remain in sol101.jl, while
# this layer gives future beams, solids, loads, and coordinate sensitivities a
# common place to attach.

using LinearAlgebra
using StaticArrays

const TACS_LINEAR_SHELL_STIFFNESS_ROUTE = "residual_first_quad4_cquadr_tria3"
const TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE = "native_residual_first_quad4_cquadr_tria3"
const TACS_LINEAR_ROD_STIFFNESS_ROUTE = "residual_first_crod_conrod_sol101_sol103"
const TACS_LINEAR_BEAM_STIFFNESS_ROUTE = "residual_first_cbar_cbeam_sol101_sol103_sol105"
const TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE = "native_residual_first_cbar_cbeam_operator"

abstract type AbstractTACSCoreContract end
abstract type AbstractTACSElementKernel <: AbstractTACSCoreContract end
abstract type AbstractTACSConstitutiveKernel <: AbstractTACSCoreContract end
abstract type AbstractTACSResponseContract <: AbstractTACSCoreContract end
abstract type AbstractTACSResponseFunction <: AbstractTACSCoreContract end
abstract type AbstractTACSSensitivityContract <: AbstractTACSCoreContract end

struct TACSShellElementKernel <: AbstractTACSElementKernel
    family::Symbol
    card_type::String
    node_count::Int
    linear_stiffness_route::String
    geometric_stiffness_route::String
end

struct TACSRodElementKernel <: AbstractTACSElementKernel
    family::Symbol
    card_type::String
    node_count::Int
    linear_stiffness_route::String
    geometric_stiffness_route::String
end

struct TACSSpringElementKernel <: AbstractTACSElementKernel
    family::Symbol
    card_type::String
    node_count::Int
    linear_stiffness_route::String
    geometric_stiffness_route::String
end

struct TACSBeamElementKernel <: AbstractTACSElementKernel
    family::Symbol
    card_type::String
    node_count::Int
    linear_stiffness_route::String
    geometric_stiffness_route::String
end

struct TACSConstitutiveKernel <: AbstractTACSConstitutiveKernel
    family::Symbol
    property_type::String
    material_type::String
    design_variables::Tuple{Vararg{Symbol}}
end

struct TACSResponseContract <: AbstractTACSResponseContract
    family::Symbol
    analysis_family::Symbol
    derivative_forms::Tuple{Vararg{Symbol}}
end

struct TACSResponseFunction <: AbstractTACSResponseFunction
    contract::TACSResponseContract
    spec::Dict{String,Any}
end

struct TACSSensitivityContract <: AbstractTACSSensitivityContract
    response_family::Symbol
    design_family::Symbol
    derivative_method::Symbol
    coordinate_supported::Bool
end

struct TACSStaticResponseContext
    response::TACSResponseFunction
    model::AbstractDict
    u::Vector{Float64}
    K::AbstractMatrix
    id_map::Any
    X::Any
    node_R::Any
    ndof::Int
    fixed_dofs::Vector{Int}
    free_dofs::Vector{Int}
    subcase_index::Int
end

struct TACSBucklingResponseContext
    response::TACSResponseFunction
    mode::Int
    value::Float64
    phi::Vector{Float64}
    Kg::AbstractMatrix
    denominator::Float64
end

struct TACSModalResponseContext
    response::TACSResponseFunction
    mode::Int
    value::Float64
    frequency::Float64
    phi::Vector{Float64}
    K::AbstractMatrix
    M::AbstractMatrix
    denominator::Float64
end

struct TACSShellElementContext
    kernel::TACSShellElementKernel
    constitutive::TACSConstitutiveKernel
    element_id::Int
    property_id::Int
    node_ids::Vector{Int}
    node_indices::Vector{Int}
    local_coords::Matrix{Float64}
    v1::SVector{3,Float64}
    v2::SVector{3,Float64}
    v3::SVector{3,Float64}
    transform::Matrix{Float64}
    dofs::Vector{Int}
    property::AbstractDict
end

function _tacs_shell_element_family(card_type::AbstractString, node_count::Integer)
    ctype = uppercase(strip(string(card_type)))
    if node_count == 3
        return :tria3
    elseif node_count == 4 && ctype == "CQUADR"
        return :cquadr
    elseif node_count == 4
        return :cquad4
    end
    error("TACS-formulation shell kernel supports CQUAD4/CQUADR/CTRIA3 only; got $node_count nodes and TYPE=$ctype.")
end

function _tacs_shell_element_kernel(el::AbstractDict)
    node_count = length(get(el, "NODES", Any[]))
    card_type = uppercase(strip(string(get(el, "TYPE", node_count == 3 ? "CTRIA3" : "CQUAD4"))))
    family = _tacs_shell_element_family(card_type, node_count)
    return TACSShellElementKernel(
        family,
        card_type,
        Int(node_count),
        TACS_LINEAR_SHELL_STIFFNESS_ROUTE,
        TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE,
    )
end

function _tacs_rod_element_kernel(el::AbstractDict)
    card_type = uppercase(strip(string(get(el, "TYPE", "CROD"))))
    family =
        card_type == "CONROD" ? :conrod :
        card_type == "CROD" ? :crod :
        error("TACS-formulation rod kernel supports CROD/CONROD only; got TYPE=$card_type.")
    return TACSRodElementKernel(
        family,
        card_type,
        2,
        TACS_LINEAR_ROD_STIFFNESS_ROUTE,
        "not_implemented",
    )
end

function _tacs_spring_element_kernel(el::AbstractDict)
    card_type = uppercase(strip(string(get(el, "TYPE", "CELAS1"))))
    family =
        card_type == "CBUSH" ? :cbush :
        card_type == "CELAS2" ? :celas2 :
        card_type == "CELAS1" ? :celas1 :
        error("TACS-formulation spring kernel supports CELAS1/CELAS2/CBUSH only; got TYPE=$card_type.")
    node_count = Int(get(el, "G2", get(el, "GB", 0))) > 0 ? 2 : 1
    return TACSSpringElementKernel(
        family,
        card_type,
        node_count,
        "residual_first_celas1_celas2_cbush_sol101_sol103",
        "not_applicable",
    )
end

function _tacs_beam_element_kernel(el::AbstractDict)
    card_type = uppercase(strip(string(get(el, "TYPE", "CBAR"))))
    family =
        card_type == "CBEAM" ? :cbeam :
        card_type == "CBAR" ? :cbar :
        error("TACS-formulation beam kernel supports CBAR/CBEAM only; got TYPE=$card_type.")
    return TACSBeamElementKernel(
        family,
        card_type,
        2,
        TACS_LINEAR_BEAM_STIFFNESS_ROUTE,
        TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE,
    )
end

function _tacs_shell_constitutive_kernel(prop::AbstractDict)
    prop_type = uppercase(strip(string(get(prop, "TYPE", "PSHELL"))))
    if prop_type == "PSHELL"
        return TACSConstitutiveKernel(
            :pshell_direct,
            "PSHELL",
            "MAT1/MAT2/MAT8",
            (:shell_thickness, :material_E, :material_G, :material_NU,
             :material_E1, :material_E2, :material_G11, :material_G12,
             :material_G13, :material_G22, :material_G23, :material_G33,
             :material_NU12, :material_RHO),
        )
    elseif prop_type == "PCOMP_CLT"
        return TACSConstitutiveKernel(
            :pcomp_clt,
            "PCOMP_CLT",
            "MAT8_CLT",
            (:shell_thickness, :pcomp_ply_thickness, :pcomp_ply_angle,
             :material_E1, :material_E2, :material_G12, :material_NU12, :material_RHO),
        )
    end
    error("TACS-formulation constitutive kernel supports PSHELL/MAT1, PSHELL/MAT2, PSHELL/MAT8, and PCOMP_CLT only; got TYPE=$prop_type.")
end

function _tacs_response_contract(response)
    family =
        response isa AbstractDict ? Symbol(lowercase(string(get(response, "type", "")))) :
        Symbol(lowercase(string(response)))
    if family == :compliance
        return TACSResponseContract(:compliance, :static, (:value, :state_derivative, :design_derivative))
    elseif family == :displacement
        return TACSResponseContract(:displacement, :static, (:value, :state_derivative, :design_derivative))
    elseif family == :ks_displacement
        return TACSResponseContract(:ks_displacement, :static, (:value, :state_derivative, :design_derivative))
    elseif family == :ks_von_mises
        return TACSResponseContract(:ks_von_mises, :static, (:value, :state_derivative, :explicit_design_derivative))
    elseif family in (:ks_ply_failure, :ks_failure, :ks_composite_failure)
        return TACSResponseContract(:ks_ply_failure, :static, (:value, :state_derivative, :explicit_design_derivative))
    elseif family == :buckling_load_factor
        return TACSResponseContract(:buckling_load_factor, :buckling, (:value, :design_derivative))
    elseif family in (:buckling_ks_load_factor, :buckling_load_factor_ks, :ks_buckling_load_factor)
        return TACSResponseContract(:buckling_ks_load_factor, :buckling, (:value, :design_derivative))
    elseif family in (:modal_eigenvalue, :normal_mode_eigenvalue, :sol103_eigenvalue)
        return TACSResponseContract(:modal_eigenvalue, :modal, (:value, :design_derivative))
    elseif family == :mass
        return TACSResponseContract(:mass, :static, (:value, :design_derivative))
    end
    error("TACS-formulation response contract does not yet support response family '$family'.")
end

function _tacs_sensitivity_contract(response_family::Symbol, design_family::Symbol)
    shell_stiffness_designs = (:shell_thickness, :pcomp_ply_thickness, :pcomp_ply_angle,
                               :material_e, :material_g, :material_nu, :material_e1,
                               :material_e2, :material_g11, :material_g12, :material_g13,
                               :material_g22, :material_g23, :material_g33, :material_nu12)
    beam_sizing_designs = (:beam_area, :beam_i1, :beam_i2, :beam_j)
    static_line_stiffness_designs = (:rod_area, :spring_stiffness, :bush_stiffness, beam_sizing_designs...)
    static_stiffness_designs = (shell_stiffness_designs..., static_line_stiffness_designs...)
    static_load_only_designs = (:material_rho, :material_alpha, :material_tref)
    failure_strength_designs = (:material_xt, :material_xc, :material_yt, :material_yc,
                                :material_s, :material_f12)
    buckling_families = (:buckling_load_factor, :buckling_ks_load_factor)
    static_adjoint_families = (:compliance, :displacement, :ks_displacement)
    if response_family in static_adjoint_families && design_family == :node_coord
        return TACSSensitivityContract(response_family, design_family, :adjoint_coordinate_fd, true)
    elseif response_family in static_adjoint_families && design_family in static_stiffness_designs
        return TACSSensitivityContract(response_family, design_family, :adjoint_design_tangent, false)
    elseif response_family in static_adjoint_families && design_family in static_load_only_designs
        return TACSSensitivityContract(response_family, design_family, :adjoint_load_fd, false)
    elseif response_family == :ks_von_mises && design_family == :node_coord
        return TACSSensitivityContract(response_family, design_family, :adjoint_coordinate_fd_explicit_stress, true)
    elseif response_family == :ks_von_mises && design_family in (shell_stiffness_designs..., beam_sizing_designs...)
        return TACSSensitivityContract(response_family, design_family, :adjoint_design_tangent_explicit_stress, false)
    elseif response_family == :ks_von_mises && design_family in static_load_only_designs
        return TACSSensitivityContract(response_family, design_family, :adjoint_load_fd, false)
    elseif response_family == :ks_ply_failure && design_family in (:pcomp_ply_thickness, :pcomp_ply_angle)
        return TACSSensitivityContract(response_family, design_family, :adjoint_design_tangent_explicit_failure, false)
    elseif response_family == :ks_ply_failure && design_family in failure_strength_designs
        return TACSSensitivityContract(response_family, design_family, :explicit_failure_strength, false)
    elseif response_family in buckling_families && design_family == :node_coord
        return TACSSensitivityContract(response_family, design_family, :rayleigh_coordinate_kg_directional_fd, true)
    elseif response_family in buckling_families && design_family == :shell_thickness
        return TACSSensitivityContract(response_family, design_family, :rayleigh_kg_directional_fd, false)
    elseif response_family in buckling_families && design_family in shell_stiffness_designs
        return TACSSensitivityContract(response_family, design_family, :rayleigh_design_kg_directional_fd, false)
    elseif response_family in buckling_families && design_family == :rod_area
        return TACSSensitivityContract(response_family, design_family, :rayleigh_design_kg_directional_fd, false)
    elseif response_family in buckling_families && design_family in beam_sizing_designs
        return TACSSensitivityContract(response_family, design_family, :rayleigh_design_kg_directional_fd, false)
    elseif response_family in buckling_families && design_family == :material_rho
        return TACSSensitivityContract(response_family, design_family, :rayleigh_load_kg_directional_fd, false)
    elseif response_family == :modal_eigenvalue && design_family == :node_coord
        return TACSSensitivityContract(response_family, design_family, :modal_coordinate_fd, true)
    elseif response_family == :modal_eigenvalue && design_family in shell_stiffness_designs
        return TACSSensitivityContract(response_family, design_family, :modal_design_tangent_fd, false)
    elseif response_family == :modal_eigenvalue && design_family in (:rod_area, :spring_stiffness, :bush_stiffness, beam_sizing_designs...)
        return TACSSensitivityContract(response_family, design_family, :modal_design_tangent_fd, false)
    elseif response_family == :modal_eigenvalue && design_family in (:material_rho, :point_mass, :point_inertia)
        return TACSSensitivityContract(response_family, design_family, :modal_mass_design_fd, false)
    elseif response_family == :mass && design_family == :node_coord
        return TACSSensitivityContract(response_family, design_family, :mass_coordinate_fd, true)
    elseif response_family == :mass && design_family in (:shell_thickness, :pcomp_ply_thickness, :material_rho, :rod_area, :beam_area, :point_mass)
        return TACSSensitivityContract(response_family, design_family, :mass_coefficient, false)
    elseif response_family == :mass && design_family in (:pcomp_ply_angle, :material_e, :material_g, :material_nu,
                                                          :material_e1, :material_e2, :material_g11, :material_g12,
                                                          :material_g13, :material_g22, :material_g23, :material_g33,
                                                          :material_nu12, :spring_stiffness, :bush_stiffness,
                                                          :beam_i1, :beam_i2, :beam_j)
        return TACSSensitivityContract(response_family, design_family, :mass_independent, false)
    end
    error("TACS-formulation sensitivity contract does not yet support response '$response_family' with design family '$design_family'.")
end

_tacs_sensitivity_contract(response::TACSResponseFunction, dv::AbstractDict) =
    _tacs_sensitivity_contract(response.contract.family, _tacs_design_family(dv))

function _tacs_response_spec(response)
    if response isa TACSResponseFunction
        return response.spec
    elseif response isa AbstractDict
        spec = Dict{String,Any}()
        for (k, v) in response
            spec[string(k)] = v
        end
        haskey(spec, "type") || error("TACS-formulation response spec requires a 'type' field.")
        return spec
    else
        return Dict{String,Any}("type" => string(response))
    end
end

function _tacs_response_function(response)
    response isa TACSResponseFunction && return response
    spec = _tacs_response_spec(response)
    return TACSResponseFunction(_tacs_response_contract(spec), spec)
end

function _tacs_design_family(dv::AbstractDict)
    return Symbol(lowercase(string(get(dv, "type", ""))))
end

function _tacs_coordinate_component(raw)
    if raw isa AbstractString
        axis = lowercase(strip(raw))
        axis in ("1", "x", "x1") && return 1
        axis in ("2", "y", "x2") && return 2
        axis in ("3", "z", "x3") && return 3
        error("TACS node_coord component must be 1/x, 2/y, or 3/z; got '$raw'.")
    end
    comp = Int(raw)
    1 <= comp <= 3 || error("TACS node_coord component must be 1, 2, or 3; got $comp.")
    return comp
end

function _tacs_explicit_design_variable(dv::AbstractDict)
    _tacs_design_family(dv) == :node_coord || return dv
    normalized = Dict{String,Any}()
    for (k, v) in dv
        normalized[string(k)] = v
    end
    haskey(normalized, "grid") || haskey(normalized, "gid") ||
        error("TACS node_coord design variable requires grid/gid.")
    haskey(normalized, "grid") || (normalized["grid"] = normalized["gid"])
    raw_comp = get(normalized, "comp", get(normalized, "component", get(normalized, "axis", nothing)))
    raw_comp === nothing && error("TACS node_coord design variable requires comp/component/axis.")
    normalized["comp"] = _tacs_coordinate_component(raw_comp)
    return normalized
end

function _tacs_static_response_context(
    results::AbstractDict,
    response;
    required_family=nothing,
    route_label::AbstractString="TACS static response",
)
    response_fn = _tacs_response_function(response)
    if required_family !== nothing && response_fn.contract.family != required_family
        error("$route_label requires response family '$required_family', got '$(response_fn.contract.family)'.")
    end
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("$route_label requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("$route_label requires stored analysis displacement vector.")
    ndof = Int(results["ndof"])
    fixed_dofs = sort!(Int.(collect(get(subcase, "fixed_dofs", Int[]))))
    free_dofs = sort!(collect(setdiff(1:ndof, fixed_dofs)))
    isempty(free_dofs) && error("$route_label found no free DOFs for the adjoint solve.")
    return TACSStaticResponseContext(
        response_fn,
        results["model"],
        u,
        results["K"],
        results["id_map"],
        results["node_coords"],
        results["node_R"],
        ndof,
        fixed_dofs,
        free_dofs,
        1,
    )
end

function _tacs_response_value(ctx::TACSStaticResponseContext)
    family = ctx.response.contract.family
    if family == :compliance
        return dot(ctx.u, ctx.K * ctx.u)
    elseif family == :mass
        isdefined(@__MODULE__, :_sol200_lite_shell_mass) ||
            error("TACS-formulation mass response requires the SOL200-lite shell mass helper to be loaded.")
        return isdefined(@__MODULE__, :_tacs_structural_mass_value) ?
            _tacs_structural_mass_value(ctx.model) :
            _sol200_lite_shell_mass(ctx.model)
    elseif family in (:displacement, :ks_displacement, :ks_von_mises, :ks_ply_failure)
        return Solver.evaluate_response(ctx.response.spec, ctx.u, ctx.model, ctx.id_map, ctx.ndof, ctx.X, ctx.node_R)
    end
    error("TACS-formulation static response value is not implemented for response family '$family'.")
end

function _tacs_response_state_derivative(ctx::TACSStaticResponseContext)
    family = ctx.response.contract.family
    if family == :compliance
        return 2.0 .* (ctx.K * ctx.u)
    elseif family == :mass
        return zeros(Float64, ctx.ndof)
    elseif family in (:displacement, :ks_displacement, :ks_von_mises, :ks_ply_failure)
        return Solver.compute_dr_du(ctx.response.spec, ctx.u, ctx.model, ctx.id_map, ctx.ndof, ctx.X, ctx.node_R)
    end
    error("TACS-formulation static response state derivative is not implemented for response family '$family'.")
end

function _tacs_static_adjoint(ctx::TACSStaticResponseContext)
    dr_du_full = _tacs_response_state_derivative(ctx)
    K_ff = ctx.K[ctx.free_dofs, ctx.free_dofs]
    lambda_f = cholesky(Symmetric(K_ff)) \ dr_du_full[ctx.free_dofs]
    lambda_full = zeros(Float64, ctx.ndof)
    lambda_full[ctx.free_dofs] = lambda_f
    return lambda_full
end

function _tacs_response_explicit_design_derivative(ctx::TACSStaticResponseContext, dv::AbstractDict)
    explicit = Solver.compute_dr_dx_explicit(
        ctx.response.spec,
        _tacs_explicit_design_variable(dv),
        ctx.model,
        ctx.id_map,
        ctx.X,
        ctx.node_R,
        ctx.u,
        ctx.ndof,
    )
    return sum(Float64(v) for v in values(explicit))
end

function _tacs_design_diagnostics(
    dv::AbstractDict,
    steps,
    contract::TACSSensitivityContract,
    gradient_backend::AbstractString;
    explicit_derivative=nothing,
    load_derivative=nothing,
)
    diag = Dict{String,Any}(
        "type" => string(get(dv, "type", "")),
        "pids" => Int.(collect(get(dv, "pids", Int[]))),
        "gradient_backend" => string(gradient_backend),
        "sensitivity_contract" => _tacs_contract_metadata(contract),
    )
    mids = get(dv, "mids", nothing)
    mids !== nothing && (diag["mids"] = Int.(collect(mids)))
    eids = get(dv, "eids", nothing)
    eids !== nothing && (diag["eids"] = Int.(collect(eids)))
    comp = get(dv, "component", get(dv, "comp", nothing))
    comp !== nothing && (diag["component"] = Int(comp))
    haskey(dv, "ply_index") && (diag["ply_index"] = Int(dv["ply_index"]))
    !isempty(steps) && (diag["step"] = maximum(steps))
    string(get(dv, "type", "")) == "pcomp_ply_angle" && (diag["angle_unit"] = "degree")
    explicit_derivative !== nothing && (diag["explicit_derivative"] = Float64(explicit_derivative))
    if load_derivative !== nothing
        load_norm = norm(Float64.(load_derivative))
        diag["load_derivative_norm"] = load_norm
        diag["load_derivative_nonzero"] = load_norm > 1e-20
    end
    return diag
end

function _tacs_buckling_response_context(results::AbstractDict; mode::Integer=1)
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    mode_idx = Int(mode)
    1 <= mode_idx <= length(eigenvalues) ||
        error("TACS buckling load-factor gradient requested mode $mode_idx but only $(length(eigenvalues)) modes are available.")
    response = _tacs_response_function(Dict{String,Any}("type" => "buckling_load_factor", "mode" => mode_idx))
    phi = Vector{Float64}(results["_raw_mode_shapes"][:, mode_idx])
    Kg = results["Kg"]
    denom = dot(phi, -Kg * phi)
    abs(denom) > 1e-30 ||
        error("TACS buckling load-factor gradient found a near-zero eigenvector normalization denominator.")
    return TACSBucklingResponseContext(response, mode_idx, eigenvalues[mode_idx], phi, Kg, denom)
end

function _tacs_modal_response_context(results::AbstractDict; mode::Integer=1)
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    frequencies = Float64.(get(results, "frequencies", Float64[]))
    mode_idx = Int(mode)
    1 <= mode_idx <= length(eigenvalues) ||
        error("TACS modal eigenvalue gradient requested mode $mode_idx but only $(length(eigenvalues)) modes are available.")
    response = _tacs_response_function(Dict{String,Any}("type" => "modal_eigenvalue", "mode" => mode_idx))
    raw_modes = get(results, "_raw_mode_shapes", zeros(Float64, 0, 0))
    size(raw_modes, 2) >= mode_idx ||
        error("TACS modal eigenvalue gradient requires stored raw SOL103 mode shapes.")
    node_R = results["node_R"]
    id_map = results["id_map"]
    modes_analysis = isdefined(@__MODULE__, :_sol103_global_to_analysis_modes) ?
        _sol103_global_to_analysis_modes(raw_modes, id_map, node_R) :
        raw_modes
    phi = Vector{Float64}(modes_analysis[:, mode_idx])
    K = results["K"]
    M = haskey(results, "M") ?
        results["M"] :
        Solver.assemble_mass(results["model"], id_map, results["node_coords"], node_R, Int(results["ndof"]))
    denom = dot(phi, M * phi)
    abs(denom) > 1e-30 ||
        error("TACS modal eigenvalue gradient found a near-zero generalized mass denominator.")
    frequency = mode_idx <= length(frequencies) ? frequencies[mode_idx] : sqrt(abs(eigenvalues[mode_idx])) / (2.0 * pi)
    return TACSModalResponseContext(response, mode_idx, eigenvalues[mode_idx], frequency, phi, K, M, denom)
end

function _tacs_eigenvalue_cluster_modes(
    eigenvalues::AbstractVector{<:Real},
    mode::Integer;
    rel_tol::Real=1e-8,
    abs_tol::Real=1e-10,
)
    mode_idx = Int(mode)
    1 <= mode_idx <= length(eigenvalues) ||
        error("TACS eigenvalue cluster requested mode $mode_idx but only $(length(eigenvalues)) eigenvalues are available.")
    lambda0 = Float64(eigenvalues[mode_idx])
    threshold = max(Float64(abs_tol), Float64(rel_tol) * max(abs(lambda0), 1.0))
    modes = Int[]
    for (idx, value) in enumerate(eigenvalues)
        abs(Float64(value) - lambda0) <= threshold && push!(modes, idx)
    end
    isempty(modes) && push!(modes, mode_idx)
    return modes
end

function _tacs_cluster_policy(policy)
    p = lowercase(strip(string(policy)))
    p in ("current", "current_mode", "rayleigh_current_mode", "index") && return :current_mode
    p in ("min", "minimum", "lower", "lower_bound") && return :min
    p in ("max", "maximum", "upper", "upper_bound") && return :max
    p in ("mean", "average", "avg") && return :mean
    error("TACS eigenvalue cluster policy '$policy' is not supported. Use current_mode, min, max, or mean.")
end

function _tacs_select_cluster_derivative(
    cluster_values::AbstractVector{<:Real},
    current_derivative::Real;
    policy=:current_mode,
)
    normalized = _tacs_cluster_policy(policy)
    values = Float64.(collect(cluster_values))
    isempty(values) && return Float64(current_derivative)
    normalized == :current_mode && return Float64(current_derivative)
    normalized == :min && return minimum(values)
    normalized == :max && return maximum(values)
    normalized == :mean && return sum(values) / length(values)
    error("Unhandled TACS eigenvalue cluster policy '$normalized'.")
end

function _tacs_mode_tracking_spec(mode_tracking)
    if mode_tracking === nothing || mode_tracking === false
        return Dict{String,Any}("method" => "index")
    elseif mode_tracking isa AbstractString || mode_tracking isa Symbol
        return Dict{String,Any}("method" => lowercase(strip(string(mode_tracking))))
    elseif mode_tracking isa AbstractDict
        spec = Dict{String,Any}()
        for (k, v) in mode_tracking
            spec[string(k)] = v
        end
        haskey(spec, "method") || (spec["method"] = "mac")
        spec["method"] = lowercase(strip(string(spec["method"])))
        return spec
    end
    error("TACS mode_tracking must be nothing, a method name, or a dictionary.")
end

function _tacs_mode_tracking_analysis_family(results::AbstractDict, analysis_family)
    if analysis_family isa Symbol
        family = analysis_family
    else
        family = Symbol(lowercase(strip(string(analysis_family))))
    end
    if family in (:auto, :default)
        sol_type = Int(get(results, "sol_type", 0))
        sol_type == 103 && return :modal
        sol_type == 105 && return :buckling
        error("TACS mode continuation can infer analysis family only from SOL103/SOL105 results; got SOL $sol_type.")
    end
    family in (:modal, :buckling) ||
        error("TACS mode continuation analysis family must be :modal, :buckling, or :auto; got '$analysis_family'.")
    return family
end

function _tacs_mode_tracking_candidate_window(
    n_modes::Integer,
    mode::Integer;
    candidate_modes=nothing,
    candidate_window=1,
)
    n = Int(n_modes)
    m = Int(mode)
    1 <= m <= n ||
        error("TACS mode continuation requested mode $m but only $n modes are available.")
    if candidate_modes !== nothing
        candidates = sort!(unique(Int.(collect(candidate_modes))))
    elseif candidate_window === nothing
        candidates = collect(1:n)
    else
        window = Int(round(Float64(candidate_window)))
        window >= 0 || error("TACS mode continuation candidate_window must be nonnegative.")
        lo = max(1, m - window)
        hi = min(n, m + window)
        candidates = collect(lo:hi)
    end
    isempty(candidates) && error("TACS mode continuation requires at least one candidate mode.")
    for candidate in candidates
        1 <= candidate <= n ||
            error("TACS mode continuation candidate $candidate is outside available mode range 1:$n.")
    end
    return candidates
end

function _tacs_mode_tracking_candidates(n_modes::Integer, spec::AbstractDict)
    raw = get(spec, "candidate_modes", get(spec, "candidates", nothing))
    modes = raw === nothing ? collect(1:Int(n_modes)) : sort!(unique(Int.(collect(raw))))
    isempty(modes) && error("TACS mode tracking requires at least one candidate mode.")
    for mode in modes
        1 <= mode <= Int(n_modes) ||
            error("TACS mode tracking candidate $mode is outside available mode range 1:$(Int(n_modes)).")
    end
    return modes
end

function _tacs_select_mode_by_mac(
    mode_matrix::AbstractMatrix,
    reference_mode::AbstractVector;
    candidate_modes=nothing,
)
    modes = Matrix{Float64}(mode_matrix)
    ref = Float64.(collect(reference_mode))
    size(modes, 1) == length(ref) ||
        error("TACS MAC mode tracking requires reference length $(length(ref)) to match mode vector length $(size(modes, 1)).")
    ref_norm2 = dot(ref, ref)
    ref_norm2 > 0.0 || error("TACS MAC mode tracking requires a nonzero reference mode.")
    candidates =
        candidate_modes === nothing ? collect(1:size(modes, 2)) :
        sort!(unique(Int.(collect(candidate_modes))))
    isempty(candidates) && error("TACS MAC mode tracking requires at least one candidate mode.")
    scores = Dict{Int,Float64}()
    for mode in candidates
        1 <= mode <= size(modes, 2) ||
            error("TACS MAC mode tracking candidate $mode is outside available mode range 1:$(size(modes, 2)).")
        phi = modes[:, mode]
        denom = ref_norm2 * dot(phi, phi)
        denom > 0.0 || error("TACS MAC mode tracking found a zero-norm candidate mode $mode.")
        scores[mode] = (dot(ref, phi)^2) / denom
    end
    selected = first(candidates)
    best = scores[selected]
    for mode in candidates
        score = scores[mode]
        if score > best || (score == best && mode < selected)
            selected = mode
            best = score
        end
    end
    return selected, scores
end

function _tacs_tracking_mode_matrix(results::AbstractDict, analysis_family::Symbol)
    raw_modes = get(results, "_raw_mode_shapes", zeros(Float64, 0, 0))
    raw_modes isa AbstractMatrix && size(raw_modes, 2) > 0 ||
        error("TACS mode tracking requires stored raw mode shapes.")
    if analysis_family == :modal
        node_R = results["node_R"]
        id_map = results["id_map"]
        return isdefined(@__MODULE__, :_sol103_global_to_analysis_modes) ?
            _sol103_global_to_analysis_modes(raw_modes, id_map, node_R) :
            Matrix{Float64}(raw_modes)
    end
    return Matrix{Float64}(raw_modes)
end

function _tacs_resolve_tracked_mode(
    results::AbstractDict;
    mode::Integer=1,
    mode_tracking=nothing,
    analysis_family::Symbol=:modal,
)
    requested_mode = Int(mode)
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    1 <= requested_mode <= length(eigenvalues) ||
        error("TACS mode tracking requested mode $requested_mode but only $(length(eigenvalues)) eigenvalues are available.")
    spec = _tacs_mode_tracking_spec(mode_tracking)
    method = string(get(spec, "method", "index"))
    if method in ("index", "none", "off", "false")
        return requested_mode, Dict{String,Any}(
            "method" => "index",
            "requested_mode" => requested_mode,
            "selected_mode" => requested_mode,
        )
    elseif method in ("mac", "modal_assurance", "modal_assurance_criterion")
        reference = get(spec, "reference_mode", get(spec, "reference", nothing))
        reference === nothing && error("TACS MAC mode tracking requires a reference_mode vector.")
        modes = _tacs_tracking_mode_matrix(results, analysis_family)
        candidates = _tacs_mode_tracking_candidates(size(modes, 2), spec)
        selected, scores = _tacs_select_mode_by_mac(modes, Float64.(collect(reference)); candidate_modes=candidates)
        selected_mac = Float64(scores[selected])
        minimum_mac = Float64(get(spec, "minimum_mac", get(spec, "min_mac", 0.0)))
        0.0 <= minimum_mac <= 1.0 ||
            error("TACS MAC mode tracking minimum_mac must be in [0, 1]; got $minimum_mac.")
        selected_mac + 1e-14 >= minimum_mac ||
            error("TACS MAC mode tracking selected mode $selected has MAC $selected_mac below requested minimum $minimum_mac.")
        return selected, Dict{String,Any}(
            "method" => "mac",
            "requested_mode" => requested_mode,
            "selected_mode" => selected,
            "candidate_modes" => candidates,
            "selected_mac" => selected_mac,
            "minimum_mac" => minimum_mac,
            "reference_mode_index" => get(spec, "reference_mode_index", get(spec, "source_mode", nothing)),
            "reference_value" => get(spec, "reference_value", nothing),
            "scores" => Dict(string(k) => v for (k, v) in scores),
        )
    end
    error("TACS mode tracking method '$method' is not supported.")
end

function eigen_mode_tracking_reference(
    results::AbstractDict;
    mode::Integer=1,
    analysis_family=:auto,
    candidate_modes=nothing,
    candidate_window=1,
    minimum_mac::Real=0.0,
)
    family = _tacs_mode_tracking_analysis_family(results, analysis_family)
    modes = _tacs_tracking_mode_matrix(results, family)
    mode_idx = Int(mode)
    candidates = _tacs_mode_tracking_candidate_window(
        size(modes, 2),
        mode_idx;
        candidate_modes=candidate_modes,
        candidate_window=candidate_window,
    )
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    1 <= mode_idx <= length(eigenvalues) ||
        error("TACS mode continuation requested mode $mode_idx but only $(length(eigenvalues)) eigenvalues are available.")
    min_mac = Float64(minimum_mac)
    0.0 <= min_mac <= 1.0 ||
        error("TACS mode continuation minimum_mac must be in [0, 1]; got $min_mac.")
    return Dict{String,Any}(
        "method" => "mac",
        "analysis_family" => string(family),
        "reference_mode" => Vector{Float64}(modes[:, mode_idx]),
        "reference_mode_index" => mode_idx,
        "reference_value" => Float64(eigenvalues[mode_idx]),
        "candidate_modes" => candidates,
        "candidate_window" => candidate_window,
        "minimum_mac" => min_mac,
        "continuation" => "previous_solve_mac",
    )
end

function eigen_mode_continuation_update(
    results::AbstractDict,
    previous_tracking=nothing;
    mode::Integer=1,
    analysis_family=:auto,
    candidate_modes=nothing,
    candidate_window=1,
    minimum_mac::Real=0.0,
)
    family = _tacs_mode_tracking_analysis_family(results, analysis_family)
    requested_mode = Int(mode)
    selected_mode =
        previous_tracking === nothing || previous_tracking === false ?
        requested_mode :
        first(_tacs_resolve_tracked_mode(
            results;
            mode=requested_mode,
            mode_tracking=previous_tracking,
            analysis_family=family,
        ))
    next_tracking = eigen_mode_tracking_reference(
        results;
        mode=selected_mode,
        analysis_family=family,
        candidate_modes=candidate_modes,
        candidate_window=candidate_window,
        minimum_mac=minimum_mac,
    )
    _, diagnostics = _tacs_resolve_tracked_mode(
        results;
        mode=requested_mode,
        mode_tracking=next_tracking,
        analysis_family=family,
    )
    diagnostics["continuation"] = "previous_solve_mac"
    diagnostics["analysis_family"] = string(family)
    diagnostics["state_initialized"] = previous_tracking === nothing || previous_tracking === false
    return next_tracking, diagnostics
end

function _tacs_projected_generalized_eigen_derivatives(
    Aproj::AbstractMatrix,
    Bproj::AbstractMatrix;
    route_label::AbstractString="TACS clustered eigenvalue sensitivity",
)
    A = Matrix{Float64}(Aproj)
    B = Matrix{Float64}(Bproj)
    size(A, 1) == size(A, 2) || error("$route_label requires a square projected derivative matrix.")
    size(B) == size(A) || error("$route_label requires matching projected metric and derivative matrices.")
    A .= 0.5 .* (A .+ transpose(A))
    B .= 0.5 .* (B .+ transpose(B))
    if size(A, 1) == 1
        denom = B[1, 1]
        abs(denom) > 1e-30 || error("$route_label found a near-zero one-dimensional projected metric.")
        return [A[1, 1] / denom]
    end
    factor = cholesky(Symmetric(B))
    L = factor.L
    C = L \ A / transpose(L)
    C .= 0.5 .* (C .+ transpose(C))
    return sort!(eigvals(Symmetric(C)))
end

function _tacs_modal_cluster_projected_derivatives(
    phi_cluster::AbstractMatrix,
    dK::AbstractMatrix,
    dM::AbstractMatrix,
    M::AbstractMatrix,
    lambda::Real;
    route_label::AbstractString="TACS modal clustered sensitivity",
)
    Phi = Matrix{Float64}(phi_cluster)
    Aproj = transpose(Phi) * (dK - Float64(lambda) * dM) * Phi
    Bproj = transpose(Phi) * M * Phi
    return _tacs_projected_generalized_eigen_derivatives(Aproj, Bproj; route_label=route_label)
end

function _tacs_buckling_cluster_projected_derivatives(
    phi_cluster::AbstractMatrix,
    dK::AbstractMatrix,
    dKg::AbstractMatrix,
    Kg::AbstractMatrix,
    lambda::Real;
    route_label::AbstractString="TACS buckling clustered sensitivity",
)
    Phi = Matrix{Float64}(phi_cluster)
    Aproj = transpose(Phi) * (dK + Float64(lambda) * dKg) * Phi
    Bproj = transpose(Phi) * (-Kg) * Phi
    return _tacs_projected_generalized_eigen_derivatives(Aproj, Bproj; route_label=route_label)
end

function _tacs_contract_metadata(contract::TACSShellElementKernel)
    return Dict{String,Any}(
        "kind" => "element",
        "family" => string(contract.family),
        "card_type" => contract.card_type,
        "node_count" => contract.node_count,
        "linear_stiffness" => contract.linear_stiffness_route,
        "geometric_stiffness" => contract.geometric_stiffness_route,
    )
end

function _tacs_contract_metadata(contract::TACSConstitutiveKernel)
    return Dict{String,Any}(
        "kind" => "constitutive",
        "family" => string(contract.family),
        "property_type" => contract.property_type,
        "material_type" => contract.material_type,
        "design_variables" => string.(contract.design_variables),
    )
end

function _tacs_contract_metadata(contract::TACSResponseContract)
    return Dict{String,Any}(
        "kind" => "response",
        "family" => string(contract.family),
        "analysis_family" => string(contract.analysis_family),
        "derivative_forms" => string.(contract.derivative_forms),
    )
end

function _tacs_contract_metadata(response::TACSResponseFunction)
    return merge(
        _tacs_contract_metadata(response.contract),
        Dict{String,Any}(
            "kind" => "response_function",
            "spec_keys" => sort!(collect(keys(response.spec))),
        ),
    )
end

function _tacs_contract_metadata(contract::TACSSensitivityContract)
    return Dict{String,Any}(
        "kind" => "sensitivity",
        "response_family" => string(contract.response_family),
        "design_family" => string(contract.design_family),
        "derivative_method" => string(contract.derivative_method),
        "coordinate_supported" => contract.coordinate_supported,
    )
end

function _tacs_core_contract_metadata()
    return Dict{String,Any}(
        "element_kernels" => ["shell_cquad4", "shell_cquadr", "shell_ctria3", "rod_crod", "rod_conrod", "beam_cbar", "beam_cbeam", "spring_celas1", "spring_celas2", "spring_cbush"],
        "constitutive_kernels" => ["pshell_mat1", "pshell_mat2", "pshell_mat8", "pcomp_clt", "rod_prod_mat1", "rod_conrod_mat1", "beam_pbar_mat1", "beam_pbeam_constant_equivalent", "beam_pbeam_station_stiffness_condensation", "beam_pbeam_station_modal_guyan_mass", "beam_pbeam_station_geometric_stiffness_condensation", "spring_pelas", "spring_direct", "spring_pbush"],
        "response_contracts" => ["compliance", "displacement", "ks_displacement", "mass", "ks_von_mises", "ks_ply_failure", "modal_eigenvalue", "buckling_load_factor", "buckling_ks_load_factor"],
        "response_functions" => ["static_response_value", "static_response_state_derivative", "static_adjoint", "explicit_design_derivative", "static_load_design_derivative", "beam_pbeam_station_stress_recovery", "modal_eigenvalue", "buckling_load_factor", "buckling_ks_load_factor", "clustered_eigenvalue_projected_derivative", "eigenvalue_cluster_policy", "mac_mode_tracking", "previous_solve_mac_mode_continuation"],
        "sensitivity_contracts" => [
            "static_shell_thickness",
            "static_shell_design_tangent",
            "coordinate_shape_sensitivity",
            "static_shell_coordinate_sensitivity",
            "static_design_dependent_load_sensitivity",
            "static_material_density_load_sensitivity",
            "static_line_thermal_load_sensitivity",
            "sol105_preload_design_dependent_load_sensitivity",
            "static_ks_von_mises_design_tangent",
            "static_ks_von_mises_beam_design_tangent",
            "static_ks_von_mises_coordinate_sensitivity",
            "static_ks_ply_failure_design_tangent",
            "static_ks_ply_failure_strength_explicit",
            "structural_mass_shell_design_tangent",
            "structural_mass_coordinate_sensitivity",
            "modal_eigenvalue_shell_coordinate",
            "modal_eigenvalue_shell_design_tangent",
            "modal_eigenvalue_material_density",
            "modal_eigenvalue_clustered_subspace",
            "modal_eigenvalue_mode_tracking",
            "modal_eigenvalue_cluster_policy",
            "modal_eigenvalue_mode_continuation",
            "buckling_load_factor_shell_thickness",
            "buckling_load_factor_shell_coordinate",
            "buckling_load_factor_shell_design_tangent",
            "buckling_load_factor_inertial_preload_density",
            "buckling_ks_load_factor_shell_design_tangent",
            "buckling_load_factor_clustered_subspace",
            "buckling_load_factor_mode_tracking",
            "buckling_load_factor_cluster_policy",
            "buckling_load_factor_mode_continuation",
        ],
        "known_missing" => [
            "broad_thermal_design_dependent_load_sensitivity",
            "inertial_centrifugal_coordinate_design_dependent_load_sensitivity",
            "sol106_nonlinear_adjoint",
            "rod_only_sol105_buckling_route",
            "rod_stress_loads_and_sensitivities",
            "spring_damping_orientation_and_broader_mass_sensitivities",
            "beam_non_pload1_loads_broader_stress_failure_shape_and_varying_pbeam_offset_release_pload1_stress_sensitivity_breadth",
            "solid_thermal_element_kernels",
        ],
    )
end

function _tacs_shell_element_context(model::Dict, el::AbstractDict, id_map, X, node_R)
    kernel = _tacs_shell_element_kernel(el)
    nids = Int.(el["NODES"])
    idxs = [id_map[nid] for nid in nids]
    ps = [SVector{3,Float64}(X[idx, 1], X[idx, 2], X[idx, 3]) for idx in idxs]
    local_geometry =
        kernel.node_count == 4 ?
        _tacs_quad4_local_geometry(ps[1], ps[2], ps[3], ps[4]) :
        _tacs_tria3_local_geometry(ps[1], ps[2], ps[3])
    lc, v1, v2, v3 = local_geometry
    transform =
        kernel.node_count == 4 ?
        _tacs_quad4_transform(idxs, v1, v2, v3, node_R) :
        _tacs_shell_transform(idxs, v1, v2, v3, node_R)
    pid = Int(get(el, "PID", 0))
    prop = model["PSHELLs"][string(pid)]
    constitutive = _tacs_shell_constitutive_kernel(prop)
    return TACSShellElementContext(
        kernel,
        constitutive,
        Int(get(el, "ID", 0)),
        pid,
        collect(nids),
        collect(idxs),
        Matrix{Float64}(lc),
        v1,
        v2,
        v3,
        transform,
        _tacs_shell_dofs(idxs),
        prop,
    )
end
