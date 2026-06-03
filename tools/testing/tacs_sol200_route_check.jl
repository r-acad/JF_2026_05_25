# Smoke check for routing SOL 200-lite through the TACS-formulation SOL101 backend.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol200_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,T1,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_tria3_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CTRIA3 SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CTRIA3,1,1,1,2,3")
        println(io, "CTRIA3,2,1,1,3,4")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,50.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,50.,0.,0.,-1.")
        println(io, "DESVAR,1,TTRIA,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.01
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS PCOMP SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,5.0E9,5.0E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,TPCOMP,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PCOMP,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_ply_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS PCOMP ply SOL200 optimization check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,PLY1T,0.003,0.001,0.01,0.0005")
        println(io, "DESVAR,2,PLY2A,45.,-90.,90.,5.0")
        println(io, "DVPREL1,1,PCOMP,1,T1,0.001,0.01,0.0,1,1.0")
        println(io, "DVPREL1,2,PCOMP,1,THETA2,-90.,90.,0.0,2,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_ply_mass_constrained_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS PCOMP ply constrained SOL200 check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx + 0.08 * j
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,45.,YES,1,0.0015,-30.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,PLY1T,0.003,0.001,0.01,0.0005")
        println(io, "DESVAR,2,PLY2A,45.,-90.,90.,5.0")
        println(io, "DVPREL1,1,PCOMP,1,T1,0.001,0.01,0.0,1,1.0")
        println(io, "DVPREL1,2,PCOMP,1,THETA2,-90.,90.,0.0,2,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,10.45")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat1_e_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT1 E SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,EMAT,7.0E10,3.5E10,1.4E11,0.2")
        println(io, "DVMREL1,1,MAT1,1,E,3.5E10,1.4E11,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat1_e_mass_constrained_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT1 E mass-constrained SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,EMATM,7.0E10,3.5E10,1.4E11,0.2")
        println(io, "DVMREL1,1,MAT1,1,E,3.5E10,1.4E11,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat1_rho_mass_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT1 RHO mass-objective SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,RHOMAT,2700.,1000.,5000.,500.")
        println(io, "DVMREL1,1,MAT1,1,RHO,1000.,5000.,0.0,1,1.0")
        println(io, "DRESP1,1,MASS,MASS")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-12,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat8_rho_mass_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT8 RHO PCOMP mass-objective SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,RHOM8,1600.,800.,2400.,300.")
        println(io, "DVMREL1,1,MAT8,1,RHO,800.,2400.,0.0,1,1.0")
        println(io, "DRESP1,1,MASS,MASS")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-12,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat8_stiffness_sol200_deck(path::AbstractString, field::AbstractString)
    field_key = uppercase(strip(field))
    field_key in ("E1", "E2", "G12", "NU12") || error("Unsupported MAT8 stiffness field $field")
    nx = 1
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]
    desvar_label =
        field_key == "E1" ? "E1M8" :
        field_key == "E2" ? "E2M8" :
        field_key == "G12" ? "G12M8" :
        "NU12M8"
    initial =
        field_key == "E1" ? "1.35E11" :
        field_key == "E2" ? "9.0E9" :
        field_key == "G12" ? "5.0E9" :
        "0.28"
    lower =
        field_key == "E1" ? "6.0E10" :
        field_key == "E2" ? "4.0E9" :
        field_key == "G12" ? "2.0E9" :
        "0.18"
    upper =
        field_key == "E1" ? "1.8E11" :
        field_key == "E2" ? "1.6E10" :
        field_key == "G12" ? "8.0E9" :
        "0.42"
    delx = field_key == "NU12" ? "0.05" : "0.2"

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT8 $field_key PCOMP compliance SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx + 0.08 * j
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,45.,YES,1,0.0015,-30.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,$desvar_label,$initial,$lower,$upper,$delx")
        println(io, "DVMREL1,1,MAT8,1,$field_key,$lower,$upper,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

_write_mat8_e1_sol200_deck(path::AbstractString) = _write_mat8_stiffness_sol200_deck(path, "E1")

function _write_mat1_nu_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT1 NU SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,NUMAT,0.3,0.2,0.45,0.05")
        println(io, "DVMREL1,1,MAT1,1,NU,0.2,0.45,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mat1_g_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS MAT1 G SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,GMAT,2.6923E10,1.5E10,4.0E10,0.2")
        println(io, "DVMREL1,1,MAT1,1,G,1.5E10,4.0E10,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_buckling_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 buckling route check")
        println(io, "DESOBJ(MAX) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
        println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "DESVAR,1,TBUCK,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,LAM,LAMA")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,100.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_displacement_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 displacement-response route check")
        println(io, "DESOBJ(MIN) = 2")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,2.,0.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "GRID,5,,1.,1.,0.")
        println(io, "GRID,6,,2.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,2,2,3,6,5")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "PSHELL,2,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,2,3")
        println(io, "FORCE,1,4,0,25.,0.,0.,-1.")
        println(io, "FORCE,1,5,0,25.,0.,0.,-1.")
        println(io, "FORCE,1,6,0,25.,0.,0.,-1.")
        println(io, "DESVAR,1,TDISP1,$thickness,0.005,0.05,0.2")
        println(io, "DESVAR,2,TDISP2,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DVPREL1,2,PSHELL,2,T,0.005,0.05,0.0,2,1.0")
        println(io, "DRESP1,1,UZ6,DISP,,,6,3")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,1,,1.0E-3")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _write_stress_ks_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 stress KS response route check")
        println(io, "DESOBJ(MIN) = 1")
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
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "DRESP1,1,VM,VMSTRS,,,,1")
        println(io, "DOPTPRM,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_stress_ks_design_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 stress KS design-gradient route check")
        println(io, "DESOBJ(MIN) = 1")
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
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "DESVAR,1,TSTRESS,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,VM,VMSTRS,,,,1")
        println(io, "DOPTPRM,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_stress_constrained_mass_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 stress-constrained mass route check")
        println(io, "DESOBJ(MIN) = 1")
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
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "DESVAR,1,TSTC,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,MASS,MASS")
        println(io, "DRESP1,2,VM,VMSTRS,,,,1")
        println(io, "DCONSTR,1,2,,2.0E6")
        println(io, "DOPTPRM,DESMAX,10,CONV1,1.0E-6,DELX,0.2,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_stress_constrained_multi_mass_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 multi-group stress-constrained mass route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,2.,0.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "GRID,5,,1.,1.,0.")
        println(io, "GRID,6,,2.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,2,2,3,6,5")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "PSHELL,2,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,2,3")
        println(io, "FORCE,1,4,0,50.,0.,0.,-1.")
        println(io, "FORCE,1,5,0,50.,0.,0.,-1.")
        println(io, "FORCE,1,6,0,50.,0.,0.,-1.")
        println(io, "DESVAR,1,TSTC1,$thickness,0.005,0.05,0.2")
        println(io, "DESVAR,2,TSTC2,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DVPREL1,2,PSHELL,2,T,0.005,0.05,0.0,2,1.0")
        println(io, "DRESP1,1,MASS,MASS")
        println(io, "DRESP1,2,VM,VMSTRS")
        println(io, "DCONSTR,1,2,,1.2E6")
        println(io, "DOPTPRM,DESMAX,12,CONV1,1.0E-6,DELX,0.2,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_stress_ks_design_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.01
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS PCOMP SOL200 stress KS design-gradient route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,5.0E9,5.0E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,TPCST,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PCOMP,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,VM,VMSTRS,,,,1")
        println(io, "DOPTPRM,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_stress_constrained_mass_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.01
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS PCOMP SOL200 stress-constrained mass route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,5.0E9,5.0E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,25.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,TPCSTM,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PCOMP,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,MASS,MASS")
        println(io, "DRESP1,2,VM,VMSTRS,,,,1")
        println(io, "DCONSTR,1,2,,1.0E6")
        println(io, "DOPTPRM,DESMAX,10,CONV1,1.0E-6,DELX,0.2,KSRHO,25.")
        println(io, "ENDDATA")
    end
    return path
end

function _check_route(deck::AbstractString; expected_property_type::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["backend_version"] == "0.1.0-dev"
    @test results["route_summary"]["translated_objective"] == "min_compliance"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["forward_results"]["sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"
    @test results["forward_results"]["formulation"]["shell"] == "residual_first_quad4_tria3_sol101_sol103_sol105_sol106"
    @test results["forward_results"]["formulation"]["thickness_derivative"] == "element_ad"
    prop = first(values(results["forward_results"]["model"]["PSHELLs"]))
    @test uppercase(string(get(prop, "TYPE", "PSHELL"))) == expected_property_type

    iterations = results["optimization"]["iterations"]
    @test length(iterations) == 1
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["formulation"]["thickness_derivative"] == "element_ad"
    return results, diagnostics
end

function _check_stress_ks_route(deck::AbstractString; expect_design_gradient::Bool=false)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    @test opt["responses"][1]["candidate_response_family"] == "von_mises"
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_response_ids"])
    @test "von_mises" in opt["sol200_lite_readiness"]["supported_execution_response_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_STRESS_RESPONSE"
    @test results["route_summary"]["translation_mode"] == "stress_ks_response"
    @test results["route_summary"]["translated_objective"] == "min_stress_ks_response"
    @test results["route_summary"]["objective_response_family"] == "von_mises"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["route_summary"]["stress_aggregation"] == "ks_von_mises"
    @test results["route_summary"]["ks_rho"] == 25.0
    @test results["forward_results"]["sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"

    opt_result = results["optimization"]
    @test opt_result["n_iter"] == 1
    @test opt_result["design_variable_count"] == (expect_design_gradient ? 1 : 0)
    @test isfinite(Float64(opt_result["stress_ks_response"]))
    @test isfinite(Float64(opt_result["peak_von_mises"]))
    @test Float64(opt_result["stress_ks_response"]) >= Float64(opt_result["peak_von_mises"])
    @test Float64(opt_result["peak_von_mises"]) > 0.0
    @test length(opt_result["stress_values"]) == 1

    diagnostics = only(opt_result["iterations"])["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["response"] == "ks_von_mises"
    if expect_design_gradient
        @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_stress_adjoint_design_tangent"
    else
        @test diagnostics["sensitivity"]["gradient_backend"] == "not_computed_response_only"
    end
    return results, diagnostics
end

function _check_stress_ks_design_route(deck::AbstractString; gradient_label::AbstractString="TSTRESS")
    results, diagnostics = _check_stress_ks_route(deck; expect_design_gradient=true)
    @test results["optimization"]["design_variable_count"] == 1
    @test results["optimization"]["design_variable_types"] == ["shell_thickness"]
    @test haskey(results["optimization"]["gradients"], gradient_label)
    @test isfinite(Float64(results["optimization"]["gradients"][gradient_label]))
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_stress_adjoint_design_tangent"
    @test diagnostics["sensitivity"]["design_variable_type"] == "mixed"
    return results, diagnostics
end

function _check_stress_constrained_mass_route(deck::AbstractString;
    response_upper_bound::Float64=2.0e6,
    require_final_mass_not_above_initial::Bool=true)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["responses"], "candidate_response_family", nothing)))
    @test families == ["mass", "von_mises"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_response_ids"])

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_mass_static_response"
    @test results["route_summary"]["constraint_response_family"] == "ks_von_mises"
    @test results["route_summary"]["constraint_ks_rho"] == 25.0
    @test results["route_summary"]["single_group_exact_search"] == true
    @test results["forward_results"]["backend"] == "tacs_formulation"

    opt_result = results["optimization"]
    @test opt_result["response_family"] == "ks_von_mises"
    @test Float64(opt_result["response_upper_bound"]) == response_upper_bound
    @test Float64(opt_result["response_value"]) <= response_upper_bound * (1.0 + 1e-8)
    if require_final_mass_not_above_initial
        @test Float64(opt_result["final_mass"]) <= Float64(opt_result["mass_initial"])
    else
        @test Float64(opt_result["final_mass"]) > 0.0
    end
    iterations = opt_result["iterations"]
    @test !isempty(iterations)
    diagnostics = iterations[end]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    return results, diagnostics
end

function _check_stress_constrained_multi_mass_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["responses"], "candidate_response_family", nothing)))
    @test families == ["mass", "von_mises"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_response_ids"])

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_mass_static_response"
    @test results["route_summary"]["constraint_response_family"] == "ks_von_mises"
    @test results["route_summary"]["constraint_ks_rho"] == 25.0
    @test results["route_summary"]["single_group_exact_search"] == false
    @test results["route_summary"]["multi_group_response_search"] == true
    @test results["forward_results"]["backend"] == "tacs_formulation"

    opt_result = results["optimization"]
    @test opt_result["response_family"] == "ks_von_mises"
    @test Float64(opt_result["response_upper_bound"]) == 1.2e6
    @test Float64(opt_result["response_value"]) <= 1.2e6 * (1.0 + 1e-8)
    @test Float64(opt_result["final_mass"]) <= Float64(opt_result["mass_initial"])
    @test length(opt_result["iterations"]) >= 2
    sensitivity_diagnostics = [
        iter["solver_diagnostics"]["sensitivity"]
        for iter in opt_result["iterations"]
        if haskey(iter["solver_diagnostics"], "sensitivity") &&
           get(iter["solver_diagnostics"]["sensitivity"], "response", nothing) == "ks_von_mises"
    ]
    @test !isempty(sensitivity_diagnostics)
    @test any(
        get(diagnostics, "gradient_backend", nothing) == "tacs_formulation_stress_adjoint_design_tangent"
        for diagnostics in sensitivity_diagnostics
    )
    diagnostics = opt_result["iterations"][end]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    return results, diagnostics
end

function _check_buckling_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["route_summary"]["translated_objective"] == "max_buckling"
    @test results["route_summary"]["forward_sol_type"] == 105
    @test results["forward_results"]["sol_type"] == 105
    @test results["forward_results"]["backend"] == "tacs_formulation"
    @test results["forward_results"]["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_tria3"
    @test !isempty(results["forward_results"]["eigenvalues"])

    iterations = results["optimization"]["iterations"]
    @test length(iterations) == 1
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_tria3"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    @test diagnostics["sensitivity"]["response"] == "buckling_load_factor"
    return results, diagnostics
end

function _check_displacement_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["route_summary"]["translated_objective"] == "min_mass_static_response"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["route_summary"]["constraint_response_family"] == "displacement"
    @test results["forward_results"]["sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test !isempty(iterations)
    diagnostics = iterations[end]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_element_ad_adjoint"
    @test diagnostics["sensitivity"]["response"] == "displacement"
    @test diagnostics["sensitivity"]["grid"] == 6
    @test diagnostics["sensitivity"]["dof"] == 3
    return results, diagnostics
end

function _check_pcomp_ply_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["property_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["pcomp_ply_angle", "pcomp_ply_thickness"]
    @test sort!(Int[get(rel, "ply_index", 0) for rel in opt["property_relations"]]) == [1, 2]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_PCOMP_PLY_OPTIMIZATION"
    @test results["route_summary"]["translation_mode"] == "pcomp_ply_projected_gradient"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_design_tangent"
    gradient = iterations[1]["gradient"]
    @test haskey(gradient, "PLY1T")
    @test haskey(gradient, "PLY2A")
    @test isfinite(Float64(gradient["PLY1T"]))
    @test isfinite(Float64(gradient["PLY2A"]))
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test any(abs(Float64(final[key]) - Float64(initial[key])) > 0.0 for key in keys(initial))
    return results, diagnostics
end

function _check_pcomp_ply_mass_constrained_route(deck::AbstractString)
    results, diagnostics = _check_pcomp_ply_route(deck)
    @test results["route_summary"]["constraint_response_family"] == "mass"
    @test results["route_summary"]["absolute_mass_target"] == 10.45
    @test results["optimization"]["mass_target"] == 10.45
    @test results["optimization"]["final_mass"] <= 10.45 * (1.0 + 1e-8)
    @test all(Float64(iter["mass_constraint_violation"]) <= 1e-8 for iter in results["optimization"]["iterations"][2:end])
    @test Float64(results["optimization"]["mass_coefficients"]["PLY1T"]) > 0.0
    @test Float64(results["optimization"]["mass_coefficients"]["PLY2A"]) == 0.0
    return results, diagnostics
end

function _check_mat1_e_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["material_E"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test "material_E" in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translation_mode"] == "material_projected_gradient"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_design_tangent"
    @test diagnostics["sensitivity"]["design_variable_type"] == "mixed"
    gradient = iterations[1]["gradient"]
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    labels = collect(keys(initial))
    @test length(labels) == 1
    label = only(labels)
    @test haskey(gradient, label)
    @test isfinite(Float64(gradient[label]))
    @test abs(Float64(final[label]) - Float64(initial[label])) > 0.0
    return results, diagnostics
end

function _check_mat1_e_mass_constrained_route(deck::AbstractString)
    results, diagnostics = _check_mat1_e_route(deck)
    @test results["route_summary"]["constraint_response_family"] == "mass"
    @test results["route_summary"]["absolute_mass_target"] == 60.0
    @test results["optimization"]["mass_target"] == 60.0
    @test isapprox(Float64(results["optimization"]["mass_initial"]), 54.0; rtol=1e-12, atol=0.0)
    @test isapprox(Float64(results["optimization"]["final_mass"]), 54.0; rtol=1e-12, atol=0.0)
    @test Float64(results["optimization"]["mass_coefficients"]["EMATM"]) == 0.0
    @test all(Float64(iter["mass_constraint_violation"]) == 0.0 for iter in results["optimization"]["iterations"])
    return results, diagnostics
end

function _check_mat1_rho_mass_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["material_RHO"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test "material_RHO" in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_mass_material_density_projected_gradient"
    @test results["route_summary"]["design_variable_types"] == ["material_RHO"]
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["response"] == "mass"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_material_mass_coefficient"
    @test isapprox(Float64(results["optimization"]["mass_initial"]), 54.0; rtol=1e-12, atol=0.0)
    @test isapprox(Float64(results["optimization"]["mass_coefficients"]["RHOMAT"]), 0.02; rtol=1e-12, atol=0.0)
    @test Float64(results["optimization"]["final_mass"]) < Float64(results["optimization"]["mass_initial"])
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test Float64(final["RHOMAT"]) < Float64(initial["RHOMAT"])
    @test Float64(results["optimization"]["model"]["MATs"]["1"]["RHO"]) == Float64(final["RHOMAT"])
    return results, diagnostics
end

function _check_mat8_rho_mass_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["material_RHO"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test "material_RHO" in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_mass_material_density_projected_gradient"
    @test results["route_summary"]["design_variable_types"] == ["material_RHO"]
    @test results["forward_results"]["backend"] == "tacs_formulation"
    prop = first(values(results["forward_results"]["model"]["PSHELLs"]))
    @test uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["response"] == "mass"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_material_mass_coefficient"
    @test isapprox(Float64(results["optimization"]["mass_initial"]), 16.0; rtol=1e-12, atol=0.0)
    @test isapprox(Float64(results["optimization"]["mass_coefficients"]["RHOM8"]), 0.01; rtol=1e-12, atol=0.0)
    @test Float64(results["optimization"]["final_mass"]) < Float64(results["optimization"]["mass_initial"])
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test Float64(final["RHOM8"]) < Float64(initial["RHOM8"])
    @test Float64(results["optimization"]["model"]["MATs"]["1"]["RHO"]) == Float64(final["RHOM8"])
    return results, diagnostics
end

function _check_mat8_stiffness_route(deck::AbstractString, field::AbstractString, desvar_label::AbstractString)
    field_key = uppercase(strip(field))
    family = "material_$field_key"
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == [family]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test family in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    initial_cm = copy(model["PSHELLs"]["1"]["Cm"])
    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translation_mode"] == "material_projected_gradient"
    @test results["route_summary"]["design_variable_types"] == [family]
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_design_tangent"
    gradient = iterations[1]["gradient"]
    @test haskey(gradient, desvar_label)
    @test isfinite(Float64(gradient[desvar_label]))
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test abs(Float64(final[desvar_label]) - Float64(initial[desvar_label])) > 0.0
    final_mat = results["optimization"]["model"]["MATs"]["1"]
    @test Float64(final_mat[field_key]) == Float64(final[desvar_label])
    field_key == "E1" && @test Float64(final_mat["E"]) == Float64(final[desvar_label])
    field_key == "G12" && @test Float64(final_mat["G"]) == Float64(final[desvar_label])
    field_key == "NU12" && @test Float64(final_mat["NU"]) == Float64(final[desvar_label])
    final_cm = results["optimization"]["model"]["PSHELLs"]["1"]["Cm"]
    @test maximum(abs.(Float64.(final_cm) .- Float64.(initial_cm))) > 0.0
    return results, diagnostics
end

_check_mat8_e1_route(deck::AbstractString) = _check_mat8_stiffness_route(deck, "E1", "E1M8")

function _check_mat1_nu_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["material_NU"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test "material_NU" in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translation_mode"] == "material_projected_gradient"
    @test results["route_summary"]["design_variable_types"] == ["material_NU"]
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_design_tangent"
    gradient = iterations[1]["gradient"]
    @test haskey(gradient, "NUMAT")
    @test isfinite(Float64(gradient["NUMAT"]))
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test abs(Float64(final["NUMAT"]) - Float64(initial["NUMAT"])) > 0.0
    final_nu = Float64(results["optimization"]["model"]["MATs"]["1"]["NU"])
    final_g = Float64(results["optimization"]["model"]["MATs"]["1"]["G"])
    final_e = Float64(results["optimization"]["model"]["MATs"]["1"]["E"])
    @test isapprox(final_g, final_e / (2.0 * (1.0 + final_nu)); rtol=1e-12, atol=0.0)
    return results, diagnostics
end

function _check_mat1_g_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["material_relations"], "candidate_design_variable_family", nothing)))
    @test families == ["material_G"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_material_relation_ids"])
    @test "material_G" in opt["sol200_lite_readiness"]["supported_execution_relation_families"]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_MATERIAL_OPTIMIZATION"
    @test results["route_summary"]["translation_mode"] == "material_projected_gradient"
    @test results["route_summary"]["design_variable_types"] == ["material_G"]
    @test results["forward_results"]["backend"] == "tacs_formulation"

    iterations = results["optimization"]["iterations"]
    @test length(iterations) >= 2
    diagnostics = iterations[1]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_design_tangent"
    gradient = iterations[1]["gradient"]
    @test haskey(gradient, "GMAT")
    @test isfinite(Float64(gradient["GMAT"]))
    initial = results["optimization"]["initial_design_variables"]
    final = results["optimization"]["design_variables"]
    @test abs(Float64(final["GMAT"]) - Float64(initial["GMAT"])) > 0.0
    final_mat = results["optimization"]["model"]["MATs"]["1"]
    @test Float64(final_mat["E"]) == 7.0e10
    @test Float64(final_mat["NU"]) == 0.3
    @test Float64(final_mat["G"]) == Float64(final["GMAT"])
    return results, diagnostics
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol200_route_")
    route_filter = lowercase(strip(get(ENV, "JFEM_TACS_SOL200_ROUTE_FILTER", "all")))

    if route_filter in ("stress", "stress_only")
        stress_ks_deck = _write_stress_ks_sol200_deck(joinpath(tmp, "tacs_stress_ks_sol200_route.bdf"))
        stress_ks_design_deck = _write_stress_ks_design_sol200_deck(joinpath(tmp, "tacs_stress_ks_design_sol200_route.bdf"))
        stress_constrained_mass_deck = _write_stress_constrained_mass_sol200_deck(joinpath(tmp, "tacs_stress_constrained_mass_sol200_route.bdf"))
        stress_constrained_multi_mass_deck = _write_stress_constrained_multi_mass_sol200_deck(joinpath(tmp, "tacs_stress_constrained_multi_mass_sol200_route.bdf"))
        pcomp_stress_ks_design_deck = _write_pcomp_stress_ks_design_sol200_deck(joinpath(tmp, "tacs_pcomp_stress_ks_design_sol200_route.bdf"))
        pcomp_stress_constrained_mass_deck = _write_pcomp_stress_constrained_mass_sol200_deck(joinpath(tmp, "tacs_pcomp_stress_constrained_mass_sol200_route.bdf"))

        stress_ks_results, stress_ks_diagnostics = _check_stress_ks_route(stress_ks_deck)
        stress_ks_design_results, stress_ks_design_diagnostics = _check_stress_ks_design_route(stress_ks_design_deck)
        stress_mass_results, stress_mass_diagnostics = _check_stress_constrained_mass_route(stress_constrained_mass_deck)
        stress_multi_mass_results, stress_multi_mass_diagnostics = _check_stress_constrained_multi_mass_route(stress_constrained_multi_mass_deck)
        pcomp_stress_ks_design_results, pcomp_stress_ks_design_diagnostics = _check_stress_ks_design_route(pcomp_stress_ks_design_deck; gradient_label="TPCST")
        pcomp_stress_mass_results, pcomp_stress_mass_diagnostics = _check_stress_constrained_mass_route(
            pcomp_stress_constrained_mass_deck;
            response_upper_bound=1.0e6,
            require_final_mass_not_above_initial=false,
        )

        println("TACS SOL200 stress route check passed")
        println("  stress ks deck        = ", abspath(stress_ks_deck))
        println("  stress ks design deck = ", abspath(stress_ks_design_deck))
        println("  stress mass deck      = ", abspath(stress_constrained_mass_deck))
        println("  stress multi mass deck = ", abspath(stress_constrained_multi_mass_deck))
        println("  pcomp stress ks design deck = ", abspath(pcomp_stress_ks_design_deck))
        println("  pcomp stress mass deck = ", abspath(pcomp_stress_constrained_mass_deck))
        println("  stress ks objective   = ", stress_ks_results["route_summary"]["translated_objective"])
        println("  stress ks value       = ", stress_ks_results["optimization"]["stress_ks_response"])
        println("  stress ks sensitivity = ", stress_ks_diagnostics["sensitivity"]["gradient_backend"])
        println("  stress ks design gradient = ", stress_ks_design_results["optimization"]["gradients"]["TSTRESS"])
        println("  stress ks design sensitivity = ", stress_ks_design_diagnostics["sensitivity"]["gradient_backend"])
        println("  stress mass final response = ", stress_mass_results["optimization"]["response_value"])
        println("  stress mass route      = ", stress_mass_results["optimization"]["response_family"])
        println("  stress multi mass final response = ", stress_multi_mass_results["optimization"]["response_value"])
        println("  stress multi mass sensitivity = ", stress_multi_mass_diagnostics["sensitivity"]["gradient_backend"])
        println("  pcomp stress ks design gradient = ", pcomp_stress_ks_design_results["optimization"]["gradients"]["TPCST"])
        println("  pcomp stress ks design sensitivity = ", pcomp_stress_ks_design_diagnostics["sensitivity"]["gradient_backend"])
        println("  pcomp stress mass final response = ", pcomp_stress_mass_results["optimization"]["response_value"])
        println("  pcomp stress mass route = ", pcomp_stress_mass_results["optimization"]["response_family"])
        return true
    elseif route_filter in ("material", "materials", "material_only")
        mat1_e_deck = _write_mat1_e_sol200_deck(joinpath(tmp, "tacs_mat1_e_sol200_route.bdf"))
        mat1_e_mass_deck = _write_mat1_e_mass_constrained_sol200_deck(joinpath(tmp, "tacs_mat1_e_mass_sol200_route.bdf"))
        mat1_rho_deck = _write_mat1_rho_mass_sol200_deck(joinpath(tmp, "tacs_mat1_rho_mass_sol200_route.bdf"))
        mat8_rho_deck = _write_mat8_rho_mass_sol200_deck(joinpath(tmp, "tacs_mat8_rho_mass_sol200_route.bdf"))
        mat8_e1_deck = _write_mat8_e1_sol200_deck(joinpath(tmp, "tacs_mat8_e1_sol200_route.bdf"))
        mat8_e2_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_e2_sol200_route.bdf"), "E2")
        mat8_g12_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_g12_sol200_route.bdf"), "G12")
        mat8_nu12_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_nu12_sol200_route.bdf"), "NU12")
        mat1_nu_deck = _write_mat1_nu_sol200_deck(joinpath(tmp, "tacs_mat1_nu_sol200_route.bdf"))
        mat1_g_deck = _write_mat1_g_sol200_deck(joinpath(tmp, "tacs_mat1_g_sol200_route.bdf"))

        mat1_e_results, mat1_e_diagnostics = _check_mat1_e_route(mat1_e_deck)
        mat1_e_mass_results, mat1_e_mass_diagnostics = _check_mat1_e_mass_constrained_route(mat1_e_mass_deck)
        mat1_rho_results, mat1_rho_diagnostics = _check_mat1_rho_mass_route(mat1_rho_deck)
        mat8_rho_results, mat8_rho_diagnostics = _check_mat8_rho_mass_route(mat8_rho_deck)
        mat8_e1_results, mat8_e1_diagnostics = _check_mat8_e1_route(mat8_e1_deck)
        mat8_e2_results, mat8_e2_diagnostics = _check_mat8_stiffness_route(mat8_e2_deck, "E2", "E2M8")
        mat8_g12_results, mat8_g12_diagnostics = _check_mat8_stiffness_route(mat8_g12_deck, "G12", "G12M8")
        mat8_nu12_results, mat8_nu12_diagnostics = _check_mat8_stiffness_route(mat8_nu12_deck, "NU12", "NU12M8")
        mat1_nu_results, mat1_nu_diagnostics = _check_mat1_nu_route(mat1_nu_deck)
        mat1_g_results, mat1_g_diagnostics = _check_mat1_g_route(mat1_g_deck)

        println("TACS SOL200 material route check passed")
        println("  mat1 e deck           = ", abspath(mat1_e_deck))
        println("  mat1 e mass deck      = ", abspath(mat1_e_mass_deck))
        println("  mat1 rho deck         = ", abspath(mat1_rho_deck))
        println("  mat8 rho deck         = ", abspath(mat8_rho_deck))
        println("  mat8 e1 deck          = ", abspath(mat8_e1_deck))
        println("  mat8 e2 deck          = ", abspath(mat8_e2_deck))
        println("  mat8 g12 deck         = ", abspath(mat8_g12_deck))
        println("  mat8 nu12 deck        = ", abspath(mat8_nu12_deck))
        println("  mat1 nu deck          = ", abspath(mat1_nu_deck))
        println("  mat1 g deck           = ", abspath(mat1_g_deck))
        println("  mat1 e sensitivity    = ", mat1_e_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat1 e mass sensitivity = ", mat1_e_mass_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat1 rho sensitivity  = ", mat1_rho_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 rho sensitivity  = ", mat8_rho_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 e1 sensitivity   = ", mat8_e1_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 e1 final value   = ", mat8_e1_results["optimization"]["design_variables"]["E1M8"])
        println("  mat8 e2 sensitivity   = ", mat8_e2_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 e2 final value   = ", mat8_e2_results["optimization"]["design_variables"]["E2M8"])
        println("  mat8 g12 sensitivity  = ", mat8_g12_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 g12 final value  = ", mat8_g12_results["optimization"]["design_variables"]["G12M8"])
        println("  mat8 nu12 sensitivity = ", mat8_nu12_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat8 nu12 final value = ", mat8_nu12_results["optimization"]["design_variables"]["NU12M8"])
        println("  mat1 nu sensitivity   = ", mat1_nu_diagnostics["sensitivity"]["gradient_backend"])
        println("  mat1 g sensitivity    = ", mat1_g_diagnostics["sensitivity"]["gradient_backend"])
        return true
    elseif route_filter != "all"
        error("Unsupported JFEM_TACS_SOL200_ROUTE_FILTER='$route_filter'. Supported values: all, stress, material")
    end

    deck = _write_sol200_deck(joinpath(tmp, "tacs_sol200_route.bdf"))
    tria3_deck = _write_tria3_sol200_deck(joinpath(tmp, "tacs_tria3_sol200_route.bdf"))
    pcomp_deck = _write_pcomp_sol200_deck(joinpath(tmp, "tacs_pcomp_sol200_route.bdf"))
    pcomp_ply_deck = _write_pcomp_ply_sol200_deck(joinpath(tmp, "tacs_pcomp_ply_sol200_route.bdf"))
    pcomp_ply_mass_deck = _write_pcomp_ply_mass_constrained_sol200_deck(joinpath(tmp, "tacs_pcomp_ply_mass_sol200_route.bdf"))
    mat1_e_deck = _write_mat1_e_sol200_deck(joinpath(tmp, "tacs_mat1_e_sol200_route.bdf"))
    mat1_e_mass_deck = _write_mat1_e_mass_constrained_sol200_deck(joinpath(tmp, "tacs_mat1_e_mass_sol200_route.bdf"))
    mat1_rho_deck = _write_mat1_rho_mass_sol200_deck(joinpath(tmp, "tacs_mat1_rho_mass_sol200_route.bdf"))
    mat8_rho_deck = _write_mat8_rho_mass_sol200_deck(joinpath(tmp, "tacs_mat8_rho_mass_sol200_route.bdf"))
    mat8_e1_deck = _write_mat8_e1_sol200_deck(joinpath(tmp, "tacs_mat8_e1_sol200_route.bdf"))
    mat8_e2_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_e2_sol200_route.bdf"), "E2")
    mat8_g12_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_g12_sol200_route.bdf"), "G12")
    mat8_nu12_deck = _write_mat8_stiffness_sol200_deck(joinpath(tmp, "tacs_mat8_nu12_sol200_route.bdf"), "NU12")
    mat1_nu_deck = _write_mat1_nu_sol200_deck(joinpath(tmp, "tacs_mat1_nu_sol200_route.bdf"))
    mat1_g_deck = _write_mat1_g_sol200_deck(joinpath(tmp, "tacs_mat1_g_sol200_route.bdf"))
    buckling_deck = _write_buckling_sol200_deck(joinpath(tmp, "tacs_buckling_sol200_route.bdf"))
    displacement_deck = _write_displacement_sol200_deck(joinpath(tmp, "tacs_displacement_sol200_route.bdf"))
    stress_ks_deck = _write_stress_ks_sol200_deck(joinpath(tmp, "tacs_stress_ks_sol200_route.bdf"))
    stress_ks_design_deck = _write_stress_ks_design_sol200_deck(joinpath(tmp, "tacs_stress_ks_design_sol200_route.bdf"))
    stress_constrained_mass_deck = _write_stress_constrained_mass_sol200_deck(joinpath(tmp, "tacs_stress_constrained_mass_sol200_route.bdf"))
    stress_constrained_multi_mass_deck = _write_stress_constrained_multi_mass_sol200_deck(joinpath(tmp, "tacs_stress_constrained_multi_mass_sol200_route.bdf"))
    pcomp_stress_ks_design_deck = _write_pcomp_stress_ks_design_sol200_deck(joinpath(tmp, "tacs_pcomp_stress_ks_design_sol200_route.bdf"))
    pcomp_stress_constrained_mass_deck = _write_pcomp_stress_constrained_mass_sol200_deck(joinpath(tmp, "tacs_pcomp_stress_constrained_mass_sol200_route.bdf"))
    results, diagnostics = _check_route(deck; expected_property_type="PSHELL")
    tria3_results, tria3_diagnostics = _check_route(tria3_deck; expected_property_type="PSHELL")
    pcomp_results, pcomp_diagnostics = _check_route(pcomp_deck; expected_property_type="PCOMP_CLT")
    pcomp_ply_results, pcomp_ply_diagnostics = _check_pcomp_ply_route(pcomp_ply_deck)
    pcomp_ply_mass_results, pcomp_ply_mass_diagnostics = _check_pcomp_ply_mass_constrained_route(pcomp_ply_mass_deck)
    mat1_e_results, mat1_e_diagnostics = _check_mat1_e_route(mat1_e_deck)
    mat1_e_mass_results, mat1_e_mass_diagnostics = _check_mat1_e_mass_constrained_route(mat1_e_mass_deck)
    mat1_rho_results, mat1_rho_diagnostics = _check_mat1_rho_mass_route(mat1_rho_deck)
    mat8_rho_results, mat8_rho_diagnostics = _check_mat8_rho_mass_route(mat8_rho_deck)
    mat8_e1_results, mat8_e1_diagnostics = _check_mat8_e1_route(mat8_e1_deck)
    mat8_e2_results, mat8_e2_diagnostics = _check_mat8_stiffness_route(mat8_e2_deck, "E2", "E2M8")
    mat8_g12_results, mat8_g12_diagnostics = _check_mat8_stiffness_route(mat8_g12_deck, "G12", "G12M8")
    mat8_nu12_results, mat8_nu12_diagnostics = _check_mat8_stiffness_route(mat8_nu12_deck, "NU12", "NU12M8")
    mat1_nu_results, mat1_nu_diagnostics = _check_mat1_nu_route(mat1_nu_deck)
    mat1_g_results, mat1_g_diagnostics = _check_mat1_g_route(mat1_g_deck)
    buckling_results, buckling_diagnostics = _check_buckling_route(buckling_deck)
    displacement_results, displacement_diagnostics = _check_displacement_route(displacement_deck)
    stress_ks_results, stress_ks_diagnostics = _check_stress_ks_route(stress_ks_deck)
    stress_ks_design_results, stress_ks_design_diagnostics = _check_stress_ks_design_route(stress_ks_design_deck)
    stress_mass_results, stress_mass_diagnostics = _check_stress_constrained_mass_route(stress_constrained_mass_deck)
    stress_multi_mass_results, stress_multi_mass_diagnostics = _check_stress_constrained_multi_mass_route(stress_constrained_multi_mass_deck)
    pcomp_stress_ks_design_results, pcomp_stress_ks_design_diagnostics = _check_stress_ks_design_route(pcomp_stress_ks_design_deck; gradient_label="TPCST")
    pcomp_stress_mass_results, pcomp_stress_mass_diagnostics = _check_stress_constrained_mass_route(
        pcomp_stress_constrained_mass_deck;
        response_upper_bound=1.0e6,
        require_final_mass_not_above_initial=false,
    )

    println("TACS SOL200 route check passed")
    println("  deck                  = ", abspath(deck))
    println("  tria3 deck            = ", abspath(tria3_deck))
    println("  pcomp deck            = ", abspath(pcomp_deck))
    println("  pcomp ply deck        = ", abspath(pcomp_ply_deck))
    println("  pcomp ply mass deck   = ", abspath(pcomp_ply_mass_deck))
    println("  mat1 e deck           = ", abspath(mat1_e_deck))
    println("  mat1 e mass deck      = ", abspath(mat1_e_mass_deck))
    println("  mat1 rho deck         = ", abspath(mat1_rho_deck))
    println("  mat8 rho deck         = ", abspath(mat8_rho_deck))
    println("  mat8 e1 deck          = ", abspath(mat8_e1_deck))
    println("  mat8 e2 deck          = ", abspath(mat8_e2_deck))
    println("  mat8 g12 deck         = ", abspath(mat8_g12_deck))
    println("  mat8 nu12 deck        = ", abspath(mat8_nu12_deck))
    println("  mat1 nu deck          = ", abspath(mat1_nu_deck))
    println("  mat1 g deck           = ", abspath(mat1_g_deck))
    println("  buckling deck         = ", abspath(buckling_deck))
    println("  displacement deck     = ", abspath(displacement_deck))
    println("  stress ks deck        = ", abspath(stress_ks_deck))
    println("  stress ks design deck = ", abspath(stress_ks_design_deck))
    println("  stress mass deck      = ", abspath(stress_constrained_mass_deck))
    println("  stress multi mass deck = ", abspath(stress_constrained_multi_mass_deck))
    println("  pcomp stress ks design deck = ", abspath(pcomp_stress_ks_design_deck))
    println("  pcomp stress mass deck = ", abspath(pcomp_stress_constrained_mass_deck))
    println("  translated objective  = ", results["route_summary"]["translated_objective"])
    println("  final forward backend = ", results["forward_results"]["backend"])
    println("  iteration backend     = ", diagnostics["backend"])
    println("  tria3 forward backend = ", tria3_results["forward_results"]["backend"])
    println("  tria3 iteration backend = ", tria3_diagnostics["backend"])
    println("  pcomp forward backend = ", pcomp_results["forward_results"]["backend"])
    println("  pcomp iteration backend = ", pcomp_diagnostics["backend"])
    println("  pcomp ply route       = ", pcomp_ply_results["route_summary"]["translation_mode"])
    println("  pcomp ply sensitivity = ", pcomp_ply_diagnostics["sensitivity"]["gradient_backend"])
    println("  pcomp ply mass target = ", pcomp_ply_mass_results["optimization"]["mass_target"])
    println("  pcomp ply mass sensitivity = ", pcomp_ply_mass_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat1 e route          = ", mat1_e_results["route_summary"]["translation_mode"])
    println("  mat1 e mass target    = ", mat1_e_mass_results["optimization"]["mass_target"])
    println("  mat1 e sensitivity    = ", mat1_e_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat1 e mass sensitivity = ", mat1_e_mass_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat1 rho objective    = ", mat1_rho_results["route_summary"]["translated_objective"])
    println("  mat1 rho sensitivity  = ", mat1_rho_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat8 rho objective    = ", mat8_rho_results["route_summary"]["translated_objective"])
    println("  mat8 rho sensitivity  = ", mat8_rho_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat8 e1 route         = ", mat8_e1_results["route_summary"]["translation_mode"])
    println("  mat8 e1 sensitivity   = ", mat8_e1_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat8 e2 route         = ", mat8_e2_results["route_summary"]["translation_mode"])
    println("  mat8 e2 sensitivity   = ", mat8_e2_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat8 g12 route        = ", mat8_g12_results["route_summary"]["translation_mode"])
    println("  mat8 g12 sensitivity  = ", mat8_g12_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat8 nu12 route       = ", mat8_nu12_results["route_summary"]["translation_mode"])
    println("  mat8 nu12 sensitivity = ", mat8_nu12_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat1 nu route         = ", mat1_nu_results["route_summary"]["translation_mode"])
    println("  mat1 nu sensitivity   = ", mat1_nu_diagnostics["sensitivity"]["gradient_backend"])
    println("  mat1 g route          = ", mat1_g_results["route_summary"]["translation_mode"])
    println("  mat1 g sensitivity    = ", mat1_g_diagnostics["sensitivity"]["gradient_backend"])
    println("  buckling objective    = ", buckling_results["route_summary"]["translated_objective"])
    println("  buckling iteration backend = ", buckling_diagnostics["backend"])
    println("  displacement objective = ", displacement_results["route_summary"]["translated_objective"])
    println("  displacement sensitivity = ", displacement_diagnostics["sensitivity"]["gradient_backend"])
    println("  stress ks objective   = ", stress_ks_results["route_summary"]["translated_objective"])
    println("  stress ks value       = ", stress_ks_results["optimization"]["stress_ks_response"])
    println("  stress ks sensitivity = ", stress_ks_diagnostics["sensitivity"]["gradient_backend"])
    println("  stress ks design gradient = ", stress_ks_design_results["optimization"]["gradients"]["TSTRESS"])
    println("  stress ks design sensitivity = ", stress_ks_design_diagnostics["sensitivity"]["gradient_backend"])
    println("  stress mass objective = ", stress_mass_results["route_summary"]["translated_objective"])
    println("  stress mass final response = ", stress_mass_results["optimization"]["response_value"])
    println("  stress mass route      = ", stress_mass_results["optimization"]["response_family"])
    println("  stress multi mass final response = ", stress_multi_mass_results["optimization"]["response_value"])
    println("  stress multi mass sensitivity = ", stress_multi_mass_diagnostics["sensitivity"]["gradient_backend"])
    println("  pcomp stress ks design gradient = ", pcomp_stress_ks_design_results["optimization"]["gradients"]["TPCST"])
    println("  pcomp stress ks design sensitivity = ", pcomp_stress_ks_design_diagnostics["sensitivity"]["gradient_backend"])
    println("  pcomp stress mass final response = ", pcomp_stress_mass_results["optimization"]["response_value"])
    println("  pcomp stress mass route = ", pcomp_stress_mass_results["optimization"]["response_family"])
    return true
end

exit(main() ? 0 : 1)
