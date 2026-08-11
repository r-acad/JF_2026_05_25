# boundary_conditions.jl - SPC application, AUTOSPC, and linear solve

@inline function model_autospc_enabled(model)
    if haskey(ENV, "JFEM_AUTOSPC")
        raw_env = lowercase(strip(ENV["JFEM_AUTOSPC"]))
        return raw_env in ("1", "true", "yes", "on")
    end
    raw = get(model, "PARAM_AUTOSPC", true)
    if raw isa AbstractString
        token = uppercase(strip(raw))
        return !(token in ("", "NO", "N", "FALSE", "F", "OFF", "0"))
    elseif raw isa Number
        return abs(Float64(raw)) > 1e-12
    elseif raw === nothing
        return true
    end
    return Bool(raw)
end

@inline function autospc_negative_diagonal_enabled()
    return solver_env_bool("JFEM_AUTOSPC_NEGATIVE_DIAGONAL", true)
end

@inline function _permanent_grid_components(ps_raw)
    comps = Int[]
    seen = Set{Int}()
    for ch in strip(string(ps_raw))
        if '1' <= ch <= '6'
            comp = Int(ch - '0')
            if !(comp in seen)
                push!(comps, comp)
                push!(seen, comp)
            end
        end
    end
    return comps
end

function _apply_permanent_grid_constraints!(fixed_dofs::Set{Int}, model, id_map)
    permanent_dofs = Set{Int}()
    constrained_grids = 0

    for (grid_key, grid) in get(model, "GRIDs", Dict())
        comps = _permanent_grid_components(get(grid, "PS", ""))
        isempty(comps) && continue

        gid = Int(get(grid, "ID", try parse(Int, string(grid_key)) catch; 0 end))
        idx = get(id_map, gid, 0)
        idx > 0 || continue

        constrained_grids += 1
        for comp in comps
            gdof = (idx - 1) * 6 + comp
            push!(fixed_dofs, gdof)
            push!(permanent_dofs, gdof)
        end
    end

    return length(permanent_dofs), constrained_grids
end

mutable struct LinearSolveCacheEntry
    free_dofs::Vector{Int}
    fixed_dofs::Set{Int}
    spc_dofs::Set{Int}
    enforced_dofs::Vector{Int}
    enforced_values::Vector{Float64}
    K_ff::SparseMatrixCSC{Float64,Int}
    K_fs::Union{Nothing,SparseMatrixCSC{Float64,Int}}
    factor::Any
    diagnostics::Dict{String,Any}
end

create_linear_solve_cache() = Dict{Any,LinearSolveCacheEntry}()

mutable struct EigenSolveCacheEntry
    free_dofs::Vector{Int}
    fixed_dofs::Set{Int}
    bc_diagnostics::Dict{String,Any}
    K_ff::SparseMatrixCSC{Float64,Int}
    factor::Any
    factor_backend::String  # "cholesky" | "lu" | ""
    # Cached CHOLMOD LDLᵀ factor of the buckling pencil K_ff + σ·Kg_ff used
    # by the Sturm inertia counts: later subcases refactor numerically into
    # this object instead of re-running the symbolic analysis. Julia pins
    # CHOLMOD to SIMPLICIAL mode, whose numeric refactorization recomputes
    # column patterns from the actual matrix, so reuse is pattern-safe even
    # if Kg sparsity were to differ across subcases; inertia counts are
    # additionally permutation-invariant (Sylvester), so reuse cannot change
    # any integer result. NUMERIC content is whatever the last count left —
    # consumers must ldlt! before reading. Retained for the lifetime of the
    # per-deck eigen cache (a pencil-factor-sized allocation; cleared with
    # the cache when the deck's solve completes).
    sturm_factor::Any
end

create_eigen_solve_cache() = Dict{Any,EigenSolveCacheEntry}()

@inline function linear_solve_cache_min_ndof()
    return max(round(Int, solver_env_float("JFEM_LINEAR_CACHE_MIN_NDOF", 2000.0)), 0)
end

@inline function eigen_solve_cache_min_ndof()
    return max(round(Int, solver_env_float("JFEM_EIGEN_CACHE_MIN_NDOF", Float64(linear_solve_cache_min_ndof()))), 0)
end

@inline function _linear_solve_cache_key(K, ndof::Int, model, spc_id, rbe3_map)
    spc_token = isnothing(spc_id) ? 0 : Int(spc_id)
    rbe3_token = isempty(rbe3_map) ? 0 : objectid(rbe3_map)
    return (
        objectid(K),
        ndof,
        objectid(model),
        spc_token,
        rbe3_token,
        model_autospc_enabled(model),
        autospc_trans_relative_threshold(model),
        autospc_rot_relative_threshold(model),
        autospc_gpst_relative_threshold(model),
        autospc_negative_diagonal_enabled(),
        gpst_enabled(),
        gpst_translational_enabled(),
    )
end

@inline function _eigen_solve_cache_key(K, ndof::Int, model, spc_id, rbe3_map;
                                        allow_factorization_autospc::Bool=true)
    return (
        _linear_solve_cache_key(K, ndof, model, spc_id, rbe3_map),
        allow_factorization_autospc,
    )
end

