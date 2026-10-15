using Test, OpenJFEM, LinearAlgebra, SparseArrays

module Sol105RecoveryReuseFixture
using Test, OpenJFEM, LinearAlgebra, SparseArrays
const O = OpenJFEM
const S = O.Solver

function fixture(dir, kind; triangle=false, warp=0.0)
    material = kind == :laminate ? """
MAT8,1,1.0E7,7.0E6,.25,3.0E6,2.0E6,1.3E6,1000.
PCOMP,10
+,1,.03,17.,YES,1,.05,-32.,YES
+ ,1,.02,58.,YES
""" : """
MAT1,1,7.E7,,.3,2700.
PSHELL,10,1,.1,1,1.,1,.833333,, -.035,.065
"""
    material = replace(material, "+ ," => "+,")
    element = triangle ? "CTRIA3,1,10,1,2,3" : "CQUAD4,1,10,1,2,3,4,23."
    path=joinpath(dir,"fixture.bdf")
    write(path,"""
SOL 105
CEND
BEGIN BULK
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,.7,.5,$warp
GRID,4,,-.7,.5,0.
$element
$material
ENDDATA
""")
    model=O.bdf_to_model(path)
    ids=Dict(i=>i for i in 1:4)
    xyz=[-1. -.5 0.;1. -.5 0.;.7 .5 warp;-.7 .5 0.]
    rotations=[Matrix{Float64}(I,3,3) for _ in 1:4]
    normals=S.compute_snorm_normals(model,ids,xyz)
    u=.001sin.(collect(1.:24.))
    state=(id_map=ids,X=xyz,node_R=rotations,snorm_normals=normals,u_static=u,temp_load_id=nothing,
        recovery=(K=spdiagm(0=>ones(24)),force=zeros(24),load_id=nothing,load_scale=1.,spc_dofs=collect(1:6),diagnostics=Dict{String,Any}()))
    results=Dict{String,Any}("model"=>model,"static_states"=>Dict(11=>state),"timings"=>Dict{String,Float64}())
    return results,state
end

function check(results,state)
    model=results["model"]
    expected=O._recover_sol105_static_fields(model,state.id_map,state.X,state.node_R,state.u_static,state.snorm_normals)
    data=O._sol105_static_results!(results,11)
    @test !isempty(data["displacements"])
    @test length(data["forces"]["quad4"])+length(data["forces"]["tria3"])==1
    @test length(data["stresses"]["quad4"])+length(data["stresses"]["tria3"])==1
    @test length(data["strains"]["quad4"])+length(data["strains"]["tria3"])==1
    @test O._sol105_static_results!(results,11) === data
    captured=results["static_shell_fields_by_subcase"][11]
    @test captured == expected
    @test O._sol105_static_fields!(results,11) === captured
    @test !haskey(results["timings"],"sol105_static_field_recovery")
    # Full rows must be unchanged by collecting compact values alongside them.
    _,_,ordinary=S._build_results_from_state(24,model,state.id_map,state.X,state.node_R,
        state.u_static,state.recovery.K*state.u_static,state.snorm_normals,Dict{String,Any}();
        spc_dofs=state.recovery.spc_dofs)
    for key in ("displacements","spc_forces","forces","forces_bilin","stresses","strains")
        @test data[key] == ordinary[key]
    end
    # Opposite writer order preserves already recovered compact values too.
    delete!(results,"static_results_by_subcase")
    delete!(results,"static_shell_fields_by_subcase")
    compact_first=O._sol105_static_fields!(results,11)
    full_after=O._sol105_static_results!(results,11)
    @test O._sol105_static_fields!(results,11) === compact_first
    @test compact_first == expected
    @test full_after["stresses"] == data["stresses"]
end

function checks()
    mktempdir() do dir
        for kind in (:isotropic,:laminate), triangle in (false,true), warp in (0.,.02)
            results,state=fixture(dir,kind;triangle,warp)
            check(results,state)
        end
        results,state=fixture(dir,:isotropic)
        withenv("JFEM_SKIP_STRESS_RECOVERY"=>"true") do
            data=O._sol105_static_results!(results,11)
            @test data["stress_recovery_skipped"]
            @test !haskey(results,"static_shell_fields_by_subcase")
            @test !isempty(O._sol105_static_fields!(results,11))
            @test haskey(results["timings"],"sol105_static_field_recovery")
        end
        # Incomplete full output must not suppress standalone compact recovery.
        results,state=fixture(dir,:isotropic)
        delete!(results["model"]["PSHELLs"],"10")
        data=O._sol105_static_results!(results,11)
        @test isempty(data["stresses"]["quad4"])
        @test !haskey(results,"static_shell_fields_by_subcase")
        @test isempty(O._sol105_static_fields!(results,11))
        @test haskey(results["timings"],"sol105_static_field_recovery")

        # Free thermal expansion has zero mechanical stress. A binary-only
        # writer must activate the selected temperature and its load scale,
        # regardless of an unrelated ambient context left by the caller.
        for compact_first in (true,false)
            results,state=fixture(dir,:isotropic)
            model=results["model"]
            model["MATs"]["1"]["ALPHA"]=1e-5
            model["MATs"]["1"]["TREF"]=20.0
            model["TEMPDs"]=Dict(100=>100.0)
            model["_active_temp_sid"]=123
            model["_active_temp_scale"]=9.0
            expansion=1e-5*(100.0-20.0)*0.5
            u=zeros(24)
            for i in 1:4
                u[6i-5:6i-3].=expansion.*(state.X[i,:].-state.X[1,:])
            end
            state=merge(state,(temp_load_id=100,u_static=u,
                recovery=merge(state.recovery,(load_scale=0.5,))))
            results["static_states"]=Dict{Int,Any}(11=>state)
            if compact_first
                fields=O._sol105_static_fields!(results,11)
                @test only(values(fields)) == (0.0,0.0,0.0)
            end
            data=O._sol105_static_results!(results,11)
            @test only(values(O._sol105_static_fields!(results,11))) == (0.0,0.0,0.0)
            @test only(data["stresses"]["quad4"])["z1"]["von_mises"] == 0.0
            @test model["_active_temp_sid"] == 123
            @test model["_active_temp_scale"] == 9.0
        end
    end
end
end

@testset "SOL105 full and compact preload recovery share fields" begin
    Sol105RecoveryReuseFixture.checks()
end
