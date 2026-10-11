using Test, LinearAlgebra, OpenJFEM
include(joinpath(@__DIR__,"..","src","coordinate_payload.jl"))
@testset "Imported CELAS axis glyphs match native displacement coordinates" begin
    a=.37;c=cos(a);s=sin(a)
    frames=Dict(string(i)=>Dict("TYPE"=>type,"Origin"=>[2.,-3.,1.],"U"=>[c,s,0.],"V"=>[-s,c,0.],"W"=>[0.,0.,1.]) for (i,type) in enumerate(("RECTANGULAR","CYLINDRICAL","SPHERICAL")))
    native=Dict("CORDs"=>frames,"GRIDs"=>Dict("10"=>Dict("CD"=>2,"X"=>[4.,2.,5.]),"20"=>Dict("CD"=>3,"X"=>[-3.,4.,1.])))
    for cid in 0:3,point in ([4.,2.,5.],[-3.,4.,1.],[2.,-3.,1.]),component in 1:6
        grid=Dict("CD"=>cid,"X"=>point);basis=OpenJFEM.Solver.get_coord_transform(native,cid,Matrix{Float64}(I,3,3);position=point)
        @test imported_grid_component_axis(native,grid,component)≈basis[:,mod1(component,3)]
    end
    endpoints=imported_spring_endpoints(native,Dict("G1"=>10,"C1"=>5,"G2"=>0,"C2"=>0),Dict(10=>1,20=>2))
    @test endpoints[1]["node"]==0
    @test endpoints[1]["component"]==5
    @test endpoints[1]["coordinate_id"]==2
    @test endpoints[2]["grounded"]
    @test endpoints[2]["axis"]===nothing
    @test endpoints[2]["node"]==-1
    scalar=imported_spring_endpoints(native,Dict("G1"=>10,"C1"=>0,"G2"=>20,"C2"=>3),Dict(10=>1,20=>2))
    @test scalar[1]["axis"]===nothing
    @test occursin("Scalar",scalar[1]["warning"])
    @test scalar[2]["axis"]≈imported_grid_component_axis(native,native["GRIDs"]["20"],3)
    native["GRIDs"]["10"]["CD"]=999
    bad=imported_spring_endpoints(native,Dict("G1"=>10,"C1"=>1),Dict(10=>1))
    @test bad[1]["axis"]===nothing
    @test occursin("Undefined",bad[1]["warning"])
end
