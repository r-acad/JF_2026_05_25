module Sol105MPCSelectionTests
using Test, OpenJFEM, LinearAlgebra
const O = OpenJFEM

function fixture(directory; common_mpc=false)
    control = common_mpc ? "MPC=100" : ""
    second_static = common_mpc ? "" : """
SUBCASE 12
 SPC=10
 LOAD=11
 MPC=300
"""
    second_preload_eigen = common_mpc ? "" : """
SUBCASE 201
 SPC=20
 MPC=100
 STATSUB=12
 METHOD=1
"""
    second_mpc = common_mpc ? 100 : 200
    path = joinpath(directory, "mpc_selections.bdf")
    write(path, """
SOL 105
CEND
$control
SUBCASE 11
 SPC=10
 LOAD=11
$second_static
SUBCASE 101
 SPC=20
 MPC=100
 STATSUB=11
 METHOD=1
SUBCASE 102
 SPC=20
 MPC=$second_mpc
 STATSUB=11
 METHOD=1
SUBCASE 103
 SPC=20
 MPC=100
 STATSUB=11
 METHOD=1
$second_preload_eigen
BEGIN BULK
PARAM,AUTOSPC,NO
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,2.,0.
GRID,4,,1.,2.,0.
GRID,5,,0.,4.,0.
MAT1,1,1.E7,,.3
PROD,1,1,.01
CROD,1,1,1,2
CROD,2,1,3,4
CELAS2,11,1000.,2,2
CELAS2,12,4000.,4,2
SPC1,10,123456,1,3,5
SPC1,10,23456,2,4
SPC1,20,123456,1,3
SPC1,20,13456,2,4,5
FORCE,11,2,0,100.,-1.,0.,0.
FORCE,11,4,0,200.,-1.,0.,0.
MPC,100,2,2,1.,5,2,-1.
MPC,100,4,2,1.,5,2,-1.
MPC,200,2,2,1.,5,2,-1.
MPC,200,4,2,1.,5,2,-2.
MPC,300,4,1,1.,2,1,-1.
EIGRL,1,-1.E6,1.E6,1
ENDDATA
""")
    return O.bdf_to_model(path)
end

@testset "SOL105 preload and perturbation use their own MPC selections" begin
    mktempdir() do directory
        model = fixture(directory)
        @test_throws ArgumentError O._model_with_selected_mpc(model)
        result = O.solve_model(model)
        cases = Dict(s.buckling_subcase_id=>s for s in result["buckling"].subcases)
        # Independent closed-form work: the rods supply -P/L geometric work;
        # grounded springs supply elastic work. q is GRID5/T2, and the second
        # tip follows c*q, so lambda=(1000+4000*c^2)/(100+200*c^2).
        for (sid, c) in ((101,1.), (102,2.), (103,1.))
            s = cases[sid]
            expected = (1000 + 4000*c^2)/(100 + 200*c^2)
            @test only(s.reported_eigenvalues) ≈ expected rtol=1e-12
            @test s.K_eig[26,26] ≈ 1000 + 4000*c^2 rtol=1e-12
            @test s.Kg[26,26] ≈ -(100 + 200*c^2) rtol=1e-12
            v = s.reported_mode_shapes[:,1]
            @test v[8] ≈ v[26] rtol=1e-12
            @test v[20] ≈ c*v[26] rtol=1e-12
        end
        # MPC300 belongs only to the second preload: equal shortening shares
        # the 300 N total load equally, without changing perturbation MPC100.
        @test only(cases[201].reported_eigenvalues) ≈ 5000/300 rtol=1e-12
        @test result["static_states"][11].u_static[7] ≈ -0.001 rtol=1e-12
        @test result["static_states"][11].u_static[19] ≈ -0.002 rtol=1e-12
        @test result["static_states"][12].u_static[7] ≈ -0.0015 rtol=1e-12
        @test result["static_states"][12].u_static[19] ≈ -0.0015 rtol=1e-12
        @test result["static_states"][11].model["_active_mpc_id"] === nothing
        @test result["static_states"][12].model["_active_mpc_id"] == 300
        @test result["cache_diagnostics"]["kg_cache_misses"] == 3
        @test result["cache_diagnostics"]["kg_cache_hits"] == 1
        @test result["cache_diagnostics"]["static_cache_misses"] == 2
        @test result["cache_diagnostics"]["static_cache_hits"] == 2
        @test !haskey(model, "_active_mpc_id")
        for sid in (11,12)
            recovered = O._sol105_static_results!(result,sid)
            @test recovered["static_subcase_id"] == sid
            @test !isempty(recovered["displacements"])
        end
        @test_throws ArgumentError O.solve_model(O.TACSFormulationBackend(),model)
        @test_throws ArgumentError O.Solver.solve_adjoint_buckling(result,"nonexistent_split_mpc_config.json")

        # Shared MPC selection keeps the existing assembly/cache route.
        common = O.solve_model(fixture(directory;common_mpc=true))
        @test all(s->only(s.reported_eigenvalues) ≈ 5000/300,common["buckling"].subcases)
        @test common["cache_diagnostics"]["kg_cache_misses"] == 1
        @test common["cache_diagnostics"]["kg_cache_hits"] == 2
        @test common["K"] === common["K_eig"]
    end
end
end
