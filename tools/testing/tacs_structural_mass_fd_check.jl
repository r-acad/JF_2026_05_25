# Finite-difference guard for TACS structural mass design gradients.
#
# Usage:
#   julia --project=. tools/testing/tacs_structural_mass_fd_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relative_error(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function _solve_tacs(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _mass_value(model::AbstractDict)
    results = _solve_tacs(model)
    response = OpenJFEM.structural_mass_design_gradient(results, Dict{String,Any}[])
    return Float64(response["value"])
end

function _with_pshell_thickness_delta(model::AbstractDict, pid::Integer, delta::Real)
    m = deepcopy(model)
    prop = m["PSHELLs"][string(Int(pid))]
    t = Float64(prop["T"]) + Float64(delta)
    t > 0.0 || error("Mass FD check produced nonpositive PSHELL thickness.")
    prop["T"] = t
    prop["Z1"] = -0.5 * t
    prop["Z2"] = 0.5 * t
    return m
end

function _with_material_field_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = m["MATs"][string(Int(mid))]
    key = uppercase(strip(field))
    mat[key] = Float64(mat[key]) + Float64(delta)
    return m
end

function _with_grid_coord_delta(model::AbstractDict, grid::Integer, comp::Integer, delta::Real)
    m = deepcopy(model)
    grid_data = m["GRIDs"][string(Int(grid))]
    x = Float64.(collect(grid_data["X"]))
    x[Int(comp)] += Float64(delta)
    grid_data["X"] = x
    return m
end

function _with_prod_area_delta(model::AbstractDict, pid::Integer, delta::Real)
    m = deepcopy(model)
    prop = m["PRODs"][string(Int(pid))]
    area = Float64(prop["A"]) + Float64(delta)
    area > 0.0 || error("Mass FD check produced nonpositive PROD area.")
    prop["A"] = area
    return m
end

function _with_conrod_area_delta(model::AbstractDict, eid::Integer, delta::Real)
    m = deepcopy(model)
    rod = m["CONRODs"][string(Int(eid))]
    area = Float64(rod["A"]) + Float64(delta)
    area > 0.0 || error("Mass FD check produced nonpositive CONROD area.")
    rod["A"] = area
    return m
end

function _write_crod_mass_deck(path::AbstractString)
    A = 0.012
    J = 2.5e-5
    L = 2.5
    nsm = 0.4
    rho = 2700.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CROD structural mass check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CROD,1,1,1,2")
        println(io, "PROD,1,1,$A,$J,0.,$nsm")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,$rho")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,10.,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, length=L, rho=rho, nsm=nsm, kind=:crod)
end

function _write_conrod_mass_deck(path::AbstractString)
    A = 0.009
    J = 1.6e-5
    L = 1.75
    nsm = 0.25
    rho = 2800.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CONROD structural mass check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CONROD,1,1,2,1,$A,$J,0.,$nsm")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,$rho")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,10.,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, length=L, rho=rho, nsm=nsm, kind=:conrod)
end

function _write_pcomp_sol101_deck(path::AbstractString; ply1_t::Float64=0.0025)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS structural mass PCOMP check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,$ply1_t,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,-100.,1.,0.,0.")
        println(io, "FORCE,1,3,0,-100.,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_point_mass_structural_deck(path::AbstractString, mass_kind::Symbol)
    mass =
        mass_kind == :conm2 ? 12.0 :
        mass_kind == :cmass2 ? 7.0 :
        mass_kind == :cmass1 ? 16.0 :
        error("Unsupported point-mass structural mass case '$mass_kind'.")
    k = 2400.0
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS $(uppercase(string(mass_kind))) structural mass check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "CELAS2,1,$k,1,1")
        if mass_kind == :conm2
            println(io, "CONM2,1,1,,$mass")
        elseif mass_kind == :cmass2
            println(io, "CMASS2,1,$mass,1,1")
        else
            println(io, "CMASS1,1,1,1,1")
            println(io, "PMASS,1,$mass")
        end
        println(io, "SPC1,1,23456,1")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, mass=mass, kind=mass_kind)
end

