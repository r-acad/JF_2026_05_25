# Guard for TACS-formulation SOL101 CBAR/CBEAM stress recovery.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_stress_recovery_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_deck(path::AbstractString, card_type::AbstractString)
    A = 1.2e-2
    I1 = 1.1e-6
    I2 = 1.9e-6
    J = 2.7e-6
    L = 2.4
    F = 1500.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card axial stress recovery check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, length=L, force=F)
end

function _write_bending_beam_deck(path::AbstractString, card_type::AbstractString)
    width_z = 8.0e-2
    height_y = 1.2e-1
    L = 2.0
    Fz = 120.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card bending stress recovery check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBARL,1,1,,BAR,$width_z,$height_y")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, width_z=width_z, height_y=height_y,
            length=L, force_z=Fz)
end

function _write_offset_release_recovery_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.1e-6
    I2 = 2.3e-6
    J = 3.4e-6
    L = 2.0
    Fz = 100.0
    wa = (0.0, 0.12, 0.08)
    wb = (0.0, -0.04, 0.03)
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card offset/release recovery check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.,,0,5,$(wa[1]),$(wa[2]),$(wa[3]),$(wb[1]),$(wb[2]),$(wb[3])")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J,
            length=L, force_z=Fz, wa=wa, wb=wb)
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _relerr(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _first_row(subcase::AbstractDict, table::AbstractString)
    rows = subcase[table]["cbar"]
    @test length(rows) == 1
    return first(rows)
end

function _beam_group(card::AbstractString)
    card == "CBAR" && return "CBARs"
    card == "CBEAM" && return "CBEAMs"
    error("unsupported card $card")
end

function _expected_offset_release_forces(case)
    p1 = [0.0, 0.0, 0.0]
    p2 = [case.length, 0.0, 0.0]
    p1_eff = p1 .+ collect(case.wa)
    p2_eff = p2 .+ collect(case.wb)
    axis = p2_eff .- p1_eff
    L_eff = norm(axis)
    vx = axis ./ L_eff
    vref = [0.0, 1.0, 0.0]
    vz = normalize(cross(vx, vref))
    vy = cross(vz, vx)
    force_global = [0.0, 0.0, case.force_z]
    f_local = [dot(force_global, vx), dot(force_global, vy), dot(force_global, vz)]
    return (
        axial=f_local[1],
        shear_1=f_local[2],
        shear_2=f_local[3],
        moment_a2=f_local[3] * L_eff,
    )
end

function _check_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    subcase = results["subcases"][1]
    force_row = _first_row(subcase, "forces")
    stress_row = _first_row(subcase, "stresses")
    strain_row = _first_row(subcase, "strains")

    ux2 = _grid_dof(results["id_map"], 2, 1)
    u = Float64.(subcase["u_analysis"])
    expected_disp = case.force * case.length / (E_BEAM * case.area)
    expected_force = case.force
    expected_stress = case.force / case.area
    expected_strain = expected_stress / E_BEAM

    disp_relerr = _relerr(u[ux2], expected_disp)
    force_relerr = _relerr(force_row["axial"], expected_force)
    stress_relerr = _relerr(stress_row["axial"], expected_stress)
    strain_relerr = _relerr(strain_row["axial"], expected_strain)

    @test disp_relerr < 1e-10
    @test force_relerr < 1e-10
    @test stress_relerr < 1e-10
    @test strain_relerr < 1e-10
    @test abs(Float64(force_row["shear_1"])) < 1e-9
    @test abs(Float64(force_row["shear_2"])) < 1e-9
    @test abs(Float64(force_row["torque"])) < 1e-9
    return disp_relerr, force_relerr, stress_relerr, strain_relerr
end

function _check_bending_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    subcase = results["subcases"][1]
    force_row = _first_row(subcase, "forces")
    stress_row = _first_row(subcase, "stresses")
    strain_row = _first_row(subcase, "strains")

    Iy = case.height_y * case.width_z^3 / 12.0
    zc = case.width_z / 2.0
    expected_shear_2 = case.force_z
    expected_moment_a2 = case.force_z * case.length
    expected_surface = expected_moment_a2 * zc / Iy

    shear_relerr = _relerr(force_row["shear_2"], expected_shear_2)
    moment_relerr = _relerr(force_row["moment_a2"], expected_moment_a2)
    p1_relerr = _relerr(stress_row["end_a"]["p1"], -expected_surface)
    p2_relerr = _relerr(stress_row["end_a"]["p2"], -expected_surface)
    p3_relerr = _relerr(stress_row["end_a"]["p3"], expected_surface)
    p4_relerr = _relerr(stress_row["end_a"]["p4"], expected_surface)

    @test shear_relerr < 1e-10
    @test moment_relerr < 1e-10
    @test p1_relerr < 1e-10
    @test p2_relerr < 1e-10
    @test p3_relerr < 1e-10
    @test p4_relerr < 1e-10
    @test abs(Float64(force_row["axial"])) < 1e-9
    @test abs(Float64(force_row["moment_b2"])) < 1e-9
    @test abs(Float64(stress_row["axial"])) < 1e-9
    @test abs(Float64(strain_row["axial"])) < 1e-12
    return shear_relerr, moment_relerr, maximum((p1_relerr, p2_relerr, p3_relerr, p4_relerr))
end

function _check_offset_release_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    beam = model[_beam_group(case.card)]["1"]
    @test Int(get(beam, "PB", 0)) == 5
    @test Float64.(get(beam, "WA", [])) == Float64.(collect(case.wa))
    @test Float64.(get(beam, "WB", [])) == Float64.(collect(case.wb))
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"

    force_row = _first_row(results["subcases"][1], "forces")
    expected = _expected_offset_release_forces(case)
    axial_relerr = _relerr(force_row["axial"], expected.axial)
    shear1_relerr = _relerr(force_row["shear_1"], expected.shear_1)
    shear2_relerr = _relerr(force_row["shear_2"], expected.shear_2)
    moment_relerr = _relerr(force_row["moment_a2"], expected.moment_a2)

    @test axial_relerr < 1e-8
    @test shear1_relerr < 1e-8
    @test shear2_relerr < 1e-8
    @test moment_relerr < 1e-8
    @test abs(Float64(force_row["moment_b2"])) < 1e-8
    return axial_relerr, shear1_relerr, shear2_relerr, moment_relerr,
           abs(Float64(force_row["moment_b2"]))
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_stress_")
    cbar = _write_beam_deck(joinpath(tmp, "tacs_cbar_stress.bdf"), "CBAR")
    cbeam = _write_beam_deck(joinpath(tmp, "tacs_cbeam_stress.bdf"), "CBEAM")
    cbar_bend = _write_bending_beam_deck(joinpath(tmp, "tacs_cbar_bending_stress.bdf"), "CBAR")
    cbeam_bend = _write_bending_beam_deck(joinpath(tmp, "tacs_cbeam_bending_stress.bdf"), "CBEAM")
    cbar_offset_release = _write_offset_release_recovery_deck(
        joinpath(tmp, "tacs_cbar_offset_release_stress.bdf"), "CBAR")
    cbeam_offset_release = _write_offset_release_recovery_deck(
        joinpath(tmp, "tacs_cbeam_offset_release_stress.bdf"), "CBEAM")

    cbar_checks = _check_case(cbar)
    cbeam_checks = _check_case(cbeam)
    cbar_bending_checks = _check_bending_case(cbar_bend)
    cbeam_bending_checks = _check_bending_case(cbeam_bend)
    cbar_offset_release_checks = _check_offset_release_case(cbar_offset_release)
    cbeam_offset_release_checks = _check_offset_release_case(cbeam_offset_release)

    println("TACS SOL101 beam stress recovery guard passed")
    for (name, checks) in (("CBAR", cbar_checks), ("CBEAM", cbeam_checks))
        println("  $name axial displacement relerr = $(checks[1])")
        println("  $name axial force relerr        = $(checks[2])")
        println("  $name axial stress relerr       = $(checks[3])")
        println("  $name axial strain relerr       = $(checks[4])")
    end
    for (name, checks) in (("CBAR", cbar_bending_checks), ("CBEAM", cbeam_bending_checks))
        println("  $name bending shear relerr      = $(checks[1])")
        println("  $name bending moment relerr     = $(checks[2])")
        println("  $name surface stress relerr     = $(checks[3])")
    end
    for (name, checks) in (("CBAR", cbar_offset_release_checks), ("CBEAM", cbeam_offset_release_checks))
        println("  $name offset/release axial relerr    = $(checks[1])")
        println("  $name offset/release shear1 relerr   = $(checks[2])")
        println("  $name offset/release shear2 relerr   = $(checks[3])")
        println("  $name offset/release moment relerr   = $(checks[4])")
        println("  $name offset/release released moment = $(checks[5])")
    end
    return true
end

exit(main() ? 0 : 1)
