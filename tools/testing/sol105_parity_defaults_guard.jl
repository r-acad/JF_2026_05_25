# Guard parity-critical SOL105 defaults and generic geometry/material gates.
#
# Usage:
#   julia --project=. tools/testing/sol105_parity_defaults_guard.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _with_env(f::Function, key::AbstractString, value)
    old = get(ENV, key, nothing)
    try
        if value === nothing
            delete!(ENV, key)
        else
            ENV[key] = string(value)
        end
        return f()
    finally
        if old === nothing
            delete!(ENV, key)
        else
            ENV[key] = old
        end
    end
end

function _without_env(f::Function, keys)
    old = Dict(key => get(ENV, key, nothing) for key in keys)
    try
        for key in keys
            delete!(ENV, key)
        end
        return f()
    finally
        for key in keys
            delete!(ENV, key)
            old[key] === nothing || (ENV[key] = old[key])
        end
    end
end

function _long_temp_artifact_path()
    tmp = joinpath(tempdir(), "openjfem_export_longpath_guard")
    parts = fill("segment0123456789", 20)
    return joinpath(tmp, parts..., "artifact.json")
end

@testset "SOL105 parity defaults" begin
    _with_env("JFEM_BUCKLING_CLUSTER_FILTER", nothing) do
        @test OpenJFEM.Solver.from_env().cluster_filter_enabled == false
    end
    _with_env("JFEM_BUCKLING_CLUSTER_FILTER", "true") do
        @test OpenJFEM.Solver.from_env().cluster_filter_enabled == true
    end
    _with_env("JFEM_BUCKLING_CLUSTER_FILTER", "false") do
        @test OpenJFEM.Solver.from_env().cluster_filter_enabled == false
    end
end

@testset "SOL105 stress-state calibration defaults" begin
    _with_env("JFEM_SOL105_LOAD_AWARE_KERNEL", nothing) do
        @test OpenJFEM.Solver.sol105_load_aware_kernel_enabled() == false
    end
    _with_env("JFEM_SOL105_LOAD_AWARE_KERNEL", "true") do
        @test OpenJFEM.Solver.sol105_load_aware_kernel_enabled() == true
    end
    _with_env("JFEM_SOL105_LOAD_AWARE_KERNEL", "false") do
        @test OpenJFEM.Solver.sol105_load_aware_kernel_enabled() == false
    end

    _without_env((
        "JFEM_KG_QUAD4_AUTO_GP_SPREAD",
        "JFEM_KG_QUAD4_GP_FIELD_PMIN_SPREAD_AVG_MIN",
        "JFEM_KG_QUAD4_GP_FIELD_PMIN_SPREAD_AVG_ALPHA",
        "JFEM_KG_SHELL_PCOMP_NXY_SCALE",
        "JFEM_KG_SHELL_PCOMP_NXY_ASPECT_SCALE",
        "JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_RELAX",
    )) do
        @test OpenJFEM.Solver.kg_quad4_auto_gp_spread_enabled() == false
        @test isinf(OpenJFEM.Solver.kg_quad4_gp_field_pmin_spread_avg_min())
        @test isapprox(OpenJFEM.Solver.kg_quad4_gp_field_pmin_spread_avg_alpha(), 0.0; atol=0.0)
        @test isapprox(OpenJFEM.Solver.kg_shell_pcomp_nxy_scale(), 1.0; atol=0.0)
        @test OpenJFEM.Solver.kg_shell_pcomp_nxy_aspect_scale_enabled() == false
        @test isapprox(OpenJFEM.Solver.kg_shell_pcomp_nxy_shear_dom_relax(), 0.0; atol=0.0)
    end
end

@testset "SOL105 PCOMP Kg geometry/material scaling" begin
    scale = OpenJFEM.Solver.sol105_geom_pcomp_kg_scale

    @test isapprox(scale(true, false, 8.0, 1.0, 0.010, 1), 1.032; rtol=1e-12)
    @test isapprox(scale(true, false, 7.5, 1.0, 0.010, 1), 1.0; rtol=1e-12)
    @test isapprox(scale(true, false, 9.0, 1.0, 0.010, 1), 1.0; rtol=1e-12)

    @test isapprox(scale(true, false, 8.0, 1.0, 0.040, 100), 0.98; rtol=1e-12)
    @test isapprox(scale(true, false, 8.0, 1.0, 0.010, 100), 1.0; rtol=1e-12)

    @test isapprox(scale(false, false, 8.0, 1.0, 0.040, 100), 1.0; rtol=1e-12)
    @test isapprox(scale(true, true, 8.0, 1.0, 0.040, 100), 1.0; rtol=1e-12)
end

@testset "SOL105 PSHELL flat-square Kg geometry/material scaling" begin
    scale = OpenJFEM.Solver.sol105_geom_pshell_iso_flat_square_kg_scale
    args = (1.03, 0.9, 1.1, 1.0e-8, 0.03, 0.08)

    @test isapprox(scale(true, true, 1.0, 0.0, 0.05, args...), 1.03; rtol=1e-12)
    @test isapprox(scale(false, true, 1.0, 0.0, 0.05, args...), 1.0; rtol=1e-12)
    @test isapprox(scale(true, false, 1.0, 0.0, 0.05, args...), 1.0; rtol=1e-12)
    @test isapprox(scale(true, true, 1.2, 0.0, 0.05, args...), 1.0; rtol=1e-12)
    @test isapprox(scale(true, true, 1.0, 2.0e-8, 0.05, args...), 1.0; rtol=1e-12)
    @test isapprox(scale(true, true, 1.0, 0.0, 0.02, args...), 1.0; rtol=1e-12)
end

@testset "Export long-path helper" begin
    long_path = _long_temp_artifact_path()
    fs_path = OpenJFEM._export_fs_path(long_path)

    if Sys.iswindows()
        @test startswith(fs_path, "\\\\?\\")
        @test length(normpath(abspath(long_path))) >= 240
    else
        @test fs_path == normpath(abspath(long_path))
    end

    short_path = joinpath(mktempdir(; prefix="openjfem_export_shortpath_"), "nested", "artifact.json")
    OpenJFEM._export_ensure_parent_dir!(short_path)
    open(OpenJFEM._export_fs_path(short_path), "w") do io
        print(io, "{}")
    end
    @test isfile(OpenJFEM._export_fs_path(short_path))
end

println("SOL105 parity defaults guard passed")
