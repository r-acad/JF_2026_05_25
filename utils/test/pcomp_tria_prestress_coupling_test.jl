using Test

module PcompTriaPrestressCouplingFixture
using Test, LinearAlgebra, OpenJFEM
const S = OpenJFEM.Solver

function fixture(path)
    lines = String["SOL 105", "CEND", "SUBCASE 1", " SPC = 1", " LOAD = 1",
        "SUBCASE 2", " SPC = 1", " METHOD = 2", " STATSUB(BUCKLING) = 1",
        "BEGIN BULK", "PARAM,K6ROT,100.", "PARAM,SNORM,0."]
    for element in 1:3
        firstnode = 3element - 2
        for (j, (x, y)) in enumerate(((0., 0.), (.8, 0.), (.1, .6)))
            push!(lines, "GRID,$(firstnode+j-1),,$(x+2element),$y,0.")
        end
        angle = element == 2 ? 23.0 : 0.0
        push!(lines, "CTRIA3,$element,$element,$firstnode,$(firstnode+1),$(firstnode+2),$angle")
    end
    append!(lines, ["MAT1,1,7.E10,,.3,2700.",
        "MAT8,2,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.",
        "PCOMP,1,.002,,,,,,", "+,1,.004,0.,YES",
        "PCOMP,2,,,,,,,", "+,2,.001,0.,YES,2,.003,70.,YES",
        "PCOMP,3,,,,,,,", "+,1,.004,0.,YES",
        "SPC1,1,123456,1,4,7", "FORCE,1,2,0,1.,0.,0.,1.",
        "EIGRL,2,0.,,2", "ENDDATA"])
    write(path, join(lines, '\n') * "\n")
    OpenJFEM.bdf_to_model(path)
end

function integrated_AB(model, element)
    property = model["PSHELLs"][string(element["PID"])]
    A = zeros(3, 3); B = zeros(3, 3)
    for ply in property["PLY_DATA"]
        material = model["MATs"][string(ply["mid"])]
        angle = deg2rad(ply["theta"] + element["THETA"])
        E1 = get(material, "E1", get(material, "E", 0.0))
        E2 = get(material, "E2", E1)
        nu = get(material, "NU12", get(material, "NU", 0.0))
        G = get(material, "G12", get(material, "G", 0.0))
        Q = OpenJFEM.laminate_plane_stress_qbar(E1, E2, nu, G, angle)
        lower, upper = ply["z_bot"], ply["z_top"]
        A .+= Q * (upper-lower)
        B .+= Q * (upper^2-lower^2) / 2
    end
    A, B
end

function run_checks()
    mktempdir() do directory
        model = fixture(joinpath(directory, "triangle_coupling.bdf"))
        K, idmap, X, ndof, node_R, maxdiag, mapping, normals, diag =
            S.assemble_stiffness(model; membrane_incomp=false,
                snorm_angle_override=0., sol105_context=true)
        cases = ((zeros(3), [.003,0.,0.]), (zeros(3), [0.,-.002,0.]),
            (zeros(3), [0.,0.,.004]), ([.0002,-.0001,.0003], [.003,-.002,.004]))
        for (strain, curvature) in cases
            state = zeros(ndof)
            for (_, i) in idmap
                x, y = X[i, 1], X[i, 2]
                state[6(i-1)+1:6(i-1)+3] = node_R[i]' *
                    [strain[1]*x+strain[3]*y/2, strain[2]*y+strain[3]*x/2, 0.]
                state[6(i-1)+4:6(i-1)+6] = node_R[i]' *
                    [-curvature[2]*y-curvature[3]*x/2, curvature[1]*x+curvature[3]*y/2, 0.]
            end
            captured = Dict{Int,Any}(); guard = ReentrantLock()
            callback = function(eid, values)
                lock(guard) do
                    captured[eid] = (N=copy(values[:N_res]), B=deepcopy(values[:Bmb_override_t3]))
                end
            end
            S.assemble_geometric_stiffness(model, idmap, X, node_R, ndof, state, normals, mapping;
                snorm_angle_override=0., buckling_subcase=2, static_load_id=1, geometric_capture=callback)
            @test length(captured) == 3
            for eid in 1:3
                A, B = integrated_AB(model, model["CSHELLs"][string(eid)])
                expected = A*strain + B*curvature
                @test norm(captured[eid].N-expected) <= 2e-11*max(norm(expected), 1.)
                @test (captured[eid].B === nothing) == (eid == 3)
            end
        end
        # The numerical correction must not silently broaden the supported
        # analytic derivative domain to offset or anisotropic laminates.
        @test_throws ArgumentError S.analytic_shell_constitutive(model, 1)
        @test_throws ArgumentError S.analytic_shell_constitutive(model, 2)
        @test S.analytic_shell_constitutive(model, 3).Bmb == zeros(3, 3)
    end
end
end

@testset "PCOMP triangle prestress includes laminate coupling" begin
    PcompTriaPrestressCouplingFixture.run_checks()
end