function prepare_eigen_solve_context(K, ndof, model, id_map, spc_id, rbe3_map;
                                     eigen_cache=nothing,
                                     allow_factorization_autospc::Bool=true)
    cache_enabled = eigen_cache !== nothing && ndof >= eigen_solve_cache_min_ndof()
    cache_key = cache_enabled ? _eigen_solve_cache_key(
        K, ndof, model, spc_id, rbe3_map;
        allow_factorization_autospc=allow_factorization_autospc) : nothing
    cached_entry = (cache_enabled && cache_key !== nothing) ? get(eigen_cache, cache_key, nothing) : nothing

    if cached_entry !== nothing
        return cached_entry, true
    end

    trial_ref = Base.RefValue{Any}(nothing)
    free_dofs, fixed_dofs, bc_diagnostics = compute_free_dofs(
        K, ndof, model, id_map, spc_id, rbe3_map; return_diagnostics=true,
        trial_factor_out=trial_ref,
        allow_factorization_autospc=allow_factorization_autospc)
    K_ff = K[free_dofs, free_dofs]

    # Trial-factor keep (perf deferred item #12, env-flagged): the partition
    # stability trial inside compute_free_dofs already paid a full Cholesky
    # of Symmetric(K_ff). When K_ff is BITWISE symmetric, the symmetrization
    # below is exact identity (0.5*(x+x) == x in IEEE), so that trial factor
    # IS a factor of the matrix ensure_eigen_solve_factorization! would
    # otherwise re-factor — keep it and skip both the two nnz-sized
    # symmetrization temporaries and the second factorization. For
    # asymmetric K_ff the trial factored a (ulp-)different matrix: discard.
    # Default ON 2026-08-06: gate showed cholesky(Symmetric(X)) and
    # cholesky(X) produce identical downstream results on the full suite
    # (field diff exactly equal at rtol=0) and battery (hash-identical).
    keep_trial = solver_env_bool("JFEM_EIGEN_TRIAL_FACTOR_KEEP", true) &&
                 trial_ref[] !== nothing && issymmetric(K_ff)
    keep_trial || (K_ff = 0.5 * (K_ff + K_ff'))

    entry = EigenSolveCacheEntry(
        copy(free_dofs),
        copy(fixed_dofs),
        deepcopy(bc_diagnostics),
        K_ff,
        keep_trial ? trial_ref[] : nothing,
        keep_trial ? "cholesky" : "",
        nothing,
    )

    if cache_enabled && cache_key !== nothing
        eigen_cache[cache_key] = entry
    end

    return entry, false
end

function ensure_eigen_solve_factorization!(entry::EigenSolveCacheEntry)
    cache_hit = entry.factor !== nothing
    if !cache_hit
        # K_ff is SPD for a well-posed problem → Cholesky is the fast path.
        # If it fails (rigid-body modes, mechanism, bad element), fall back to
        # LU rather than letting PosDefException bubble up and abort the solve.
        backend = "cholesky"
        f = try
            cholesky(entry.K_ff)
        catch e
            if e isa LinearAlgebra.PosDefException ||
               e isa LinearAlgebra.SingularException ||
               e isa LinearAlgebra.ZeroPivotException
                log_msg("[EIGEN] Cholesky failed ($(typeof(e))); falling back to LU. Check model constraints.")
                backend = "lu"
                lu(entry.K_ff)
            else
                rethrow(e)
            end
        end
        entry.factor = f
        entry.factor_backend = backend
    end
    return entry.factor, cache_hit
end

function seed_eigen_solve_cache_from_linear!(eigen_cache, linear_cache, K, ndof::Int, model, spc_id, rbe3_map)
    eigen_cache === nothing && return false
    linear_cache === nothing && return false
    ndof >= eigen_solve_cache_min_ndof() || return false

    linear_key = _linear_solve_cache_key(K, ndof, model, spc_id, rbe3_map)
    linear_entry = get(linear_cache, linear_key, nothing)
    linear_entry === nothing && return false

    eigen_key = _eigen_solve_cache_key(K, ndof, model, spc_id, rbe3_map)
    haskey(eigen_cache, eigen_key) && return false

    solver_diag = get(linear_entry.diagnostics, "linear_solver", Dict{String,Any}())
    linear_backend = lowercase(string(get(solver_diag, "backend", "")))
    factor_backend =
        occursin("cholesky", linear_backend) ? "cholesky" :
        (occursin("lu", linear_backend) ? "lu" : "")
    isempty(factor_backend) && return false

    eigen_cache[eigen_key] = EigenSolveCacheEntry(
        copy(linear_entry.free_dofs),
        copy(linear_entry.fixed_dofs),
        deepcopy(get(linear_entry.diagnostics, "bc_partition", Dict{String,Any}())),
        linear_entry.K_ff,
        linear_entry.factor,
        factor_backend,
        nothing,
    )
    return true
end

function _singular_lu_regularization_exponents()
    first_exp = solver_env_int("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MIN_EXP", -14)
    last_exp = solver_env_int("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MAX_EXP", -6)
    step = max(abs(solver_env_int("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_EXP_STEP", 2)), 1)
    if first_exp <= last_exp
        return collect(first_exp:step:last_exp)
    end
    return collect(first_exp:-step:last_exp)
end

@inline function _singular_solver_mode()
    return lowercase(strip(get(ENV, "JFEM_SOL101_SINGULAR_SOLVER", "regularized_lu")))
end

@inline function _lsmr_maxiter(n::Int)
    default_iter = min(max(2 * n, 1000), 10000)
    return max(solver_env_int("JFEM_SOL101_LSMR_MAXITER", default_iter), 1)
end

function _diag_scaled_sparse_copy(K::SparseMatrixCSC{Float64,Int}, scale::AbstractVector{Float64})
    Ks = copy(K)
    rows = rowvals(Ks)
    vals = nonzeros(Ks)
    @inbounds for col in 1:size(Ks, 2)
        col_scale = scale[col]
        for p in nzrange(Ks, col)
            vals[p] *= scale[rows[p]] * col_scale
        end
    end
    return Ks
end

function _lsmr_singular_solve(K_ff::SparseMatrixCSC{Float64,Int}, F_ff::Vector{Float64},
                              diagnostics::Dict{String,Any}, backend::String;
                              scaled::Bool=false)
    atol = max(solver_env_float("JFEM_SOL101_LSMR_ATOL", 1e-8), 0.0)
    btol = max(solver_env_float("JFEM_SOL101_LSMR_BTOL", 1e-8), 0.0)
    conlim = max(solver_env_float("JFEM_SOL101_LSMR_CONLIM", 1e12), 0.0)
    damping = max(solver_env_float("JFEM_SOL101_LSMR_DAMPING", 0.0), 0.0)
    maxiter = _lsmr_maxiter(size(K_ff, 2))

    diagnostics["linear_solver"]["backend"] = backend * (scaled ? "_scaled_lsmr" : "_lsmr")
    diagnostics["linear_solver"]["used_lsmr_fallback"] = true
    diagnostics["linear_solver"]["lsmr_scaled"] = scaled
    diagnostics["linear_solver"]["lsmr_atol"] = atol
    diagnostics["linear_solver"]["lsmr_btol"] = btol
    diagnostics["linear_solver"]["lsmr_conlim"] = conlim
    diagnostics["linear_solver"]["lsmr_damping"] = damping
    diagnostics["linear_solver"]["lsmr_maxiter"] = maxiter
    log_msg("[SOLVER] Singular solve using $(scaled ? "scaled " : "")LSMR: atol=$atol, btol=$btol, conlim=$conlim, damping=$damping, maxiter=$maxiter")

    if scaled
        diag_abs = abs.(collect(diag(K_ff)))
        diag_max = max(maximum(diag_abs; init=0.0), 1.0)
        floor_rel = max(solver_env_float("JFEM_SOL101_LSMR_DIAG_FLOOR_REL", 1e-12), 0.0)
        diag_floor = max(diag_max * floor_rel, eps(Float64))
        dscale = max.(diag_abs, diag_floor)
        inv_sqrt_d = 1.0 ./ sqrt.(dscale)
        K_scaled = _diag_scaled_sparse_copy(K_ff, inv_sqrt_d)
        F_scaled = inv_sqrt_d .* F_ff
        diagnostics["linear_solver"]["lsmr_diag_scale_min"] = minimum(dscale)
        diagnostics["linear_solver"]["lsmr_diag_scale_max"] = maximum(dscale)
        diagnostics["linear_solver"]["lsmr_diag_floor"] = diag_floor
        y = lsmr(K_scaled, F_scaled; atol=atol, btol=btol, conlim=conlim,
                 maxiter=maxiter, log=false, λ=damping)
        return nothing, inv_sqrt_d .* y
    else
        u = lsmr(K_ff, F_ff; atol=atol, btol=btol, conlim=conlim,
                 maxiter=maxiter, log=false, λ=damping)
        return nothing, u
    end
end

@inline function _auto_lsmr_residual_threshold()
    return max(solver_env_float("JFEM_SOL101_AUTO_LSMR_RESIDUAL_REL_MAX", 1e-4), 0.0)
end

function _singular_solution_relative_residual(K_ff::SparseMatrixCSC{Float64,Int},
                                              F_ff::Vector{Float64},
                                              u::Vector{Float64})
    residual = K_ff * u - F_ff
    r_norm = norm(residual)
    return r_norm, r_norm / max(norm(F_ff), 1e-30)
end

function _auto_lsmr_singular_candidate(K_ff::SparseMatrixCSC{Float64,Int}, F_ff::Vector{Float64},
                                       diagnostics::Dict{String,Any}, backend::String;
                                       scaled::Bool=false)
    threshold = _auto_lsmr_residual_threshold()
    diagnostics["linear_solver"]["auto_lsmr_threshold"] = threshold
    diagnostics["linear_solver"]["auto_lsmr_scaled"] = scaled
    try
        _, u = _lsmr_singular_solve(K_ff, F_ff, diagnostics, backend; scaled=scaled)
        r_norm, rel = _singular_solution_relative_residual(K_ff, F_ff, u)
        diagnostics["linear_solver"]["auto_lsmr_residual_norm"] = r_norm
        diagnostics["linear_solver"]["auto_lsmr_relative_residual"] = rel
        accepted = rel <= threshold
        diagnostics["linear_solver"]["auto_lsmr_accepted"] = accepted
        if accepted
            diagnostics["linear_solver"]["backend"] = backend * (scaled ? "_auto_scaled_lsmr" : "_auto_lsmr")
            log_msg("[SOLVER] Auto singular LSMR accepted: rel_residual=$rel <= $threshold")
            return true, nothing, u
        end
        diagnostics["linear_solver"]["used_lsmr_fallback"] = false
        diagnostics["linear_solver"]["lsmr_scaled"] = false
        log_msg("[SOLVER] Auto singular LSMR rejected: rel_residual=$rel > $threshold; using regularized LU")
    catch lsmr_err
        diagnostics["linear_solver"]["auto_lsmr_accepted"] = false
        diagnostics["linear_solver"]["auto_lsmr_error"] = sprint(showerror, lsmr_err)
        diagnostics["linear_solver"]["used_lsmr_fallback"] = false
        diagnostics["linear_solver"]["lsmr_scaled"] = false
        log_msg("[SOLVER] Auto singular LSMR failed ($(typeof(lsmr_err))); using regularized LU")
    end
    return false, nothing, zeros(size(F_ff))
end

function _singular_lu_regularization_matrix(K_ff::SparseMatrixCSC{Float64,Int},
                                            max_elem_stiff::Float64,
                                            exp::Int,
                                            diagnostics::Dict{String,Any})
    mode = lowercase(strip(get(ENV, "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MODE", "global")))
    diagnostics["linear_solver"]["regularization_mode"] = mode
    abs_shift = max(solver_env_float("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_ABS_SHIFT", 0.0), 0.0)
    if abs_shift > 0.0
        diagnostics["linear_solver"]["regularization_shift_source"] = "explicit_absolute"
        diagnostics["linear_solver"]["regularization_shift"] = abs_shift
        diagnostics["linear_solver"]["regularization_shift_min"] = abs_shift
        diagnostics["linear_solver"]["regularization_shift_max"] = abs_shift
        return abs_shift * spdiagm(0 => ones(size(K_ff, 1)))
    end
    rel_shift = max(solver_env_float("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_REL_SHIFT", 0.0), 0.0)
    if rel_shift > 0.0
        diag_scale = max(max_elem_stiff, mapreduce(abs, max, diag(K_ff); init=0.0), 1.0)
        shift = diag_scale * rel_shift
        diagnostics["linear_solver"]["regularization_shift_source"] = "explicit_relative"
        diagnostics["linear_solver"]["regularization_shift"] = shift
        diagnostics["linear_solver"]["regularization_shift_min"] = shift
        diagnostics["linear_solver"]["regularization_shift_max"] = shift
        return shift * spdiagm(0 => ones(size(K_ff, 1)))
    end
    if mode in ("diagonal", "diag", "diagonal_relative", "diag_relative")
        diag_abs = map(abs, diag(K_ff))
        shifts = max.(diag_abs, 1.0) .* 10.0^exp
        diagnostics["linear_solver"]["regularization_shift_source"] = "exponent_diagonal"
        diagnostics["linear_solver"]["regularization_shift_min"] = minimum(shifts)
        diagnostics["linear_solver"]["regularization_shift_max"] = maximum(shifts)
        return spdiagm(0 => shifts)
    end

    diag_scale = max(max_elem_stiff, mapreduce(abs, max, diag(K_ff); init=0.0), 1.0)
    shift = diag_scale * 10.0^exp
    diagnostics["linear_solver"]["regularization_shift_source"] = "exponent_global"
    diagnostics["linear_solver"]["regularization_shift"] = shift
    diagnostics["linear_solver"]["regularization_shift_min"] = shift
    diagnostics["linear_solver"]["regularization_shift_max"] = shift
    return shift * spdiagm(0 => ones(size(K_ff, 1)))
end

function _lu_or_regularized_solve(K_ff::SparseMatrixCSC{Float64,Int}, F_ff::Vector{Float64},
                                  max_elem_stiff::Float64, diagnostics::Dict{String,Any},
                                  backend::String)
    try
        F_lu = lu(K_ff)
        diagnostics["linear_solver"]["backend"] = backend
        diagnostics["linear_solver"]["used_lu_fallback"] = true
        return F_lu, F_lu \ F_ff
    catch err
        if !(err isa LinearAlgebra.SingularException)
            rethrow(err)
        end
        mode = _singular_solver_mode()
        diagnostics["linear_solver"]["singular_solver_mode"] = mode
        if mode in ("lsmr", "minimum_norm", "minnorm", "least_squares", "least_squares_lsmr")
            return _lsmr_singular_solve(K_ff, F_ff, diagnostics, backend; scaled=false)
        elseif mode in ("scaled_lsmr", "equilibrated_lsmr", "diag_scaled_lsmr")
            return _lsmr_singular_solve(K_ff, F_ff, diagnostics, backend; scaled=true)
        elseif mode in ("auto_lsmr", "compatible_lsmr", "range_lsmr")
            accepted, F_auto, u_auto = _auto_lsmr_singular_candidate(
                K_ff, F_ff, diagnostics, backend; scaled=false)
            accepted && return F_auto, u_auto
        elseif mode in ("auto_scaled_lsmr", "compatible_scaled_lsmr", "range_scaled_lsmr")
            accepted, F_auto, u_auto = _auto_lsmr_singular_candidate(
                K_ff, F_ff, diagnostics, backend; scaled=true)
            accepted && return F_auto, u_auto
        end
        solver_env_bool("JFEM_SOL101_SINGULAR_LU_REGULARIZATION", true) || rethrow(err)

        diagnostics["linear_solver"]["used_singular_lu_regularization"] = true
        last_err = err
        for exp in _singular_lu_regularization_exponents()
            try
                D_reg = _singular_lu_regularization_matrix(K_ff, max_elem_stiff, exp, diagnostics)
                K_reg = K_ff + D_reg
                F_reg = lu(K_reg)
                diagnostics["linear_solver"]["backend"] = backend * "_regularized"
                diagnostics["linear_solver"]["used_lu_fallback"] = true
                diagnostics["linear_solver"]["regularization_shift_exponent"] = exp
                shift_min = diagnostics["linear_solver"]["regularization_shift_min"]
                shift_max = diagnostics["linear_solver"]["regularization_shift_max"]
                mode = diagnostics["linear_solver"]["regularization_mode"]
                log_msg("[SOLVER] Singular LU regularization succeeded with mode=$(mode), shift_range=[$(shift_min), $(shift_max)] (1e$exp scale)")
                return F_reg, F_reg \ F_ff
            catch reg_err
                last_err = reg_err
            end
        end
        throw(last_err)
    end
end

function _free_dofs_from_fixed_set(ndof::Int, fixed_dofs::Set{Int})
    n_fixed = count(d -> 1 <= d <= ndof, fixed_dofs)
    free_dofs = Vector{Int}(undef, max(ndof - n_fixed, 0))
    next_idx = 1
    @inbounds for dof in 1:ndof
        if !(dof in fixed_dofs)
            free_dofs[next_idx] = dof
            next_idx += 1
        end
    end
    return free_dofs
end


function _autospc_model_sol_type(model)
    cc = get(model, "CASE_CONTROL", Dict{String,Any}())
    raw = get(model, "SOL", get(cc, "SOL", 101))
    if raw isa Integer
        return Int(raw)
    elseif raw isa AbstractString
        m = match(r"\d+", raw)
        m === nothing && return 101
        return parse(Int, m.match)
    elseif raw isa Number
        return round(Int, raw)
    end
    return 101
end

@inline function _autospc_is_sol101(model)
    return _autospc_model_sol_type(model) == 101
end

@inline function sol101_load_path_autospc_protect_enabled(model)
    return model !== nothing &&
           _autospc_is_sol101(model) &&
           solver_env_bool("JFEM_SOL101_AUTOSPC_LOAD_PATH_PROTECT", false)
end

@inline function sol101_factorization_probe_check_false_enabled(model)
    return model !== nothing &&
           _autospc_is_sol101(model) &&
           solver_env_bool("JFEM_SOL101_FACTOR_AUTOSPC_CHECK_FALSE", false)
end


@inline function sol101_factorization_autospc_allow_trans_enabled(model)
    if haskey(ENV, "JFEM_FACTOR_AUTOSPC_ALLOW_TRANSLATIONAL")
        return solver_env_bool("JFEM_FACTOR_AUTOSPC_ALLOW_TRANSLATIONAL", true)
    end
    return !(model !== nothing && _autospc_is_sol101(model)) ||
           solver_env_bool("JFEM_SOL101_FACTOR_AUTOSPC_ALLOW_TRANSLATIONAL", false)
end


@inline function sol101_factorization_autospc_shift_multiplier()
    return max(solver_env_float("JFEM_SOL101_FACTOR_AUTOSPC_PIVOT_SHIFT_MUL", 3.0), 0.0)
end

@inline function sol101_factorization_autospc_median_relative()
    return max(solver_env_float("JFEM_SOL101_FACTOR_AUTOSPC_PIVOT_MEDIAN_REL", 1e-4), 0.0)
end

@inline function sol101_factorization_autospc_max_fraction()
    return clamp(solver_env_float("JFEM_SOL101_FACTOR_AUTOSPC_MAX_FRACTION", 0.5), 0.0, 1.0)
end

@inline function autospc_trans_relative_threshold(model=nothing)
    return max(solver_env_float("JFEM_AUTOSPC_TRANS_REL", 1e-8), 0.0)
end

function autospc_rot_relative_threshold(model=nothing)
    default = model !== nothing && _autospc_model_sol_type(model) == 103 ?
        1e-14 : autospc_trans_relative_threshold(model)
    if haskey(ENV, "JFEM_AUTOSPC_ROT_REL")
        return max(solver_env_float("JFEM_AUTOSPC_ROT_REL", default), 0.0)
    end
    # A global rotational reference can be many orders of magnitude larger
    # than the local shell-drilling stiffness.  In SOL103 the former 1e-8
    # default then constrained legitimate shell rotations on large mixed
    # models.  A 1e-14 modal floor retains only numerical-zero rotations in a
    # validated large mixed shell/beam audit; other solution sequences retain
    # the historical threshold until they have their own parity audit. GPST keeps its
    # independent EPZERO-scale test below.
    return default
end

"""
    autospc_gpst_relative_threshold(model=nothing)

Relative eigenvalue threshold (Nastran `EPZERO`) used by grid-point
singularity processing. `JFEM_AUTOSPC_GPST_REL` has highest precedence,
followed by a numeric deck `PARAM,EPZERO`; when neither is present, use the
translational AUTOSPC threshold (historically `1e-8`).
Invalid or non-finite values fall back safely and negative values clamp to zero.
"""
function autospc_gpst_relative_threshold(model=nothing)
    fallback = autospc_trans_relative_threshold(model)
    deck_default = fallback

    if model !== nothing && haskey(model, "PARAM_EPZERO")
        raw = model["PARAM_EPZERO"]
        parsed = try
            raw isa Number ? Float64(raw) : tryparse(Float64, strip(string(raw)))
        catch
            nothing
        end
        if parsed !== nothing && isfinite(parsed)
            deck_default = max(parsed, 0.0)
        end
    end

    value = solver_env_float("JFEM_AUTOSPC_GPST_REL", deck_default)
    return isfinite(value) ? max(value, 0.0) : deck_default
end

@inline function gpst_enabled()
    return solver_env_bool("JFEM_AUTOSPC_GRID_POINT_SINGULARITY", true)
end

"""
Whether the directional singularity test also runs on the 3x3 TRANSLATIONAL
block. Default ON, matching the reference solver, which tests both blocks.

Validated against purpose-built reference runs under
`VALIDATION_FILES/GRID_POINT_SINGULARITY_2026_08_04/` -- rods and bars, since a
pure-shell deck cannot produce a translational singularity. A single rod resists
only along its own axis, so its free node's translational stiffness is rank 1
with a two-dimensional null space; three rods spanning an oblique plane leave a
one-dimensional null space along that plane's normal, which no DOF axis lies
near and which therefore no per-DOF diagonal test can find.
"""
@inline function gpst_translational_enabled()
    return solver_env_bool("JFEM_AUTOSPC_GRID_POINT_SINGULARITY_TRANS", true)
end

"""
    _grid_point_singularity_autospc!(fixed_dofs, spc_dofs, K, ndof, model, id_map, protected_trans_dofs)

Nastran-equivalent grid point singularity processing.

The pre-existing `_diagonal_autospc!` tests one DOF at a time against its own
diagonal. That cannot see a singular *direction* which is not aligned with a DOF
axis -- and on a shell whose normal is oblique to the global axes, the
drilling direction never is. The reference solver instead tests, at each grid,
the 3x3 translational and 3x3 rotational stiffness blocks as a whole: it
eigen-decomposes each block, forms the ratio of each eigenvalue to that block's
largest, and any direction whose ratio falls below `EPZERO` is singular and is
moved from the free set to the SPC set. Its `GRID POINT SINGULARITY TABLE`
reports the failed direction as the DOF the singular eigenvector lies closest
to.

Worked example that pins the semantics -- the MacNeal twisted beam at
`PARAM,K6ROT,0.`, whose section rotates 90 degrees from root to tip. The
reference AUTOSPCs 24 directions, and the reported DOF migrates from 6 to 5 as
the shell normal swings from global Z to global Y:

    grids  3..12  ->  failed direction 6, ratios 3.29e-11 .. 3.76e-11
    grids 13..26  ->  failed direction 5, ratios 0.00e+00 .. 3.76e-11

A diagonal test finds almost none of these, which is why an earlier
investigation concluded the mechanisms were OpenJFEM's own. They are not; they
are inherent to any quad without a genuine drilling formulation once the
drilling spring is removed, and the reference simply processes them.

Runs *after* `_diagonal_autospc!` and only over DOFs still free, so it is purely
additive. Fully constrained grids are skipped, matching the reference (the
clamped root grids are absent from its table).
"""
function _grid_point_singularity_autospc!(fixed_dofs::Set{Int}, spc_dofs::Union{Nothing,Set{Int}},
                                          K, ndof, model, id_map,
                                          protected_trans_dofs::Union{Nothing,Set{Int}}=nothing)
    eps_zero = autospc_gpst_relative_threshold(model)
    n_nodes = div(ndof, 6)
    n_trans = 0
    n_rot = 0
    entries = Vector{NTuple{3,Any}}()   # (grid_id, failed dof 1..6, stiffness ratio)
    inv_id_map = _autospc_inverse_id_map(id_map)

    do_trans = gpst_translational_enabled()
    blk = zeros(Float64, 3, 3)
    for node_idx in 1:n_nodes
        base = (node_idx - 1) * 6
        for (offset, is_rot) in ((0, false), (3, true))
            (is_rot || do_trans) || continue
            # Only the DOFs of this block that are still free participate; a
            # partially constrained grid is tested on its remaining subspace.
            free_local = Int[]
            for a in 1:3
                gdof = base + offset + a
                gdof <= ndof || continue
                (gdof in fixed_dofs) && continue
                push!(free_local, a)
            end
            length(free_local) >= 1 || continue

            m = length(free_local)
            @inbounds for ii in 1:m, jj in 1:m
                blk[ii, jj] = Float64(K[base + offset + free_local[ii],
                                        base + offset + free_local[jj]])
            end
            sub = @view blk[1:m, 1:m]
            # Symmetrise defensively; K is symmetric up to assembly roundoff.
            S = Symmetric((Matrix(sub) .+ transpose(Matrix(sub))) ./ 2)
            local vals, vecs
            try
                F = eigen(S)
                vals = F.values
                vecs = F.vectors
            catch
                continue
            end
            lam_max = maximum(abs, vals)
            lam_max > 0.0 || continue

            claimed = Set{Int}()
            for k in 1:m
                ratio = abs(vals[k]) / lam_max
                ratio < eps_zero || continue
                # Constrain the DOF the singular eigenvector lies closest to,
                # which is what the reference's table records. Ties, and the
                # ordering within a degenerate null space, are broken by lowest
                # DOF index so that OpenJFEM is at least deterministic.
                #
                # A caveat that the reference's own output forces, and that no
                # implementation can remove: when the null space has dimension
                # > 1 its eigenvector basis is arbitrary, so WHICH DOFs get
                # constrained is not a property of the method. The reference
                # picks {1,3} for a rod along (1,1,1) in one deck and {2,3} for
                # the identical rod direction in another. Both leave the axial
                # load path intact -- and both return a displacement along the
                # single surviving DOF rather than along the rod. Only the COUNT
                # of constrained directions, and the choice when the null space
                # is one-dimensional, are reproducible.
                best_a, best_w = 0, -1.0
                for ii in 1:m
                    w = abs(vecs[ii, k])
                    a = free_local[ii]
                    (a in claimed) && continue
                    if w > best_w + 1e-12
                        best_w, best_a = w, a
                    end
                end
                best_a == 0 && continue
                gdof = base + offset + best_a
                (gdof in fixed_dofs) && continue
                if !is_rot && protected_trans_dofs !== nothing && (gdof in protected_trans_dofs)
                    continue
                end
                push!(claimed, best_a)
                push!(fixed_dofs, gdof)
                !isnothing(spc_dofs) && push!(spc_dofs, gdof)
                is_rot ? (n_rot += 1) : (n_trans += 1)
                gid = 1 <= node_idx <= length(inv_id_map) ? inv_id_map[node_idx] : 0
                push!(entries, (gid, offset + best_a, ratio))
            end
        end
    end

    return Dict(
        "dofs" => n_trans + n_rot,
        "translational_dofs" => n_trans,
        "rotational_dofs" => n_rot,
        "eps_zero" => eps_zero,
        "entries" => entries,
    )
end

function _load_path_add_components!(node_components::Dict{Int,Set{Int}}, node_idx::Int, comps)
    node_idx > 0 || return
    comp_set = get!(node_components, node_idx, Set{Int}())
    for comp_raw in comps
        comp = Int(comp_raw)
        1 <= comp <= 3 && push!(comp_set, comp)
    end
end

function _load_path_element_components(nodes, loaded_components::Dict{Int,Set{Int}}, id_map)
    comps = Set{Int}()
    for nid in nodes
        idx = get(id_map, nid, 0)
        idx > 0 || continue
        node_loaded = get(loaded_components, idx, nothing)
        node_loaded === nothing && continue
        union!(comps, node_loaded)
    end
    return comps
end

function _load_path_protect_element_nodes!(protected_components::Dict{Int,Set{Int}},
                                           loaded_components::Dict{Int,Set{Int}},
                                           nodes, id_map)
    comps = _load_path_element_components(nodes, loaded_components, id_map)
    isempty(comps) && return false
    for nid in nodes
        _load_path_add_components!(protected_components, get(id_map, nid, 0), comps)
    end
    return true
end

function _build_sol101_load_path_protected_trans_dofs(F_applied, ndof::Int, model, id_map)
    diagnostics = Dict{String,Any}(
        "enabled" => sol101_load_path_autospc_protect_enabled(model),
        "loaded_translational_dofs" => 0,
        "loaded_nodes" => 0,
        "protected_translational_dofs" => 0,
        "protected_nodes" => 0,
        "connected_elements" => 0,
        "force_tolerance" => 0.0,
    )
    diagnostics["enabled"] || return nothing, diagnostics

    force_max = mapreduce(abs, max, F_applied; init=0.0)
    force_rel = max(solver_env_float("JFEM_SOL101_AUTOSPC_LOAD_PATH_FORCE_REL", 1e-12), 0.0)
    force_abs = max(solver_env_float("JFEM_SOL101_AUTOSPC_LOAD_PATH_FORCE_ABS", 1e-9), 0.0)
    force_tol = max(force_abs, force_rel * max(force_max, 1.0))
    diagnostics["force_tolerance"] = force_tol

    loaded_components = Dict{Int,Set{Int}}()
    stop_dof = min(ndof, length(F_applied))
    @inbounds for gdof in 1:stop_dof
        comp = mod(gdof - 1, 6) + 1
        comp <= 3 || continue
        abs(F_applied[gdof]) > force_tol || continue
        node_idx = div(gdof - 1, 6) + 1
        _load_path_add_components!(loaded_components, node_idx, (comp,))
    end

    loaded_dofs = sum(length(comps) for comps in values(loaded_components); init=0)
    diagnostics["loaded_translational_dofs"] = loaded_dofs
    diagnostics["loaded_nodes"] = length(loaded_components)
    if isempty(loaded_components)
        return Set{Int}(), diagnostics
    end

    protected_components = Dict{Int,Set{Int}}()
    for (node_idx, comps) in loaded_components
        _load_path_add_components!(protected_components, node_idx, comps)
    end

    connected_elements = 0
    for group_name in ("CSHELLs", "CSOLIDs")
        for (_, el) in get(model, group_name, Dict())
            nodes = get(el, "NODES", Int[])
            connected_elements += _load_path_protect_element_nodes!(
                protected_components, loaded_components, nodes, id_map) ? 1 : 0
        end
    end

    for group_name in ("CBARs", "CBEAMs", "CRODs", "CONRODs", "CBUSHs")
        for (_, el) in get(model, group_name, Dict())
            nodes = Int[]
            ga = get(el, "GA", 0)
            gb = get(el, "GB", 0)
            ga != 0 && push!(nodes, ga)
            gb != 0 && push!(nodes, gb)
            connected_elements += _load_path_protect_element_nodes!(
                protected_components, loaded_components, nodes, id_map) ? 1 : 0
        end
    end

    for (_, el) in get(model, "CELASs", Dict())
        nodes = Int[]
        g1 = get(el, "G1", 0)
        g2 = get(el, "G2", 0)
        g1 != 0 && push!(nodes, g1)
        g2 != 0 && push!(nodes, g2)
        connected_elements += _load_path_protect_element_nodes!(
            protected_components, loaded_components, nodes, id_map) ? 1 : 0
    end

    protected_dofs = Set{Int}()
    for (node_idx, comps) in protected_components
        for comp in comps
            push!(protected_dofs, (node_idx - 1) * 6 + comp)
        end
    end

    diagnostics["protected_translational_dofs"] = length(protected_dofs)
    diagnostics["protected_nodes"] = length(protected_components)
    diagnostics["connected_elements"] = connected_elements
    return protected_dofs, diagnostics
end

@inline function autospc_audit_csv_path()
    return strip(get(ENV, "JFEM_AUTOSPC_AUDIT_CSV", ""))
end

function _autospc_inverse_id_map(id_map)
    inv_id_map = zeros(Int, length(id_map))
    for (gid, idx_raw) in id_map
        idx = Int(idx_raw)
        if 1 <= idx <= length(inv_id_map)
            inv_id_map[idx] = gid isa Integer ? Int(gid) : parse(Int, string(gid))
        end
    end
    return inv_id_map
end

@inline function _autospc_component_name(dof_local::Int)
    dof_local <= 3 && return "T$dof_local"
    return "R$(dof_local - 3)"
end

function _open_autospc_audit_csv(path::AbstractString)
    isempty(path) && return nothing, ""
    abs_path = abspath(path)
    try
        mkpath(dirname(abs_path))
        io = open(abs_path, "w")
        println(io, join((
            "global_dof",
            "grid_id",
            "component",
            "dof_class",
            "k_diagonal",
            "abs_k_diagonal",
            "max_k_reference",
            "relative_threshold",
            "effective_threshold",
            "reason",
        ), ","))
        return io, abs_path
    catch err
        @warn "Could not open JFEM_AUTOSPC_AUDIT_CSV; AUTOSPC audit disabled" path exception=(err, catch_backtrace())
        return nothing, ""
    end
end

function _write_autospc_audit_row(io, i::Int, gid::Int, dof_local::Int, k_diag::Float64,
                                  max_K_ref::Float64, rel_thresh::Float64, thresh::Float64,
                                  reason::AbstractString)
    io === nothing && return
    dof_class = dof_local <= 3 ? "translation" : "rotation"
    println(io, join((
        i,
        gid,
        _autospc_component_name(dof_local),
        dof_class,
        k_diag,
        abs(k_diag),
        max_K_ref,
        rel_thresh,
        thresh,
        reason,
    ), ","))
end


function _diagonal_autospc!(fixed_dofs::Set{Int}, spc_dofs::Union{Nothing,Set{Int}}, K, ndof, model, id_map,
                            protected_trans_dofs::Union{Nothing,Set{Int}}=nothing)
    autospc_rel_trans = autospc_trans_relative_threshold(model)
    autospc_rel_rot = autospc_rot_relative_threshold(model)
    max_K_trans = maximum((abs(K[i, i]) for i in 1:ndof if mod(i - 1, 6) + 1 <= 3); init=1.0)
    max_K_rot = maximum((abs(K[i, i]) for i in 1:ndof if mod(i - 1, 6) + 1 > 3); init=1.0)


    n_autospc = 0
    n_autospc_trans = 0
    n_autospc_rot = 0
    n_load_path_skipped = 0
    negative_diagonal_enabled = autospc_negative_diagonal_enabled()

    audit_io, audit_path = _open_autospc_audit_csv(autospc_audit_csv_path())
    inv_id_map = audit_io === nothing ? Int[] : _autospc_inverse_id_map(id_map)

    try
        for i in 1:ndof
            dof_local = mod(i - 1, 6) + 1
            node_idx = div(i - 1, 6) + 1
            max_K_ref = dof_local <= 3 ? max_K_trans : max_K_rot
            rel_thresh = dof_local <= 3 ? autospc_rel_trans : autospc_rel_rot
            thresh = rel_thresh * max(max_K_ref, 1.0)
            k_diag = Float64(K[i, i])
            is_below_threshold = abs(k_diag) < thresh
            raw_negative = k_diag < 0
            is_negative = negative_diagonal_enabled && raw_negative
            if !(i in fixed_dofs) && (is_below_threshold || is_negative)
                if dof_local <= 3 &&
                   !is_negative &&
                   protected_trans_dofs !== nothing &&
                   (i in protected_trans_dofs)
                    n_load_path_skipped += 1
                    continue
                end
                push!(fixed_dofs, i)
                !isnothing(spc_dofs) && push!(spc_dofs, i)
                n_autospc += 1
                if dof_local <= 3
                    n_autospc_trans += 1
                else
                    n_autospc_rot += 1
                end

                if audit_io !== nothing
                    gid = 1 <= node_idx <= length(inv_id_map) ? inv_id_map[node_idx] : 0
                    reason = is_negative ? "negative_diagonal" : "below_threshold"
                    _write_autospc_audit_row(
                        audit_io, i, gid, dof_local, k_diag, max_K_ref, rel_thresh, thresh,
                        reason,
                    )
                end
            end
        end
    finally
        if audit_io !== nothing
            close(audit_io)
        end
    end

    return Dict(
        "dofs" => n_autospc,
        "translational_dofs" => n_autospc_trans,
        "rotational_dofs" => n_autospc_rot,
        "rel_threshold" => autospc_rel_trans,
        "rel_threshold_trans" => autospc_rel_trans,
        "rel_threshold_rot" => autospc_rel_rot,
        "max_K_trans" => max_K_trans,
        "max_K_rot" => max_K_rot,
        "audit_csv" => audit_path,
        "load_path_protected_translational_dofs" =>
            protected_trans_dofs === nothing ? 0 : length(protected_trans_dofs),
        "load_path_autospc_skipped_dofs" => n_load_path_skipped,
        "negative_diagonal_rule_enabled" => negative_diagonal_enabled,
    )
end

function factorization_autospc_free_dofs(K, ndof, fixed_dofs::Set{Int})
    diagnostics = Dict{String,Any}(
        "triggered" => false,
        "mechanism_dofs" => 0,
        "mechanism_translational_dofs" => 0,
        "mechanism_rotational_dofs" => 0,
        "shift_exponent" => nothing,
        "skipped_as_too_aggressive" => false,
    )

    free_dofs = _free_dofs_from_fixed_set(ndof, fixed_dofs)
    isempty(free_dofs) && return free_dofs, 0, diagnostics, nothing

    K_ff = K[free_dofs, free_dofs]
    try
        # The stability trial is a FULL Cholesky of the eigen-partition K_ff.
        # Hand the successful factor back so the caller can keep it instead
        # of paying a second, identical factorization (trial-factor keep,
        # perf program deferred item #12).
        F_trial = cholesky(Symmetric(K_ff))
        return free_dofs, 0, diagnostics, F_trial
    catch
    end

    max_diag = maximum((abs(K[d, d]) for d in free_dofs); init=1.0)
    max_diag = max(max_diag, 1.0)
    n_mechanism_total = 0

    for shift_exp in (-12, -10, -8, -6)
        shift_val = max_diag * 10.0^shift_exp
        try
            diagnostics["triggered"] = true
            diagnostics["shift_exponent"] = shift_exp

            F_chol_probe = cholesky(Symmetric(K_ff); shift=shift_val)
            # diag(F) reads the factor diagonal without materializing L
            # (bit-identical to diag(sparse(F.L)); 19x measured at 48k DOF,
            # and skips a transient copy of the full fill-in).
            L_diag = abs.(diag(F_chol_probe))
            L_median = median(L_diag)
            pivot_threshold = min(sqrt(shift_val) * 3.0, L_median * 1e-4)
            small_pivot_mask = L_diag .< pivot_threshold
            n_mechanism = count(small_pivot_mask)

            if n_mechanism > length(free_dofs) * 0.5
                diagnostics["mechanism_dofs"] = n_mechanism
                diagnostics["skipped_as_too_aggressive"] = true
                log_msg("[BUCKLING] Factorization AUTOSPC (shift=1e$shift_exp): $n_mechanism DOFs (>50% of $(length(free_dofs)) free) - threshold too aggressive, skipping")
                break
            end

            if n_mechanism > 0
                perm = F_chol_probe.p
                mechanism_local = findall(small_pivot_mask)
                mechanism_original = perm[mechanism_local]
                mechanism_global = free_dofs[mechanism_original]
                n_mech_trans = count(d -> mod(d - 1, 6) + 1 <= 3, mechanism_global)
                n_mech_rot = n_mechanism - n_mech_trans
                diagnostics["mechanism_dofs"] = n_mechanism
                diagnostics["mechanism_translational_dofs"] = n_mech_trans
                diagnostics["mechanism_rotational_dofs"] = n_mech_rot
                log_msg("[BUCKLING] Factorization AUTOSPC (shift=1e$shift_exp): Found $n_mechanism DOFs ($n_mech_trans trans + $n_mech_rot rot)")
                for d in mechanism_global
                    push!(fixed_dofs, d)
                end
                n_mechanism_total = n_mechanism
                free_dofs = _free_dofs_from_fixed_set(ndof, fixed_dofs)
            end
            break
        catch
            continue
        end
    end

    # After AUTOSPC mutations no clean factor of the FINAL partition exists.
    return free_dofs, n_mechanism_total, diagnostics, nothing
end

# Compute free DOFs without solving (for eigenvalue problems that need the same BC partition).
function compute_free_dofs(K, ndof, model, id_map, spc_id, rbe3_map; return_diagnostics::Bool=false,
                           trial_factor_out::Union{Nothing,Base.RefValue{Any}}=nothing,
                           allow_factorization_autospc::Bool=true)
    fixed_dofs = Set{Int}()
    diagnostics = Dict{String,Any}(
        "mpc_dependent_dofs" => length(rbe3_map),
        "permanent_grid_dofs" => 0,
        "permanent_grid_constraints" => 0,
        "explicit_spc_dofs" => 0,
        "autospc_enabled" => model_autospc_enabled(model),
        "autospc_diagonal_dofs" => 0,
        "autospc_diagonal_translational_dofs" => 0,
        "autospc_diagonal_rotational_dofs" => 0,
        "autospc_load_path_protected_translational_dofs" => 0,
        "autospc_load_path_skipped_dofs" => 0,
        "autospc_load_path_protection" => Dict{String,Any}("enabled" => false),
        "factorization_autospc" => Dict{String,Any}(),
        "fixed_dofs" => 0,
        "free_dofs" => 0,
    )

    # MPC dependent DOFs
    for dep_dof in keys(rbe3_map)
        push!(fixed_dofs, dep_dof)
    end

    permanent_grid_dofs, permanent_grid_constraints = _apply_permanent_grid_constraints!(fixed_dofs, model, id_map)
    diagnostics["permanent_grid_dofs"] = permanent_grid_dofs
    diagnostics["permanent_grid_constraints"] = permanent_grid_constraints

    # SPC DOFs
    sets = Set{Int}()
    if !isnothing(spc_id)
        sid = Int(spc_id)
        if haskey(model["SPCADDs"], sid)
            union!(sets, model["SPCADDs"][sid])
        else
            push!(sets, sid)
        end
    end
    fixed_before_spc = length(fixed_dofs)
    for spc in model["SPC1s"]
        if Int(spc["SID"]) in sets
            for n in spc["NODES"]
                idx = get(id_map, n, 0)
                if idx > 0
                    for c in spc["C"]
                        push!(fixed_dofs, (idx - 1) * 6 + parse(Int, c))
                    end
                end
            end
        end
    end
    diagnostics["explicit_spc_dofs"] = max(length(fixed_dofs) - fixed_before_spc, 0)

    if model_autospc_enabled(model)
        autospc_diag = _diagonal_autospc!(fixed_dofs, nothing, K, ndof, model, id_map)
        diagnostics["autospc_diagonal_dofs"] = autospc_diag["dofs"]
        diagnostics["autospc_diagonal_translational_dofs"] = autospc_diag["translational_dofs"]
        diagnostics["autospc_diagonal_rotational_dofs"] = autospc_diag["rotational_dofs"]
        diagnostics["autospc_load_path_protected_translational_dofs"] = autospc_diag["load_path_protected_translational_dofs"]
        diagnostics["autospc_load_path_skipped_dofs"] = autospc_diag["load_path_autospc_skipped_dofs"]
        # The eigen partition must reach the SAME constrained set as the static
        # path, or K and Kg disagree about which DOFs exist. Run the directional
        # test here too.
        if gpst_enabled()
            gpst = _grid_point_singularity_autospc!(fixed_dofs, nothing, K, ndof, model, id_map)
            diagnostics["autospc_gpst_dofs"] = gpst["dofs"]
            diagnostics["autospc_gpst_translational_dofs"] = gpst["translational_dofs"]
            diagnostics["autospc_gpst_rotational_dofs"] = gpst["rotational_dofs"]
            diagnostics["autospc_gpst_eps_zero"] = gpst["eps_zero"]
            diagnostics["autospc_gpst_entries"] =
                [Dict("grid_id" => e[1], "failed_direction" => e[2], "stiffness_ratio" => e[3])
                 for e in gpst["entries"]]
            if gpst["dofs"] > 0
                log_msg("[SOLVER] AUTOSPC grid-point singularity (eigen partition): $(gpst["dofs"]) DOFs ($(gpst["translational_dofs"]) trans + $(gpst["rotational_dofs"]) rot, eps_zero=$(gpst["eps_zero"]))")
            end
        end
    end

    free_dofs, n_fact_autospc, fact_diag, F_trial = if allow_factorization_autospc
        factorization_autospc_free_dofs(K, ndof, fixed_dofs)
    else
        (
            _free_dofs_from_fixed_set(ndof, fixed_dofs),
            0,
            Dict{String,Any}(
                "triggered" => false,
                "bypassed" => true,
                "reason" => "nullspace-preserving eigen solve",
            ),
            nothing,
        )
    end
    trial_factor_out !== nothing && (trial_factor_out[] = F_trial)
    if n_fact_autospc > 0
        log_msg("[BUCKLING] Added $n_fact_autospc factorization AUTOSPC DOFs to stabilize eigen partition")
    end
    diagnostics["factorization_autospc"] = fact_diag
    diagnostics["fixed_dofs"] = length(fixed_dofs)
    diagnostics["free_dofs"] = length(free_dofs)

    if return_diagnostics
        return free_dofs, fixed_dofs, diagnostics
    end
    return free_dofs, fixed_dofs
end

function apply_bc_and_solve(K, ndof, model, id_map, F_applied, node_R, rbe3_map, max_elem_stiff, orig_diag;
                            linear_cache=nothing)
    log_msg("[SOLVER] Processing Boundary Conditions...")

    spc_id = get(model, "_spc_id", nothing)
    load_path_protect_enabled = sol101_load_path_autospc_protect_enabled(model)
    cache_enabled = linear_cache !== nothing && ndof >= linear_solve_cache_min_ndof() && !load_path_protect_enabled
    cache_key = cache_enabled ? _linear_solve_cache_key(K, ndof, model, spc_id, rbe3_map) : nothing
    cached_entry = (cache_enabled && cache_key !== nothing) ? get(linear_cache, cache_key, nothing) : nothing

    diagnostics = Dict{String,Any}(
        "bc_partition" => Dict{String,Any}(
            "mpc_dependent_dofs" => length(rbe3_map),
            "permanent_grid_dofs" => 0,
            "permanent_grid_constraints" => 0,
            "explicit_spc_dofs" => 0,
            "enforced_displacement_dofs" => 0,
            "autospc_enabled" => model_autospc_enabled(model),
            "autospc_diagonal_dofs" => 0,
            "autospc_diagonal_translational_dofs" => 0,
            "autospc_diagonal_rotational_dofs" => 0,
            "autospc_load_path_protected_translational_dofs" => 0,
            "autospc_load_path_skipped_dofs" => 0,
            "autospc_load_path_protection" => Dict{String,Any}("enabled" => false),
            "post_factorization_singular_dofs" => 0,
            "post_factorization_singular_translational_dofs" => 0,
            "post_factorization_singular_rotational_dofs" => 0,
            "fixed_dofs" => 0,
            "free_dofs" => 0,
        ),
        "linear_solver" => Dict{String,Any}(
            "backend" => "unknown",
            "strategy" => "unknown",
            "cache_hit" => false,
            "used_enforced_displacement_correction" => false,
            "used_lu_fallback" => false,
            "used_singular_lu_regularization" => false,
            "singular_solver_mode" => _singular_solver_mode(),
            "used_lsmr_fallback" => false,
            "lsmr_scaled" => false,
            "lsmr_atol" => 0.0,
            "lsmr_btol" => 0.0,
            "lsmr_conlim" => 0.0,
            "lsmr_damping" => 0.0,
            "lsmr_maxiter" => 0,
            "lsmr_diag_scale_min" => 0.0,
            "lsmr_diag_scale_max" => 0.0,
            "lsmr_diag_floor" => 0.0,
            "auto_lsmr_threshold" => 0.0,
            "auto_lsmr_scaled" => false,
            "auto_lsmr_residual_norm" => 0.0,
            "auto_lsmr_relative_residual" => 0.0,
            "auto_lsmr_accepted" => false,
            "auto_lsmr_error" => "",
            "regularization_mode" => "global",
            "regularization_shift" => 0.0,
            "regularization_shift_min" => 0.0,
            "regularization_shift_max" => 0.0,
            "regularization_shift_source" => "",
            "regularization_shift_exponent" => nothing,
            "used_factorization_autospc" => false,
            "factorization_autospc" => Dict{String,Any}(
                "triggered" => false,
                "mechanism_dofs" => 0,
                "mechanism_translational_dofs" => 0,
                "mechanism_rotational_dofs" => 0,
                "skipped_translational_dofs" => 0,
                "shift_exponent" => nothing,
                "pivot_threshold" => 0.0,
                "pivot_shift_multiplier" => 0.0,
                "pivot_median_relative" => 0.0,
                "max_fraction" => 0.0,
                "skipped_as_too_aggressive" => false,
            ),
            "force_norm" => 0.0,
            "force_max" => 0.0,
            "force_nonzero_dofs" => 0,
            "residual_norm" => 0.0,
            "relative_residual" => 0.0,
        ),
    )

    F_norm = norm(F_applied)
    F_max = mapreduce(abs, max, F_applied; init=0.0)
    n_nonzero = count(x -> abs(x) > 1e-10, F_applied)

    if cached_entry !== nothing
        diagnostics = deepcopy(cached_entry.diagnostics)
        diagnostics["linear_solver"]["cache_hit"] = true
        diagnostics["linear_solver"]["force_norm"] = F_norm
        diagnostics["linear_solver"]["force_max"] = F_max
        diagnostics["linear_solver"]["force_nonzero_dofs"] = n_nonzero
        log_msg("[SOLVER] Force vector: |F|=$(F_norm), max=$(F_max), nonzero DOFs=$n_nonzero")
        log_msg("[SOLVER] Reusing BC partition/factorization cache: Fixed DOFs=$(length(cached_entry.fixed_dofs)), Free DOFs=$(length(cached_entry.free_dofs))")

        F_ff = F_applied[cached_entry.free_dofs]
        if cached_entry.K_fs !== nothing
            F_ff = F_ff - cached_entry.K_fs * cached_entry.enforced_values
            log_msg("[SOLVER] Enforced displacement RHS correction applied ($(length(cached_entry.enforced_dofs)) DOFs)")
        end

        u_ff = cached_entry.factor \ F_ff
        r_solve = cached_entry.K_ff * u_ff - F_ff
        r_norm = norm(r_solve)
        rel_residual = r_norm / max(norm(F_ff), 1e-30)
        diagnostics["linear_solver"]["residual_norm"] = r_norm
        diagnostics["linear_solver"]["relative_residual"] = rel_residual
        log_msg("[SOLVER] Residual: |r|=$(r_norm), |r|/|F|=$rel_residual")

        log_msg("[SOLVER] Post-Processing...")
        u_global = zeros(ndof)
        u_global[cached_entry.free_dofs] = u_ff
        for (gdof, dval) in zip(cached_entry.enforced_dofs, cached_entry.enforced_values)
            u_global[gdof] = dval
        end

        n_rbe3_recovered = 0
        for (dep_dof, pairs) in rbe3_map
            u_avg = 0.0
            for (ind_dof, coeff) in pairs
                u_avg += coeff * u_global[ind_dof]
            end
            u_global[dep_dof] = u_avg
            n_rbe3_recovered += 1
        end
        if n_rbe3_recovered > 0
            log_msg("[SOLVER] RBE3: Recovered $n_rbe3_recovered dependent DOFs")
        end

        return u_global, copy(cached_entry.fixed_dofs), copy(cached_entry.spc_dofs), diagnostics
    end

    fixed_dofs = Set{Int}()
    spc_dofs = Set{Int}()  # True SPC DOFs only (SPC1 + AUTOSPC), excludes MPC-dependent
    enforced_disp = Dict{Int,Float64}()  # global_dof => enforced value (non-zero)

    # Fix MPC dependent DOFs (RBE2/RBE3/RBE1/RSPLINE/MPC)
    for dep_dof in keys(rbe3_map)
        push!(fixed_dofs, dep_dof)
    end
    if !isempty(rbe3_map)
        log_msg("[SOLVER] MPC: Fixed $(length(rbe3_map)) dependent DOFs")
    end

    permanent_grid_dofs, permanent_grid_constraints = _apply_permanent_grid_constraints!(fixed_dofs, model, id_map)
    diagnostics["bc_partition"]["permanent_grid_dofs"] = permanent_grid_dofs
    diagnostics["bc_partition"]["permanent_grid_constraints"] = permanent_grid_constraints
    if permanent_grid_dofs > 0
        log_msg("[SOLVER] Permanent GRID/GRDSET constraints: $permanent_grid_dofs DOFs across $permanent_grid_constraints grid(s)")
    end

    sets = Set{Int}()
    spc_id = get(model, "_spc_id", nothing)
    if !isnothing(spc_id)
        sid = Int(spc_id)
        if haskey(model["SPCADDs"], sid)
            union!(sets, model["SPCADDs"][sid])
        else
            push!(sets, sid)
        end
    end
    fixed_before_spc = length(fixed_dofs)
    for spc in model["SPC1s"]
        if Int(spc["SID"]) in sets
            d_val = Float64(get(spc, "D", 0.0))
            for n in spc["NODES"]
                idx = get(id_map, n, 0)
                if idx > 0
                    for c in spc["C"]
                        gdof = (idx - 1) * 6 + parse(Int, c)
                        push!(fixed_dofs, gdof)
                        push!(spc_dofs, gdof)
                        if abs(d_val) > 0.0
                            enforced_disp[gdof] = d_val
                        end
                    end
                end
            end
        end
    end
    log_msg("[SOLVER] SPC: $(length(spc_dofs)) constrained DOFs from SPC1 cards")
    diagnostics["bc_partition"]["explicit_spc_dofs"] = max(length(fixed_dofs) - fixed_before_spc, 0)
    if !isempty(enforced_disp)
        log_msg("[SOLVER] Enforced displacements: $(length(enforced_disp)) DOFs")
    end
    diagnostics["bc_partition"]["enforced_displacement_dofs"] = length(enforced_disp)
    diagnostics["linear_solver"]["used_enforced_displacement_correction"] = !isempty(enforced_disp)

    protected_trans_dofs = nothing
    if model_autospc_enabled(model)
        load_path_diag = Dict{String,Any}("enabled" => false)
        if load_path_protect_enabled
            protected_trans_dofs, load_path_diag = _build_sol101_load_path_protected_trans_dofs(
                F_applied, ndof, model, id_map)
            log_msg("[SOLVER] SOL101 load-path AUTOSPC protection: protected=$(get(load_path_diag, "protected_translational_dofs", 0)) translational DOFs across $(get(load_path_diag, "protected_nodes", 0)) nodes")
        end

        autospc_diag = _diagonal_autospc!(fixed_dofs, spc_dofs, K, ndof, model, id_map, protected_trans_dofs)
        diagnostics["bc_partition"]["autospc_diagonal_dofs"] = autospc_diag["dofs"]
        diagnostics["bc_partition"]["autospc_diagonal_translational_dofs"] = autospc_diag["translational_dofs"]
        diagnostics["bc_partition"]["autospc_diagonal_rotational_dofs"] = autospc_diag["rotational_dofs"]
        diagnostics["bc_partition"]["autospc_load_path_protected_translational_dofs"] = autospc_diag["load_path_protected_translational_dofs"]
        diagnostics["bc_partition"]["autospc_load_path_skipped_dofs"] = autospc_diag["load_path_autospc_skipped_dofs"]
        diagnostics["bc_partition"]["autospc_load_path_protection"] = load_path_diag
        rel_trans = autospc_diag["rel_threshold_trans"]
        rel_rot = autospc_diag["rel_threshold_rot"]
        rel_msg = rel_trans == rel_rot ? string(rel_trans) : "trans=$(rel_trans), rot=$(rel_rot)"
        log_msg("[SOLVER] AUTOSPC: $(autospc_diag["dofs"]) DOFs ($(autospc_diag["translational_dofs"]) trans + $(autospc_diag["rotational_dofs"]) rot, rel_thresh=$rel_msg, max_K_trans=$(round(autospc_diag["max_K_trans"], sigdigits=3)), max_K_rot=$(round(autospc_diag["max_K_rot"], sigdigits=3)))")
        if autospc_diag["load_path_autospc_skipped_dofs"] > 0
            log_msg("[SOLVER] AUTOSPC load-path protection skipped $(autospc_diag["load_path_autospc_skipped_dofs"]) low-diagonal translational candidates")
        end
        if gpst_enabled()
            gpst = _grid_point_singularity_autospc!(fixed_dofs, spc_dofs, K, ndof, model, id_map,
                                                    protected_trans_dofs)
            diagnostics["bc_partition"]["autospc_gpst_dofs"] = gpst["dofs"]
            diagnostics["bc_partition"]["autospc_gpst_translational_dofs"] = gpst["translational_dofs"]
            diagnostics["bc_partition"]["autospc_gpst_rotational_dofs"] = gpst["rotational_dofs"]
            diagnostics["bc_partition"]["autospc_gpst_eps_zero"] = gpst["eps_zero"]
            diagnostics["bc_partition"]["autospc_gpst_entries"] =
                [Dict("grid_id" => e[1], "failed_direction" => e[2], "stiffness_ratio" => e[3])
                 for e in gpst["entries"]]
            log_msg("[SOLVER] AUTOSPC grid-point singularity: $(gpst["dofs"]) DOFs ($(gpst["translational_dofs"]) trans + $(gpst["rotational_dofs"]) rot, eps_zero=$(gpst["eps_zero"]))")
        end
    else
        log_msg("[SOLVER] AUTOSPC: disabled by PARAM,AUTOSPC")
    end

    F_norm = norm(F_applied)
    F_max = mapreduce(abs, max, F_applied; init=0.0)
    n_nonzero = count(x -> abs(x) > 1e-10, F_applied)
    diagnostics["linear_solver"]["force_norm"] = F_norm
    diagnostics["linear_solver"]["force_max"] = F_max
    diagnostics["linear_solver"]["force_nonzero_dofs"] = n_nonzero
    log_msg("[SOLVER] Force vector: |F|=$(F_norm), max=$(F_max), nonzero DOFs=$n_nonzero")
    log_msg("[SOLVER] Slicing Matrix (Reducing System)...")
    free_dofs = _free_dofs_from_fixed_set(ndof, fixed_dofs)
    diagnostics["bc_partition"]["fixed_dofs"] = length(fixed_dofs)
    diagnostics["bc_partition"]["free_dofs"] = length(free_dofs)
    log_msg("[SOLVER] Fixed DOFs: $(length(fixed_dofs)), Free DOFs: $(length(free_dofs))")

    K_ff = K[free_dofs, free_dofs]
    F_ff = F_applied[free_dofs]
    enforced_dofs = Int[]
    enforced_values = Float64[]
    K_fs = nothing

    # Enforced displacement correction: F_ff -= K_fs * u_s
    if !isempty(enforced_disp)
        enforced_dofs = sort(collect(keys(enforced_disp)))
        enforced_values = [enforced_disp[d] for d in enforced_dofs]
        K_fs = K[free_dofs, enforced_dofs]
        F_ff = F_ff - K_fs * enforced_values
        log_msg("[SOLVER] Enforced displacement RHS correction applied ($(length(enforced_dofs)) DOFs)")
    end

    n_free = length(free_dofs)
    solve_factor = nothing
    if n_free <= 2000000
        diagnostics["linear_solver"]["strategy"] = "direct"
        log_msg("[SOLVER] Using Direct Solver (Cholesky) for $n_free DOFs...")
        u_ff = try
            F_chol = cholesky(Symmetric(K_ff))

            # diag(F) avoids materializing the whole factor (bit-identical;
            # 19x measured); diag(K_ff) replaces n_free CSC binary searches.
            L_diag = abs.(diag(F_chol))
            K_diag = abs.(diag(K_ff))
            pivot_ratios = zeros(n_free)
            for i in 1:n_free
                if K_diag[i] > 1e-30
                    pivot_ratios[i] = L_diag[i]^2 / K_diag[i]
                else
                    pivot_ratios[i] = 1.0
                end
            end
            perm = F_chol.p
            sing_threshold = max(
                solver_env_float("JFEM_SOL101_POST_FACTOR_SINGULAR_PIVOT_THRESHOLD", 1e-7),
                0.0,
            )
            singular_local = findall(pivot_ratios .< sing_threshold)
            n_sing = length(singular_local)
            if n_sing > 0
                singular_original = perm[singular_local]
                singular_global = free_dofs[singular_original]
                n_sing_trans = count(d -> mod(d - 1, 6) + 1 <= 3, singular_global)
                n_sing_rot = n_sing - n_sing_trans
                diagnostics["bc_partition"]["post_factorization_singular_dofs"] = n_sing
                diagnostics["bc_partition"]["post_factorization_singular_translational_dofs"] = n_sing_trans
                diagnostics["bc_partition"]["post_factorization_singular_rotational_dofs"] = n_sing_rot
                log_msg("[SOLVER] Post-factorization singularity: $n_sing DOFs ($n_sing_trans trans + $n_sing_rot rot, threshold=$sing_threshold)")

                for d in singular_global
                    push!(fixed_dofs, d)
                end
                free_dofs = _free_dofs_from_fixed_set(ndof, fixed_dofs)
                K_ff = K[free_dofs, free_dofs]
                F_ff = F_applied[free_dofs]
                if !isempty(enforced_disp)
                    K_fs = K[free_dofs, enforced_dofs]
                    F_ff = F_ff - K_fs * enforced_values
                end
                n_free = length(free_dofs)
                diagnostics["bc_partition"]["fixed_dofs"] = length(fixed_dofs)
                diagnostics["bc_partition"]["free_dofs"] = n_free
                log_msg("[SOLVER] Re-solving with $(length(fixed_dofs)) fixed, $n_free free DOFs")
                F_chol = cholesky(Symmetric(K_ff))
            end

            diagnostics["linear_solver"]["backend"] = "direct_cholesky"
            solve_factor = F_chol
            F_chol \ F_ff
        catch e
            log_msg("[SOLVER] Cholesky failed: $(typeof(e)). Running factorization AUTOSPC...")

            local u_result
            mechanism_found = false

            # Try shifted Cholesky with progressively larger shifts (limited range to avoid false positives)
            for shift_exp in [-12, -10, -8, -6]
                shift_val = max(max_elem_stiff, 1.0) * 10.0^shift_exp
                try
                    diagnostics["linear_solver"]["used_factorization_autospc"] = true
                    diagnostics["linear_solver"]["factorization_autospc"]["triggered"] = true
                    diagnostics["linear_solver"]["factorization_autospc"]["shift_exponent"] = shift_exp

                    F_chol_probe = if sol101_factorization_probe_check_false_enabled(model)
                        cholesky(Symmetric(K_ff); shift=shift_val, check=false)
                    else
                        cholesky(Symmetric(K_ff); shift=shift_val)
                    end
                    L_diag = abs.(diag(F_chol_probe))
                    L_median = median(L_diag)
                    # Use ratio-based threshold: mechanisms have L[i] close to sqrt(shift),
                    # regular DOFs have L[i] much larger than sqrt(shift).
                    pivot_shift_mul = sol101_factorization_autospc_shift_multiplier()
                    pivot_median_rel = sol101_factorization_autospc_median_relative()
                    max_fraction = sol101_factorization_autospc_max_fraction()
                    pivot_threshold = min(sqrt(shift_val) * pivot_shift_mul,
                                          L_median * pivot_median_rel)
                    diagnostics["linear_solver"]["factorization_autospc"]["pivot_threshold"] = pivot_threshold
                    diagnostics["linear_solver"]["factorization_autospc"]["pivot_shift_multiplier"] = pivot_shift_mul
                    diagnostics["linear_solver"]["factorization_autospc"]["pivot_median_relative"] = pivot_median_rel
                    diagnostics["linear_solver"]["factorization_autospc"]["max_fraction"] = max_fraction
                    small_pivot_mask = L_diag .< pivot_threshold
                    n_mechanism = count(small_pivot_mask)

                    # Sanity check: if too many DOFs are flagged, the threshold is
                    # too aggressive for this shift.
                    if n_mechanism > n_free * max_fraction
                        diagnostics["linear_solver"]["factorization_autospc"]["mechanism_dofs"] = n_mechanism
                        diagnostics["linear_solver"]["factorization_autospc"]["skipped_as_too_aggressive"] = true
                        max_pct = round(100.0 * max_fraction; digits=3)
                        log_msg("[SOLVER] Factorization AUTOSPC (shift=1e$shift_exp): $n_mechanism DOFs (>$max_pct% of $n_free free) - threshold too aggressive, skipping")
                        mechanism_found = true
                        break
                    end

                    if n_mechanism > 0
                        perm = F_chol_probe.p
                        mechanism_local = findall(small_pivot_mask)
                        mechanism_original = perm[mechanism_local]
                        mechanism_global_raw = free_dofs[mechanism_original]
                        mechanism_global = Int[]
                        skipped_trans = 0
                        allow_trans =
                            sol101_factorization_autospc_allow_trans_enabled(model)
                        for d in mechanism_global_raw
                            dof_local = mod(d - 1, 6) + 1
                            if dof_local <= 3
                                if !allow_trans
                                    skipped_trans += 1
                                    continue
                                end
                            end
                            push!(mechanism_global, d)
                        end
                        n_mech_trans = count(d -> mod(d - 1, 6) + 1 <= 3, mechanism_global)
                        n_mech_rot = length(mechanism_global) - n_mech_trans
                        diagnostics["linear_solver"]["factorization_autospc"]["mechanism_dofs"] = length(mechanism_global)
                        diagnostics["linear_solver"]["factorization_autospc"]["mechanism_translational_dofs"] = n_mech_trans
                        diagnostics["linear_solver"]["factorization_autospc"]["mechanism_rotational_dofs"] = n_mech_rot
                        diagnostics["linear_solver"]["factorization_autospc"]["skipped_translational_dofs"] = skipped_trans
                        log_msg("[SOLVER] Factorization AUTOSPC (shift=1e$shift_exp): Found $(length(mechanism_global)) DOFs ($n_mech_trans trans + $n_mech_rot rot), skipped $(skipped_trans) translational candidates")

                        for d in mechanism_global
                            push!(fixed_dofs, d)
                            push!(spc_dofs, d)
                        end
                        free_dofs = _free_dofs_from_fixed_set(ndof, fixed_dofs)
                        K_ff = K[free_dofs, free_dofs]
                        F_ff = F_applied[free_dofs]
                        if !isempty(enforced_disp)
                            K_fs = K[free_dofs, enforced_dofs]
                            F_ff = F_ff - K_fs * enforced_values
                        end
                        n_free = length(free_dofs)
                        diagnostics["bc_partition"]["fixed_dofs"] = length(fixed_dofs)
                        diagnostics["bc_partition"]["free_dofs"] = n_free
                        log_msg("[SOLVER] Rebuilt system: Fixed=$(length(fixed_dofs)), Free=$n_free")
                    end

                    mechanism_found = true
                    break
                catch
                    continue
                end
            end

            if mechanism_found
                # Try clean Cholesky on reduced system
                try
                    F_chol_clean = cholesky(Symmetric(K_ff))
                    solve_factor = F_chol_clean
                    u_result = F_chol_clean \ F_ff
                    diagnostics["linear_solver"]["backend"] = "direct_cholesky_after_factorization_autospc"
                    log_msg("[SOLVER] Clean Cholesky succeeded after factorization AUTOSPC")
                catch e2
                    log_msg("[SOLVER] Clean Cholesky still failed: $(typeof(e2)). Using LU factorization...")
                    solve_factor, u_result = _lu_or_regularized_solve(
                        K_ff, F_ff, max_elem_stiff, diagnostics,
                        "direct_lu_after_factorization_autospc",
                    )
                end
            else
                log_msg("[SOLVER] All shifted Cholesky attempts failed. Using LU factorization directly...")
                solve_factor, u_result = _lu_or_regularized_solve(
                    K_ff, F_ff, max_elem_stiff, diagnostics,
                    "direct_lu",
                )
            end
            u_result
        end
    else
        # Ensure perfect symmetry for iterative solver
        K_sym = Symmetric(K_ff)
        diagnostics["linear_solver"]["strategy"] = "iterative"
        log_msg("[SOLVER] Computing Preconditioner (Smoothed Aggregation)...")
        ml = smoothed_aggregation(K_sym)
        P = aspreconditioner(ml)
        log_msg("[SOLVER] Solving Linear System (CG + AMG)...")
        u_ff = try
            diagnostics["linear_solver"]["backend"] = "iterative_cg_amg"
            cg(K_sym, F_ff; reltol=1e-8, maxiter=5000, Pl=P)
        catch e
            log_msg("[SOLVER] CG Failed ($e). Trying MINRES...")
            diagnostics["linear_solver"]["backend"] = "iterative_minres"
            minres(K_sym, F_ff; reltol=1e-8, maxiter=5000)
        end
    end

    # Report residual
    r_solve = K_ff * u_ff - F_ff
    r_norm = norm(r_solve)
    rel_residual = r_norm / max(norm(F_ff), 1e-30)
    diagnostics["linear_solver"]["residual_norm"] = r_norm
    diagnostics["linear_solver"]["relative_residual"] = rel_residual
    log_msg("[SOLVER] Residual: |r|=$(r_norm), |r|/|F|=$rel_residual")

    # JFEM_DUMP_SOLVE_STATE: env-var-gated dump of the actual solve-time state
    # (free_dofs, K_ff stats, F_ff stats, u_ff stats) for post-hoc comparison
    # against results["K"]/results["u_static"]/results["fixed_dofs"] when
    # localising parity gaps. Path comes from the env var; "1"/"true" → stdout-only.
    dump_target = get(ENV, "JFEM_DUMP_SOLVE_STATE", "")
    if dump_target != ""
        n_ff = length(free_dofs)
        Fz_F_ff = sum(F_ff[i] for (i,d) in enumerate(free_dofs) if (d-1) % 6 == 2; init=0.0)
        Fz_u_ff = sum(u_ff[i] for (i,d) in enumerate(free_dofs) if (d-1) % 6 == 2; init=0.0)
        K_ff_diag_norm = norm(diag(K_ff))
        K_ff_trace = sum(K_ff[i,i] for i in 1:n_ff; init=0.0)
        U_internal = 0.5 * dot(u_ff, K_ff * u_ff)
        do_file = !(lowercase(strip(dump_target)) in ("1", "true", "yes", "stdout"))
        io = do_file ? open(dump_target, "a") : stdout
        try
            println(io, "=" ^ 70)
            println(io, "JFEM_DUMP_SOLVE_STATE @ apply_bc_and_solve (post-solve)")
            println(io, "=" ^ 70)
            println(io, "n_dof_total          = ", ndof)
            println(io, "n_free_dofs          = ", n_ff)
            println(io, "n_fixed_dofs         = ", length(fixed_dofs))
            println(io, "n_enforced_dofs      = ", length(enforced_dofs))
            println(io, "enforced_values_norm = ", isempty(enforced_values) ? 0.0 : norm(enforced_values))
            println(io, "|F_applied|          = ", norm(F_applied))
            println(io, "|F_ff| (post-enforced corr) = ", norm(F_ff))
            println(io, "Fz_F_ff (sum z-components)  = ", Fz_F_ff)
            println(io, "|u_ff|               = ", norm(u_ff))
            println(io, "Fz_u_ff (sum z-components)  = ", Fz_u_ff)
            println(io, "|K_ff diag|          = ", K_ff_diag_norm)
            println(io, "trace(K_ff)          = ", K_ff_trace)
            println(io, "|K_ff*u_ff - F_ff|   = ", r_norm)
            println(io, "|r|/|F_ff|           = ", rel_residual)
            println(io, "U_internal = 1/2 u'·K·u = ", U_internal)
            println(io, "factor backend       = ", diagnostics["linear_solver"]["backend"])
            println(io, "free_dofs[1:min(20,end)] = ", free_dofs[1:min(20, n_ff)])
            println(io, "fixed_dofs (sorted, [1:min(20,end)]) = ", sort(collect(fixed_dofs))[1:min(20, length(fixed_dofs))])
            println(io, "F_ff[1:min(8,end)]   = ", F_ff[1:min(8, n_ff)])
            println(io, "u_ff[1:min(8,end)]   = ", u_ff[1:min(8, n_ff)])
            println(io)
        finally
            do_file && close(io)
        end
    end

    if cache_enabled && cache_key !== nothing && solve_factor !== nothing &&
       diagnostics["linear_solver"]["strategy"] == "direct"
        linear_cache[cache_key] = LinearSolveCacheEntry(
            copy(free_dofs),
            copy(fixed_dofs),
            copy(spc_dofs),
            copy(enforced_dofs),
            copy(enforced_values),
            K_ff,
            K_fs,
            solve_factor,
            deepcopy(diagnostics),
        )
    end

    log_msg("[SOLVER] Post-Processing...")
    u_global = zeros(ndof)
    u_global[free_dofs] = u_ff

    # Apply enforced displacement values
    for (gdof, dval) in zip(enforced_dofs, enforced_values)
        u_global[gdof] = dval
    end

    # RBE3 displacement recovery
    n_rbe3_recovered = 0
    for (dep_dof, pairs) in rbe3_map
        u_avg = 0.0
        for (ind_dof, coeff) in pairs
            u_avg += coeff * u_global[ind_dof]
        end
        u_global[dep_dof] = u_avg
        n_rbe3_recovered += 1
    end
    if n_rbe3_recovered > 0
        log_msg("[SOLVER] RBE3: Recovered $n_rbe3_recovered dependent DOFs")
    end

    # Second JFEM_DUMP_SOLVE_STATE dump: u_global at function return (after
    # enforced-disp + RBE3 recovery). u_global[free_dofs] should byte-match
    # the u_ff dumped earlier; if it doesn't, the post-processing is the bug.
    if dump_target != ""
        u_global_ff = u_global[free_dofs]
        do_file2 = !(lowercase(strip(dump_target)) in ("1", "true", "yes", "stdout"))
        io2 = do_file2 ? open(dump_target, "a") : stdout
        try
            println(io2, "-" ^ 70)
            println(io2, "JFEM_DUMP_SOLVE_STATE @ apply_bc_and_solve (RETURN)")
            println(io2, "-" ^ 70)
            println(io2, "|u_global|              = ", norm(u_global))
            println(io2, "|u_global[free_dofs]|   = ", norm(u_global_ff))
            println(io2, "u_global[free[1:8]]     = ", u_global_ff[1:min(8, length(u_global_ff))])
            println(io2, "u_global[free] - u_ff norm = ", norm(u_global_ff - u_ff))
            println(io2)
        finally
            do_file2 && close(io2)
        end
    end

    return u_global, fixed_dofs, spc_dofs, diagnostics
end
