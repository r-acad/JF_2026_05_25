using Test, WingFEGen
const W=WingFEGen

@testset "Coordinate formatting does not quantize physical station inputs" begin
    eta=0.337123456789
    source=W.default_params()
    source["box.end_eta"]=0.987654321
    source["box.front_spar_points"]=[Dict("eta"=>eta,"dxc"=>0.0123456789)]
    source["box.rear_spar_points"]=[Dict("eta"=>eta,"dxc"=>-0.0123456789,"stringer_angle"=>0.)]
    source["ribs.masters"]=[Dict("eta"=>eta,"mode"=>"flight_direction","angle"=>90.,"pitch"=>0.6)]
    source["planform.twist_axis_xc"]=0.337123456789
    source["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>4.),Dict("eta"=>eta,"twist"=>1.),Dict("eta"=>1.,"twist"=>-3.)]
    normalized=first(W.normalize_params(source))
    @test normalized["box.end_eta"]===source["box.end_eta"]
    @test normalized["planform.twist_axis_xc"]===source["planform.twist_axis_xc"]
    @test normalized["box.front_spar_points"][1]["eta"]===eta
    @test normalized["box.rear_spar_points"][1]["eta"]===eta
    @test normalized["ribs.masters"][1]["eta"]===eta
    @test normalized["loft.twist_stations"][2]["eta"]===eta
    @test normalized["box.front_spar_points"][1]["dxc"]===0.0123456789
    aerodynamic=first(W.aerodynamic_geometry(source))
    @test aerodynamic["planform.twist_axis_xc"]===source["planform.twist_axis_xc"]
    @test aerodynamic["loft.twist_stations"][2]["eta"]===eta
    @test source["box.front_spar_points"][1]["eta"]===eta
end
