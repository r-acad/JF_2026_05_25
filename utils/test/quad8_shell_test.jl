# Eight-node shell stiffness (flat parallelograms) and consistent loads of the
# quadratic shells.
#
# The stiffness entries below are element stiffness terms of the reference
# solver for single CQUAD8 elements (E = 7e10, constraint forces of a
# unit displacement with every other degree of freedom fixed).
using Test

module Quad8ShellFixture
using Test, LinearAlgebra, OpenJFEM
const FEMK = OpenJFEM.FEM
const S = OpenJFEM.Solver

corners(a, b, angle) = [0.0 0.0 0.0; a 0.0 0.0; a+b*cosd(angle) b*sind(angle) 0.0; b*cosd(angle) b*sind(angle) 0.0]
function nodes(a, b, angle=90.0)
    c = corners(a, b, angle)
    vcat(c, (c[1:1, :] + c[2:2, :])/2, (c[2:2, :] + c[3:3, :])/2, (c[3:3, :] + c[4:4, :])/2, (c[4:4, :] + c[1:1, :])/2)
end

function stiffness(xyz, t, nu; membrane=true, bending=true, mid3=true)
    E = 7e10
    Q = E/(1 - nu^2) .* [1 nu 0; nu 1 0; 0 0 (1 - nu)/2]
    FEMK.stiffness_quad8_shell(xyz; membrane=membrane ? t .* Q : nothing, bending=bending ? (t^3/12) .* Q : nothing,
        shear=mid3 ? E/(2(1 + nu))*t*5/6 : Inf, bending_reference=E*t^3/(12(1 - nu^2)))
end
entry(K, g1, d1, g2, d2) = K[6(g1 - 1)+d1, 6(g2 - 1)+d2]

# (grid, component, grid, component, value)
const SQUARE_THIN = ((1,1,1,1,1.760932e+08), (1,1,2,1,9.040324e+07), (1,2,5,1,-3.443310e+07), (5,1,5,1,4.540455e+08), (6,2,6,2,4.540455e+08),
    (1,3,1,3,1.253251e+06), (5,3,5,3,4.250664e+06), (1,4,1,4,6.634877e+03), (5,4,5,4,8.362246e+04), (5,5,5,5,9.381577e+04),
    (1,3,5,5,-1.900314e+05), (1,4,3,5,-2.285448e+01), (1,3,3,3,-1.245830e+05))
const SQUARE_THICK = ((1,1,1,1,1.760932e+09), (1,3,1,3,2.598648e+08), (5,3,5,3,5.426027e+08), (1,4,1,4,9.044588e+05), (5,4,5,4,6.578773e+06),
    (5,5,5,5,8.337817e+06), (1,3,5,5,-1.936875e+07), (1,4,3,5,-2.285448e+04), (1,3,3,3,1.259557e+07))
const RECTANGLE_5_1 = ((1,1,1,1,2.457450e+08), (1,1,2,1,8.123854e+07), (5,1,5,1,2.592302e+08), (6,2,6,2,2.101807e+09), (1,3,1,3,3.827198e+06),
    (5,3,5,3,9.533152e+06), (1,4,1,4,2.607194e+03), (5,4,5,4,2.387533e+04), (5,5,5,5,2.428525e+05), (1,3,5,5,-3.158663e+05), (1,3,3,3,6.769717e+05))
const RHOMBUS_60 = ((1,1,1,1,1.350522e+08), (1,1,2,1,8.959888e+07), (1,2,5,1,3.451339e+07), (5,1,5,1,4.442377e+08), (6,2,6,2,5.447713e+08),
    (1,3,1,3,5.944989e+05), (5,3,5,3,5.550362e+06), (1,4,1,4,6.068592e+03), (5,4,5,4,7.765585e+04), (5,5,5,5,8.574910e+04),
    (1,3,5,5,-1.518727e+05), (1,4,3,5,-9.809505e+00), (1,3,3,3,-2.526517e+05))
const SQUARE_NO_MID3 = ((1,3,1,3,1.349044e+06), (5,3,5,3,4.792878e+06), (1,4,1,4,7.428836e+03), (5,4,5,4,9.565907e+04), (5,5,5,5,1.063579e+05),
    (1,3,5,5,-2.126211e+05), (1,3,3,3,-1.696779e+05))

