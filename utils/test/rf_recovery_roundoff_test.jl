using Test
module RFRecoveryRoundoffFixture
using Test
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","rf_recovery.jl"))
function checks()
    influence=[1e8,-1e8];state=[1.,1.];actual=0.;predicted=1.49e-8
    bound=rf_affine_roundoff_bound(0.,influence,state)
    @test bound==128eps(Float64)*2e8
    @test abs(actual-predicted)<=rf_affine_replay_tolerance(actual,predicted,0.,influence,state)
    # The view-frame error isolated in the production case was30MPa. A valid
    # roundoff allowance remains many orders of magnitude below that error.
    @test 3e7>rf_affine_replay_tolerance(0.,3e7,0.,influence,state)
    @test rf_affine_roundoff_bound(0.,1e-3influence,state)≈1e-3bound
    @test .37-.37^2>rf_affine_replay_tolerance(.37,.37^2,0.,[1.],[.37])
    @test rf_affine_roundoff_bound(2.,[0.,0.],state)==256eps(Float64)
    native=(;Solver=(;_stress_entry_public_id=(id,el)->parse(Int,string(id))))
    element=Dict("NODES"=>[10,11,12],"PID"=>1)
    op=(;model=Dict{String,Any}("CSHELLs"=>Dict("5"=>element)),id_map=Dict(10=>1,11=>2,12=>3))
    wing=(;groups=[(;eids=[5])])
    index=rf_build_recovery_index(native,op,wing)
    context=(;op,wing,recovery_index=index,recovery_targets=Dict{Int,Any}())
    target=rf_recovery_target(native,context,5)
    @test target.eid==5
    @test target.dofs==collect(1:18)
    @test target.el===element
    @test rf_recovery_target(native,context,5)===target
    @test target.model["CSHELLs"]["5"]===element
    @test isempty(target.model["CBARs"])
    @test_throws ArgumentError rf_recovery_target(native,context,6)
    duplicate=(;model=merge(op.model,Dict("CBARs"=>Dict("5"=>Dict("GA"=>10,"GB"=>11)))),id_map=op.id_map)
    @test_throws ArgumentError rf_build_recovery_index(native,duplicate,wing)
end
end
@testset "RF affine primitive checks account only for summation roundoff" begin
    RFRecoveryRoundoffFixture.checks()
end
