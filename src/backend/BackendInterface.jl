# BackendInterface.jl -- solver backend selection and shared metadata.
#
# The default backend preserves the existing calibrated JFEM/Nastran-parity
# route.  The TACS-formulation backend is intentionally opt-in and grows as a
# residual-first implementation behind the same public solver API.

abstract type AbstractJFEMBackend end

struct NastranParityBackend <: AbstractJFEMBackend end
struct TACSFormulationBackend <: AbstractJFEMBackend end

const JFEM_BACKEND_DEFAULT = "nastran_parity"
const JFEM_BACKEND_TACS = "tacs_formulation"

function normalize_backend_name(raw)::String
    name = lowercase(strip(string(raw)))
    name = replace(name, "-" => "_", " " => "_")
    if name in ("", "default", "nastran", "nastran_parity", "parity", "jfem")
        return JFEM_BACKEND_DEFAULT
    elseif name in ("tacs", "tacs_formulation", "tacs_backend", "clean_formulation")
        return JFEM_BACKEND_TACS
    end
    error("Unsupported JFEM backend '$raw'. Supported backends are '$JFEM_BACKEND_DEFAULT' and '$JFEM_BACKEND_TACS'.")
end

backend_name(::NastranParityBackend) = JFEM_BACKEND_DEFAULT
backend_name(::TACSFormulationBackend) = JFEM_BACKEND_TACS

backend_version(::NastranParityBackend) = "0.1.0"
backend_version(::TACSFormulationBackend) = "0.1.0-dev"

function backend_from_name(raw)::AbstractJFEMBackend
    name = normalize_backend_name(raw)
    if name == JFEM_BACKEND_DEFAULT
        return NastranParityBackend()
    elseif name == JFEM_BACKEND_TACS
        return TACSFormulationBackend()
    end
    error("Internal backend normalization error for '$raw'")
end

function backend_from_model(model::AbstractDict)::AbstractJFEMBackend
    raw = get(model, "backend", get(ENV, "JFEM_BACKEND", JFEM_BACKEND_DEFAULT))
    return backend_from_name(raw)
end

function backend_metadata(backend::AbstractJFEMBackend)::Dict{String,Any}
    name = backend_name(backend)
    formulation =
        backend isa NastranParityBackend ? Dict{String,Any}(
            "shell" => "existing_calibrated_jfem",
            "constitutive" => "existing_model_builder_properties",
            "geometric_stiffness" => "existing_parity_route",
            "thickness_derivative" => "existing_solver_routes",
        ) : Dict{String,Any}(
            "shell" => "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106",
            "constitutive" => "mat1_pshell_pcomp_clt",
            "geometric_stiffness" => "native_residual_first_quad4_cquadr_tria3",
            "nonlinear_state" => "backend_sol106_state_callback",
            "thickness_derivative" => "element_ad",
        )
    return Dict{String,Any}(
        "backend" => name,
        "backend_version" => backend_version(backend),
        "formulation" => formulation,
    )
end

function attach_backend_metadata!(results::AbstractDict, backend::AbstractJFEMBackend)
    metadata = backend_metadata(backend)
    for (k, v) in metadata
        results[k] = v
    end
    diagnostics = get(results, "solver_diagnostics", nothing)
    if diagnostics isa AbstractDict
        diagnostics["backend"] = metadata["backend"]
        diagnostics["backend_version"] = metadata["backend_version"]
    elseif diagnostics isa AbstractVector
        push!(diagnostics, Dict{String,Any}(
            "phase" => "backend",
            "backend" => metadata["backend"],
            "backend_version" => metadata["backend_version"],
        ))
    end
    return results
end

function static_compliance_thickness_gradient(backend::AbstractJFEMBackend, results::AbstractDict; pids=nothing)
    error("Static compliance thickness gradients are not implemented for backend '$(backend_name(backend))'.")
end

function static_compliance_thickness_gradient(results::AbstractDict; pids=nothing)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return static_compliance_thickness_gradient(backend, results; pids=pids)
end

function static_displacement_thickness_gradient(backend::AbstractJFEMBackend, results::AbstractDict, response::AbstractDict; pids=nothing)
    error("Static displacement thickness gradients are not implemented for backend '$(backend_name(backend))'.")
end

function static_displacement_thickness_gradient(results::AbstractDict, response::AbstractDict; pids=nothing)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return static_displacement_thickness_gradient(backend, results, response; pids=pids)
end

function static_compliance_design_gradient(backend::AbstractJFEMBackend, results::AbstractDict, design_variables::AbstractVector)
    error("Static compliance design gradients are not implemented for backend '$(backend_name(backend))'.")
end

function static_compliance_design_gradient(results::AbstractDict, design_variables::AbstractVector)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return static_compliance_design_gradient(backend, results, design_variables)
end

function static_displacement_design_gradient(backend::AbstractJFEMBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    error("Static displacement design gradients are not implemented for backend '$(backend_name(backend))'.")
end

function static_displacement_design_gradient(results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return static_displacement_design_gradient(backend, results, response, design_variables)
end

function static_ks_von_mises_design_gradient(backend::AbstractJFEMBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    error("Static KS von-Mises design gradients are not implemented for backend '$(backend_name(backend))'.")
end

function static_ks_von_mises_design_gradient(results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return static_ks_von_mises_design_gradient(backend, results, response, design_variables)
end

function buckling_load_factor_thickness_gradient(backend::AbstractJFEMBackend, results::AbstractDict; pids=nothing, mode::Integer=1)
    error("Buckling load-factor thickness gradients are not implemented for backend '$(backend_name(backend))'.")
end

function buckling_load_factor_thickness_gradient(results::AbstractDict; pids=nothing, mode::Integer=1)
    backend = backend_from_name(get(results, "backend", JFEM_BACKEND_DEFAULT))
    return buckling_load_factor_thickness_gradient(backend, results; pids=pids, mode=mode)
end
