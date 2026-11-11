module SPCADDMissingMemberTests
using Test,OpenJFEM,LinearAlgebra,SparseArrays
const O=OpenJFEM
const S=O.Solver

function fixture(directory;free_body=false)
    path=joinpath(directory,"optional_constraint_members.bdf")
    members=free_body ? "SPC1,10,123456,3\nSPC,20,3,1,0.\n" : "SPC1,10,1,1\nSPC,20,2,2,0.\n"
    write(path,"""
SOL 103
CEND
SPC = 1000
BEGIN BULK
PARAM,AUTOSPC,NO
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,2.,0.,0.,,6
$members
SPC1,1000,123456,1,2
SPCADD,1000,10,3001,20,6001,3001
ENDDATA
""")
    O.bdf_to_model(path)
end

@testset "Undefined SPCADD members warn without changing valid constraints" begin
    mktempdir() do directory
        model=fixture(directory);before=deepcopy(model["SPC1s"])
        selected=@test_logs (:warn,r"SPCADD 1000.*undefined.*ignored") S.selected_spc_sets(model,1000)
        @test selected==Set([10,20])
        @test model["SPC1s"]==before
        # SPCADD takes precedence over the direct SPC1 with the same SID.
        @test !(1000 in selected)
        result=@test_logs (:warn,r"SPCADD 1000.*undefined.*ignored") S.compute_free_dofs(spdiagm(0=>ones(18)),18,model,Dict(i=>i for i in 1:3),1000,Dict(12=>nothing);return_diagnostics=true,allow_factorization_autospc=false)
        free,fixed,diagnostics=result
        @test fixed==Set([1,8,12,18])
        @test free==setdiff(collect(1:18),[1,8,12,18])
        @test diagnostics["explicit_spc_dofs"]==2
        @test diagnostics["permanent_grid_dofs"]==1
        @test diagnostics["mpc_dependent_dofs"]==1
        @test diagnostics["autospc_diagonal_dofs"]==0
        # Constraining a separate dummy GRID must not anchor the free body.
        free_model=fixture(directory;free_body=true)
        result=@test_logs (:warn,r"SPCADD 1000.*undefined.*ignored") S.compute_free_dofs(spdiagm(0=>ones(18)),18,free_model,Dict(i=>i for i in 1:3),1000,Dict{Int,Any}();return_diagnostics=true,allow_factorization_autospc=false)
        @test result[1]==collect(1:12)
        @test result[2]==Set(13:18)
        @test isempty(intersect(result[2],Set(1:12)))
        @test result[3]["autospc_diagonal_dofs"]==0
    end
end

@testset "Top-level, empty, invalid and nested SPC selection stays strict" begin
    model=Dict{String,Any}("SPC1s"=>[Dict("SID"=>10)],"SPCADDs"=>Dict(100=>[10,404],200=>Int[],300=>[100],400=>[400],500=>[0]))
    @test S.selected_spc_sets(model,nothing)==Set{Int}()
    @test S.selected_spc_sets(model,0)==Set{Int}()
    @test S.selected_spc_sets(model,10)==Set([10])
    @test_throws ArgumentError S.selected_spc_sets(model,404)
    @test_throws ArgumentError S.selected_spc_sets(model,200)
    @test_throws ArgumentError S.selected_spc_sets(model,300)
    @test_throws ArgumentError S.selected_spc_sets(model,400)
    @test_throws ArgumentError S.selected_spc_sets(model,500)
    model["SPCADDs"][600]=[404,405]
    selected=@test_logs (:warn,r"SPCADD 600.*undefined.*ignored") S.selected_spc_sets(model,600)
    @test isempty(selected)
    # Dictionary JSON callers can retain string keys for combination IDs.
    model["SPCADDs"]=Dict("100"=>[10,404])
    @test (@test_logs (:warn,r"SPCADD 100.*undefined.*ignored") S.selected_spc_sets(model,100))==Set([10])
end
end