function _check_pshell_mass_gradients()
    deck = joinpath(repo_root, "examples", "precompile", "sol101_quad_static.bdf")
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    t0 = Float64(model["PSHELLs"]["1"]["T"])
    rho0 = Float64(model["MATs"]["1"]["RHO"])
    h_t = max(1e-5 * t0, 1e-7)
    h_rho = max(1e-6 * rho0, 1e-6)
    h_x = 1e-6

    dvs = Dict{String,Any}[
        Dict("id" => "t_pid1", "type" => "shell_thickness", "pids" => [1]),
        Dict("id" => "rho_mid1", "type" => "material_RHO", "mids" => [1]),
        Dict("id" => "E_mid1", "type" => "material_E", "mids" => [1]),
        Dict("id" => "grid2_x", "type" => "node_coord", "grid" => 2, "comp" => 1, "step" => h_x),
    ]
    response = OpenJFEM.structural_mass_design_gradient(results, dvs)
    @test response["response"] == "mass"
    @test response["gradient_backend"] == "tacs_formulation_mixed_mass_design_coordinate_fd"
    @test isapprox(Float64(response["value"]), 54.0; rtol=1e-12, atol=1e-10)
    @test Float64(response["gradient"]["E_mid1"]) == 0.0

    fd_t = (_mass_value(_with_pshell_thickness_delta(model, 1, h_t)) -
            _mass_value(_with_pshell_thickness_delta(model, 1, -h_t))) / (2.0 * h_t)
    fd_rho = (_mass_value(_with_material_field_delta(model, 1, "RHO", h_rho)) -
              _mass_value(_with_material_field_delta(model, 1, "RHO", -h_rho))) / (2.0 * h_rho)
    fd_x = (_mass_value(_with_grid_coord_delta(model, 2, 1, h_x)) -
            _mass_value(_with_grid_coord_delta(model, 2, 1, -h_x))) / (2.0 * h_x)

    hook_t = Float64(response["gradient"]["t_pid1"])
    hook_rho = Float64(response["gradient"]["rho_mid1"])
    hook_x = Float64(response["gradient"]["grid2_x"])
    @test _relative_error(hook_t, fd_t) < 1e-8
    @test _relative_error(hook_rho, fd_rho) < 1e-8
    @test _relative_error(hook_x, fd_x) < 1e-6

    return Dict(
        "mass" => Float64(response["value"]),
        "thickness" => (fd_t, hook_t, _relative_error(hook_t, fd_t)),
        "rho" => (fd_rho, hook_rho, _relative_error(hook_rho, fd_rho)),
        "node_coord" => (fd_x, hook_x, _relative_error(hook_x, fd_x)),
    )
end

function _check_pcomp_mass_gradient()
    tmp = mktempdir(; prefix="openjfem_tacs_mass_pcomp_")
    t0 = 0.0025
    h = max(1e-6 * t0, 1e-10)
    deck = _write_pcomp_sol101_deck(joinpath(tmp, "mass_pcomp.bdf"); ply1_t=t0)
    deck_p = _write_pcomp_sol101_deck(joinpath(tmp, "mass_pcomp_p.bdf"); ply1_t=t0 + h)
    deck_m = _write_pcomp_sol101_deck(joinpath(tmp, "mass_pcomp_m.bdf"); ply1_t=t0 - h)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    dv = Dict{String,Any}("id" => "ply1_t", "type" => "pcomp_ply_thickness", "pids" => [1], "ply_index" => 1)
    response = OpenJFEM.structural_mass_design_gradient(results, [dv])

    model_p = OpenJFEM.bdf_to_model(deck_p)
    model_m = OpenJFEM.bdf_to_model(deck_m)
    fd = (_mass_value(model_p) - _mass_value(model_m)) / (2.0 * h)
    hook = Float64(response["gradient"]["ply1_t"])
    rel = _relative_error(hook, fd)
    @test response["gradient_backend"] == "tacs_formulation_mass_coefficient"
    @test rel < 1e-8
    return Dict(
        "mass" => Float64(response["value"]),
        "pcomp_ply_thickness" => (fd, hook, rel),
    )
end

function _check_rod_mass_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    h_A = max(1e-6 * case.area, 1e-8)
    h_rho = max(1e-6 * case.rho, 1e-6)
    h_x = 1e-6
    area_dv =
        case.kind == :crod ?
        Dict{String,Any}("id" => "rod_area", "type" => "rod_area", "pids" => [1]) :
        Dict{String,Any}("id" => "rod_area", "type" => "rod_area", "eids" => [1])
    rho_dv = Dict{String,Any}("id" => "rod_rho", "type" => "material_RHO", "mids" => [1])
    x_dv = Dict{String,Any}("id" => "rod_x", "type" => "node_coord", "grid" => 2, "comp" => 1, "step" => h_x)
    response = OpenJFEM.structural_mass_design_gradient(results, [area_dv, rho_dv, x_dv])

    expected_mass = (case.rho * case.area + case.nsm) * case.length
    @test _relative_error(Float64(response["value"]), expected_mass) < 1e-12
    expected_area = case.rho * case.length
    expected_rho = case.area * case.length
    expected_x = case.rho * case.area + case.nsm

    area_model_p =
        case.kind == :crod ? _with_prod_area_delta(model, 1, h_A) :
        _with_conrod_area_delta(model, 1, h_A)
    area_model_m =
        case.kind == :crod ? _with_prod_area_delta(model, 1, -h_A) :
        _with_conrod_area_delta(model, 1, -h_A)
    fd_A = (_mass_value(area_model_p) - _mass_value(area_model_m)) / (2.0 * h_A)
    fd_rho = (_mass_value(_with_material_field_delta(model, 1, "RHO", h_rho)) -
              _mass_value(_with_material_field_delta(model, 1, "RHO", -h_rho))) / (2.0 * h_rho)
    fd_x = (_mass_value(_with_grid_coord_delta(model, 2, 1, h_x)) -
            _mass_value(_with_grid_coord_delta(model, 2, 1, -h_x))) / (2.0 * h_x)

    hook_A = Float64(response["gradient"]["rod_area"])
    hook_rho = Float64(response["gradient"]["rod_rho"])
    hook_x = Float64(response["gradient"]["rod_x"])
    @test _relative_error(hook_A, expected_area) < 1e-12
    @test _relative_error(hook_rho, expected_rho) < 1e-12
    @test _relative_error(hook_x, expected_x) < 1e-6
    @test _relative_error(hook_A, fd_A) < 1e-8
    @test _relative_error(hook_rho, fd_rho) < 1e-8
    @test _relative_error(hook_x, fd_x) < 1e-6
    return Dict(
        "mass" => Float64(response["value"]),
        "rod_area" => (fd_A, hook_A, _relative_error(hook_A, fd_A)),
        "rod_rho" => (fd_rho, hook_rho, _relative_error(hook_rho, fd_rho)),
        "rod_x" => (fd_x, hook_x, _relative_error(hook_x, fd_x)),
    )
