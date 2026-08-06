# SOL101/103/105 precompile workload (ON by default since 2026-08-05).
#
# Bakes the parse -> build -> solve path into the package image at precompile
# time, eliminating the measured ~147 s of per-process first-solve JIT
# (79% of a fresh single-deck run; PERF_AUDIT_SOL105_2026_08_05 item 1).
# The one-time cost is paid at package precompilation after a source change.
#
# Opt out (e.g. for tight source-edit loops) with:
#   JFEM_SOL105_PRECOMPILE_WORKLOAD=false
#
# Optionally override the BDF list with semicolon-separated absolute/relative
# paths in JFEM_SOL105_PRECOMPILE_BDF and the flag set with
# JFEM_SOL105_PRECOMPILE_FLAGS="FLAG=val,FLAG2=val2".

const _JFEM_PRECOMPILE_TRUE = Set(("1", "true", "yes", "on"))

@inline function _jfem_precompile_bool(key::String, default::Bool=false)
    raw = lowercase(strip(get(ENV, key, default ? "true" : "false")))
    return raw in _JFEM_PRECOMPILE_TRUE
end

function _jfem_precompile_split_paths(raw::AbstractString)
    paths = String[]
    for item in split(raw, ';')
        path = strip(item)
        isempty(path) && continue
        push!(paths, normpath(isabspath(path) ? path : abspath(path)))
    end
    return paths
end

function _jfem_default_precompile_bdfs()
    repo_root = normpath(joinpath(@__DIR__, ".."))
    precompile_dir = joinpath(repo_root, "JFEM_installation", "examples", "precompile")
    candidates = String[
        joinpath(precompile_dir, "sol101_quad_static.bdf"),
        joinpath(precompile_dir, "sol103_quad_modes.bdf"),
        joinpath(precompile_dir, "sol105_quad_buckling.bdf"),
        # ~1000-DOF mixed CQUAD4/CTRIA3 plate with ranged EIGRL + STATSUB:
        # exercises the SPARSE eigsolve/Sturm/augmentation branches (the tiny
        # decks above stay under the dense-path thresholds and left ~26 s of
        # first-solve JIT uncovered on production-size decks).
        joinpath(precompile_dir, "sol105_plate_ranged.bdf"),
    ]
    return filter(isfile, candidates)
end

function _jfem_precompile_bdfs()
    raw = strip(get(ENV, "JFEM_SOL105_PRECOMPILE_BDF", ""))
    if !isempty(raw)
        return filter(isfile, _jfem_precompile_split_paths(raw))
    end
    return _jfem_default_precompile_bdfs()
end

function _jfem_precompile_flags()
    raw = strip(get(ENV, "JFEM_SOL105_PRECOMPILE_FLAGS", ""))
    pairs = Pair{String,String}[]
    isempty(raw) && return pairs
    sep = occursin(";", raw) ? ";" : ","
    for kv in split(raw, sep)
        isempty(strip(kv)) && continue
        parts = split(kv, "="; limit=2)
        length(parts) == 2 || continue
        push!(pairs, strip(parts[1]) => strip(parts[2]))
    end
    return pairs
end

function _jfem_with_env(f::Function, pairs)
    old = Dict{String,Union{Nothing,String}}()
    for (key, value) in pairs
        old[key] = haskey(ENV, key) ? ENV[key] : nothing
        ENV[key] = value
    end
    try
        return f()
    finally
        for (key, value) in old
            if value === nothing
                delete!(ENV, key)
            else
                ENV[key] = value
            end
        end
    end
end

function _jfem_precompile_solve_bdf(path::AbstractString)
    # Route through main() so the export stack (JSON/binary/markdown) is
    # baked into the pkgimage too — export was a measured chunk of the
    # residual first-solve JIT when the workload called solve_model only.
    # A failing workload deck must degrade coverage, never break package
    # precompilation.
    try
        outdir = mktempdir()
        main(String(path); output_dir=outdir, export_json=true)
        return nothing
    catch err
        @warn "precompile workload deck failed (coverage reduced)" path err
        return nothing
    end
end

if _jfem_precompile_bool("JFEM_SOL105_PRECOMPILE_WORKLOAD", true) ||
   haskey(ENV, "JFEM_SOL105_PRECOMPILE_BDF")
    @setup_workload begin
        bdfs = _jfem_precompile_bdfs()
        flags = _jfem_precompile_flags()
        @compile_workload begin
            _jfem_with_env(flags) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        for bdf in bdfs
                            _jfem_precompile_solve_bdf(bdf)
                        end
                    end
                end
            end
        end
    end
end