function checks()
    @testset "reference stiffness terms" begin
        for (name, K, table) in (("square thin", stiffness(nodes(0.3, 0.3), 0.003, 0.33), SQUARE_THIN),
            ("square thick", stiffness(nodes(0.3, 0.3), 0.03, 0.33), SQUARE_THICK),
            ("rectangle 5:1", stiffness(nodes(0.5, 0.1), 0.003, 0.33), RECTANGLE_5_1),
            ("rhombus 60", stiffness(nodes(0.3, 0.3, 60.0), 0.003, 0.33), RHOMBUS_60),
            ("square without MID3", stiffness(nodes(0.3, 0.3), 0.003, 0.33; mid3=false), SQUARE_NO_MID3))
            for (g1, d1, g2, d2, value) in table
                @test entry(K, g1, d1, g2, d2) ≈ value rtol=2e-6
            end
        end
    end
    @testset "structure" begin
        xyz = nodes(0.4, 0.25, 70.0)
        K = stiffness(xyz, 0.004, 0.3)
        @test K == K'
        # six rigid-body motions carry no force; rotation about the normal has no stiffness of its own
        rigid = zeros(48, 6)
        for k in 1:8, c in 1:3
            rigid[6(k - 1)+c, c] = 1
            rigid[6(k - 1)+3+c, 3+c] = 1
        end
        for k in 1:8
            x, y, z = xyz[k, :]
            rigid[6(k - 1)+1:6(k - 1)+3, 4] = [0, -z, y]; rigid[6(k - 1)+1:6(k - 1)+3, 5] = [z, 0, -x]; rigid[6(k - 1)+1:6(k - 1)+3, 6] = [-y, x, 0]
        end
        @test norm(K*rigid) <= 1e-9*norm(K)
        drill = [6(k - 1)+6 for k in 1:8]
        @test all(iszero, K[drill, :])
        values = eigvals(Symmetric(K))
        @test count(v -> abs(v) < 1e-9*maximum(values), values) == 6 + 8
        @test minimum(values) > -1e-9*maximum(values)
        # constant membrane strain and constant curvature states are reproduced
        nu = 0.3; t = 0.004; E = 7e10
        u = zeros(48)
        for k in 1:8; u[6(k - 1)+1] = 1e-3*xyz[k, 1]; u[6(k - 1)+2] = -nu*1e-3*xyz[k, 2]; end
        area = 0.4*0.25*sind(70.0)
        @test u'*K*u ≈ E*t*1e-6*area rtol=1e-10
        w = zeros(48)                       # w = x^2/2, cylindrical bending with zero shear strain
        for k in 1:8
            x, y = xyz[k, 1], xyz[k, 2]
            w[6(k - 1)+3] = x^2/2; w[6(k - 1)+5] = -x
        end
        @test w'*K*w ≈ E*t^3/(12(1 - nu^2))*area rtol=1e-10
        # a rigid rotation of the element in space leaves the energies unchanged
        R = [cosd(35) -sind(35) 0; sind(35) cosd(35) 0; 0 0 1]*[1 0 0; 0 cosd(50) -sind(50); 0 sind(50) cosd(50)]
        Kr = stiffness(xyz*R', 0.004, 0.3)
        T = kron(Matrix(I, 16, 16), R)
        @test norm(Kr - T*K*T') <= 1e-10*norm(K)
        @test FEMK.quad8_shell_parallelogram(xyz)
        moved = copy(xyz); moved[5, 1] += 0.01
        @test !FEMK.quad8_shell_parallelogram(moved)
        @test_throws ArgumentError stiffness(moved, 0.004, 0.3)
        trapezoid = nodes(0.4, 0.25); trapezoid[3, 1] -= 0.05; trapezoid[6, 1] -= 0.025; trapezoid[7, 1] -= 0.025
        @test !FEMK.quad8_shell_parallelogram(trapezoid)
        warped = copy(xyz); warped[3, 3] += 0.01
        @test !FEMK.quad8_shell_parallelogram(warped)
    end
    @testset "assembly and loads" begin
        mktempdir() do dir
            deck = joinpath(dir, "quad8.bdf")
            open(deck, "w") do io
                println(io, "SOL 101\nCEND\nSUBCASE 1\n LOAD = 1\nSUBCASE 2\n LOAD = 2\nSUBCASE 3\n LOAD = 3\nBEGIN BULK\nPARAM,COUPMASS,1")
                println(io, "MAT1,1,7.E10,,.33,2700.,2.3-5,20.\nPSHELL,1,1,.003,1,,1")
                println(io, "TEMPD,5,120.\nTEMPD,6,20.\nTEMPP1,6,1,20.,1000.\nTEMPP1,6,2,20.,1000.")
                for (i, p) in enumerate(eachrow(nodes(0.3, 0.4)))
                    println(io, "GRID,$i,,", join(p, ','))
                end
                for (i, p) in enumerate(eachrow([0.6 0.0 0.0; 1.0 0.0 0.0; 0.6 0.3 0.0; 0.8 0.0 0.0; 0.8 0.15 0.0; 0.6 0.15 0.0]))
                    println(io, "GRID,$(10+i),,", join(p, ','))
                end
                println(io, "CQUAD8,1,1,1,2,3,4,5,6\n,7,8")
                println(io, "CTRIA6,2,1,11,12,13,14,15,16")
                println(io, "PLOAD4,1,1,1000.\nPLOAD4,1,2,1000.")
                println(io, "GRAV,2,,9.81,0.,0.,-1.")
                println(io, "PLOAD4,3,1,1000.,2000.,3000.,4000.\nPLOAD4,3,2,1000.,2000.,3000.")
                println(io, "ENDDATA")
            end
            model = OpenJFEM.bdf_to_model(deck)
            captured = Dict{Int,Any}()
            assembled = S.assemble_stiffness(model; element_capture=(eid, pid, dofs, K) -> (captured[eid] = (copy(dofs), copy(K))))
            ids = assembled[2]; X = assembled[3]; ndof = assembled[4]
            dofs, K = captured[1]
            @test size(K) == (48, 48)
            @test K ≈ stiffness(nodes(0.3, 0.4), 0.003, 0.33) rtol=1e-12
            load(sid) = begin
                F = zeros(ndof)
                S.resolve_loads(model, sid, 1.0, ids, Dict(), X, F)
                F
            end
            fz(F, grid) = F[6(ids[grid] - 1)+3]
            F = load(1)
            # uniform pressure: -pA/12 at the corners and pA/3 at the midsides of the quadrilateral,
            # nothing at the corners and pA/3 at the midsides of the triangle
            for g in 1:4; @test fz(F, g) ≈ -1000*0.12/12 rtol=1e-12; end
            for g in 5:8; @test fz(F, g) ≈ 1000*0.12/3 rtol=1e-12; end
            for g in 11:13; @test abs(fz(F, g)) <= 1e-12; end
            for g in 14:16; @test fz(F, g) ≈ 1000*0.06/3 rtol=1e-12; end
            F = load(2)
            weight = 2700*0.003*9.81
            for g in 1:4; @test fz(F, g) ≈ weight*0.12/12 rtol=1e-12; end
            for g in 5:8; @test fz(F, g) ≈ -weight*0.12/3 rtol=1e-12; end
            @test sum(fz(F, g) for g in 1:8) ≈ -weight*0.12 rtol=1e-12
            @test sum(fz(F, g) for g in 11:16) ≈ -weight*0.06 rtol=1e-12
            F = load(3)
            @test sum(fz(F, g) for g in 1:8) ≈ 2500*0.12 rtol=1e-12
            @test sum(fz(F, g) for g in 11:16) ≈ 2000*0.06 rtol=1e-12
            # temperature: the thermal membrane force and bending moment act on the outline,
            # one sixth of a side at each of its corners and two thirds at its midside node
            thermal(sid) = begin
                F = zeros(ndof)
                S.resolve_thermal_loads(model, sid, 1.0, ids, Dict(), X, F)
                F
            end
            component(F, grid, c) = F[6(ids[grid] - 1)+c]
            F = thermal(5)
            force = 7e10*0.003*2.3e-5*100/(1 - 0.33)
            @test component(F, 5, 2) ≈ -force*0.3*2/3 rtol=1e-12
            @test abs(component(F, 5, 1)) <= 1e-9*force
            @test component(F, 1, 1) ≈ -force*0.4/6 rtol=1e-12
            @test component(F, 1, 2) ≈ -force*0.3/6 rtol=1e-12
            @test component(F, 14, 2) ≈ -force*0.4*2/3 rtol=1e-12
            @test all(abs(sum(component(F, g, c) for g in 1:8)) <= 1e-9*force for c in 1:3)
            @test all(abs(component(F, g, c)) <= 1e-12 for g in 1:8 for c in 4:6)
            F = thermal(6)
            moment = 7e10*0.003^3/12*2.3e-5*1000/(1 - 0.33)
            @test component(F, 5, 4) ≈ moment*0.3*2/3 rtol=1e-12
            @test component(F, 8, 5) ≈ -moment*0.4*2/3 rtol=1e-12
            @test component(F, 14, 4) ≈ moment*0.4*2/3 rtol=1e-12
            @test all(abs(component(F, g, c)) <= 1e-9*moment for g in 1:8 for c in 1:3)
        end
    end
end
end

@testset "eight-node shell" begin
    Quad8ShellFixture.checks()
end