end

function _check_point_mass_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    h = max(1e-6 * case.mass, 1e-8)
    mass_dv =
        case.kind == :cmass1 ?
        Dict{String,Any}("id" => "point_mass", "type" => "point_mass", "pids" => [1], "step" => h) :
        Dict{String,Any}("id" => "point_mass", "type" => "point_mass", "eids" => [1], "step" => h)
    k_dv = Dict{String,Any}("id" => "spring_k", "type" => "spring_stiffness", "eids" => [1])
    response = OpenJFEM.structural_mass_design_gradient(results, [mass_dv, k_dv])

    @test _relative_error(Float64(response["value"]), case.mass) < 1e-12
    @test Float64(response["gradient"]["spring_k"]) == 0.0
    model_p = OpenJFEM._tacs_model_with_design_delta(model, mass_dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, mass_dv, -h)
    fd = (_mass_value(model_p) - _mass_value(model_m)) / (2.0 * h)
    hook = Float64(response["gradient"]["point_mass"])
    @test _relative_error(hook, 1.0) < 1e-12
    @test _relative_error(fd, 1.0) < 1e-8
    @test _relative_error(hook, fd) < 1e-8
    return Dict(
        "mass" => Float64(response["value"]),
        "point_mass" => (fd, hook, _relative_error(hook, fd)),
    )
end

function main()
    pshell = _check_pshell_mass_gradients()
    pcomp = _check_pcomp_mass_gradient()
    tmp = mktempdir(; prefix="openjfem_tacs_mass_rods_")
    crod = _check_rod_mass_case(_write_crod_mass_deck(joinpath(tmp, "mass_crod.bdf")))
    conrod = _check_rod_mass_case(_write_conrod_mass_deck(joinpath(tmp, "mass_conrod.bdf")))
    point_tmp = mktempdir(; prefix="openjfem_tacs_mass_points_")
    point_cases = Dict(
        :conm2 => _check_point_mass_case(_write_point_mass_structural_deck(joinpath(point_tmp, "mass_conm2.bdf"), :conm2)),
        :cmass2 => _check_point_mass_case(_write_point_mass_structural_deck(joinpath(point_tmp, "mass_cmass2.bdf"), :cmass2)),
        :cmass1 => _check_point_mass_case(_write_point_mass_structural_deck(joinpath(point_tmp, "mass_cmass1.bdf"), :cmass1)),
    )
    println("TACS structural mass FD check passed")
    println("  PSHELL mass             = ", pshell["mass"])
    for name in ("thickness", "rho", "node_coord")
        fd, hook, rel = pshell[name]
        println("  dMass/d", name, " FD = ", fd, " hook = ", hook, " rel = ", rel)
    end
    println("  PCOMP mass              = ", pcomp["mass"])
    fd, hook, rel = pcomp["pcomp_ply_thickness"]
    println("  dMass/dpcomp_ply_t FD = ", fd, " hook = ", hook, " rel = ", rel)
    println("  CROD mass               = ", crod["mass"])
    for name in ("rod_area", "rod_rho", "rod_x")
        fd, hook, rel = crod[name]
        println("  CROD dMass/d", name, " FD = ", fd, " hook = ", hook, " rel = ", rel)
    end
    println("  CONROD mass             = ", conrod["mass"])
    for name in ("rod_area", "rod_rho", "rod_x")
        fd, hook, rel = conrod[name]
        println("  CONROD dMass/d", name, " FD = ", fd, " hook = ", hook, " rel = ", rel)
    end
    for name in (:conm2, :cmass2, :cmass1)
        check = point_cases[name]
        fd, hook, rel = check["point_mass"]
        println("  ", uppercase(string(name)), " mass          = ", check["mass"])
        println("  ", uppercase(string(name)), " dMass/dpoint_mass FD = ", fd, " hook = ", hook, " rel = ", rel)
    end
    return true
end

exit(main() ? 0 : 1)
