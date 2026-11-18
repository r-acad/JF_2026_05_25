module RFPlateUnresolvedTests
using Test,LinearAlgebra,ForwardDiff
const ROOT=normpath(joinpath(@__DIR__,"..",".."))
include(joinpath(ROOT,"APPS","JFEM-Boxer","src","rf_kernels.jl"))
include(joinpath(ROOT,"APPS","JFEM-Boxer","src","rf_native_assessment.jl"))
const D=[22.40910111098642 7.395003366625518 0.;7.395003366625518 22.40910111098642 0.;0. 0. 7.50704887218045]
const N=[-248044.83021862997,-1370.863295787625,-18709.124528141732]
const L=.6357899202170895
const W=.1664719546111051
function fixture(N=N;factor=1.,fixity=1.)
    raw=Dict("key"=>"supported_plate","length_m"=>L,"width_m"=>W,"fixity_coefficient"=>fixity,
        "elements"=>[Dict("eid"=>1,"pid"=>6000033,"area_m2"=>L*W,"thickness_m"=>.0015,
            "stress_transform"=>Matrix{Float64}(I,3,3),"bending_matrix_Nm"=>D)])
    item=Dict("case_id"=>1,"case_key"=>"1:default","result"=>Dict("elementResults"=>Dict("1"=>Dict("forces"=>Dict(zip(("fx","fy","fxy"),-N))))))
    input=Dict("assessmentPolicy"=>Dict("bucklingPolicyFactor"=>factor))
    input,item,raw
end
@testset "Unresolved plate roots retain physical coverage without negative utilization" begin
    input,item,raw=fixture()
    # Actual supported-panel load tensor, with an explicitly small frozen
    # basis: every retained root is negative despite weak oblique compression.
    modes=[(1,1),(1,2),(2,1)]
    pair=rf_plate_pair(L,W,D,N,modes)
    @test pair.mu<0
    @test eigmax(Symmetric([N[1] N[3];N[3] N[2]]))>0
    for derivatives in (true,false)
        row=rf_plate_response(input,item,raw,"skin_buckling";derivatives,frozen_modes=modes)
        @test row["status"]=="unavailable"
        @test !occursin("utilization is not finite",row["reason"])
        @test row["raw_RF"]===nothing&&row["utilization"]===nothing
        @test row["no_demand"]===false
        @test row["membrane_recovery_complete"]===true
        @test length(row["feature_values"])==3
        @test row["lower_bound_RF"]>1.
        @test haskey(row,"_plate_matrices")
    end
    input,item,raw=fixture([-1e4,-2e4,0.])
    row=rf_plate_response(input,item,raw,"skin_buckling")
    @test row["status"]=="ok"&&row["no_demand"]===true
    @test row["utilization"]==0&&row["raw_RF"]===nothing
    @test all(iszero,vcat(row["feature_gradient"],row["capacity_gradient"]))
    for damage in (:missing,:nonfinite,:bad_geometry)
        input,item,raw=fixture()
        damage==:missing&&delete!(item["result"]["elementResults"],"1")
        damage==:nonfinite&&(item["result"]["elementResults"]["1"]["forces"]["fx"]=NaN)
        damage==:bad_geometry&&(raw["length_m"]=0.)
        row=rf_plate_response(input,item,raw,"skin_buckling";frozen_modes=modes)
        @test row["status"]=="unavailable"
        @test !haskey(row,"lower_bound_RF")
        @test !get(row,"membrane_recovery_complete",false)
    end
end
@testset "All-mode plate RF certificate scaling and rigor" begin
    for loads in ([1e4,0.,0.],[0.,1e4,0.],[1e4,-2e4,2e3],[0.,0.,1e4])
        bound=rf_plate_lower_bound(L,W,D,loads)
        pair=rf_solve_plate(L,W,D,loads)
        @test bound>0&&bound<=inv(pair.mu)
        @test rf_plate_lower_bound(L,W,D,2loads)≈bound/2
        @test rf_plate_lower_bound(L,W,D,loads;factor=1.5,fixity=2.)≈bound*2/1.5
        for scale in (1e-100,1e100)
            @test rf_plate_lower_bound(L,W,scale*D,scale*loads)≈bound rtol=1e-12
        end
    end
    @test rf_plate_lower_bound(0.,W,D,N)===nothing
    @test rf_plate_lower_bound(L,W,D,[NaN,0.,0.])===nothing
    @test rf_plate_lower_bound(L,W,[1. .7 .7;.7 1. .7;.7 .7 1.],N)===nothing
end
end
