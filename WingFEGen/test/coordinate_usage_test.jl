using Test, LinearAlgebra
cross3(a,b)=Tuple(cross(collect(a),collect(b)))
include(joinpath(@__DIR__,"..","src","coordinate_payload.jl"))

@testset "Coordinate purpose follows references, not coincident origins" begin
    frame=Dict{String,Any}("TYPE"=>"RECTANGULAR","Origin"=>[0.,0.,0.],"U"=>[1.,0.,0.],"V"=>[0.,1.,0.],"W"=>[0.,0.,1.],"RID"=>0,"A_raw"=>[0.,0.,0.])
    native=Dict("CORDs"=>Dict("10"=>deepcopy(frame),"20"=>deepcopy(frame)),
        "GRIDs"=>Dict("10"=>Dict("ID"=>10,"CP"=>0,"CD"=>0,"X"=>[0.,0.,0.]),
                     "99"=>Dict("ID"=>99,"CP"=>20,"CD"=>20,"X"=>[2.,3.,4.])),
        "CSHELLs"=>Dict("7"=>Dict("ID"=>7,"MCID"=>10),"8"=>Dict("ID"=>8,"MCID"=>0,"THETA"=>10.)),
        "RBE3s"=>Dict("100"=>Dict("REFGRID"=>10)))
    before=deepcopy(native);data=imported_coordinate_payload(native);frames=Dict(row["id"]=>row for row in data["systems"])
    @test native==before
    @test length(frames)==3
    @test all(row->row["origin"]==[0.,0.,0.],values(frames))
    @test frames[10]["usage"]==Dict("grid_cp"=>0,"grid_cd"=>0,"shell_mcid"=>1,"shell_eids"=>[7])
    @test frames[20]["usage"]["grid_cp"]==frames[20]["usage"]["grid_cd"]==1
    @test frames[0]["usage"]["grid_cp"]==frames[0]["usage"]["grid_cd"]==1
    @test frames[0]["usage"]["shell_mcid"]==0 # THETA is not a CID.
    @test frames[10]["properties"]["Example shell EIDs"]==[7]
    @test occursin("do not attach frames",data["note"])
    @test isempty(data["warnings"])
    @test occursin("Coincident origins are valid",data["note"])

    blob(values)=(bytes=collect(reinterpret(UInt8,values)),)
    group=Dict("kind"=>"quad","eids"=>blob(Int32[71]),"axes"=>Dict("x"=>blob(Float32[0,1,0]),"y"=>blob(Float32[-1,0,0]),"z"=>blob(Float32[0,0,1])))
    generated=generated_coordinate_payload([group];node_count=9);basic,shell=generated["systems"]
    @test shell["id"]==71
    @test shell["origin"]==[0.,0.,0.]
    @test shell["x"]==[0.,1.,0.]
    @test shell["usage"]==Dict("grid_cp"=>0,"grid_cd"=>0,"shell_mcid"=>1,"shell_eids"=>[71])
    @test basic["usage"]["grid_cp"]==basic["usage"]["grid_cd"]==9
end
