module Sol105ConstraintSelectionTests
using Test, OpenJFEM, LinearAlgebra, SparseArrays
const O = OpenJFEM
const S = O.Solver

function fixture(directory; global_spc="", static_spc=11, buckling_spc="")
    path=joinpath(directory,"constraints.bdf")
    write(path,"""
SOL 105
CEND
$global_spc
SUBCASE 1
 SPC=$static_spc
 LOAD=1
SUBCASE 2
 STATSUB=1
 METHOD=1
$buckling_spc
BEGIN BULK
PARAM,AUTOSPC,NO
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,2.,0.,0.,,4
SPC1,11,123456,1
SPC1,12,123456,2
SPCADD,13,11,12
EIGRL,1,1.e-6,,1
ENDDATA
""")
    return O.bdf_to_model(path)
end

@testset "SOL105 eigen constraints are independent of the preload" begin
    mktempdir() do directory
        for (global_spc,static_spc,buckling_spc,expected_id,expected_spc_dofs) in (
            ("",11,"",nothing,Int[]),
            ("SPC=11",12,"",11,collect(1:6)),
            ("",11," SPC=12",12,collect(7:12)),
            ("SPC=11",12," SPC=0",0,Int[]),
            ("",11," SPC=13",13,collect(1:12)),
        )
            model=fixture(directory;global_spc,static_spc,buckling_spc)
            control=model["CASE_CONTROL"]
            eigen_subcase=control["SUBCASES"][2]
            selector=O._resolve_sol105_spc(control,eigen_subcase)
            @test selector===expected_id
            # Test the actual boundary partition, including a permanent GRID
            # constraint and an MPC-dependent DOF that must survive omission.
            free,fixed,diagnostics=S.compute_free_dofs(spdiagm(0=>ones(18)),18,
                model,Dict(i=>i for i in 1:3),selector,Dict(18=>nothing);
                return_diagnostics=true,allow_factorization_autospc=false)
            expected_fixed=Set(vcat(expected_spc_dofs,[16,18]))
            @test fixed==expected_fixed
            @test free==setdiff(collect(1:18),sort!(collect(expected_fixed)))
            @test diagnostics["explicit_spc_dofs"]==length(expected_spc_dofs)
            @test diagnostics["permanent_grid_dofs"]==1
            @test diagnostics["mpc_dependent_dofs"]==1
            @test control["SUBCASES"][1]["SPC"]==static_spc
        end
        # Dictionary callers may leave global defaults unexpanded.
        @test O._resolve_sol105_spc(Dict("SPC"=>11),Dict("STATSUB"=>1))==11
        @test O._resolve_sol105_spc(Dict(),Dict("STATSUB"=>1,"SPC"=>nothing))===nothing
    end
end
end
