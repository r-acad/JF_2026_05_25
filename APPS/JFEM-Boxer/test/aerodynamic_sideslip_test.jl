using Test,WingFEGen,LinearAlgebra
const W=WingFEGen
@testset "Positive beta arrives from right and pushes fins left" begin
 p=W.default_params();merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","movable_surfaces.items"=>Any[]))
 p["loft.vertical_shift_stations"]=[Dict("eta"=>e,"shift_percent"=>z) for (e,z) in ((0.,0.),(.8,0.),(1.,45.))]
 # Put the moment reference ahead of the fins so the side-force lever arm
 # has a defined restoring-yaw sign; a quarter-chord winglet need not be stable.
 settings=Dict{String,Any}("chord_panels"=>2,"span_panels"=>3,"control_chord_panels"=>1,"alpha"=>0.,"reference"=>[-2.,0.,0.],"speed"=>30.,"compressibility"=>"incompressible","derivatives"=>false)
 plus=only(W.run_aerodynamic_study(p,merge(settings,Dict("beta"=>5.)))["cases"])
 minus=only(W.run_aerodynamic_study(p,merge(settings,Dict("beta"=>-5.)))["cases"])
 flow=plus["wake_direction"];T=W.aerodynamic_frame_matrices(plus["condition"])["body"]
 @test flow[2]<0 # air travels from right to left, not aircraft velocity
 @test (-T*flow)[2]>0 # aircraft air-relative velocity has positive body v
 @test (-flow)[2]>0 # upstream source is on right (+Y_B)
 @test plus["coefficients"]["body"]["force"][2]<0
 @test plus["coefficients"]["body"]["moment"][3]>0
 @test minus["coefficients"]["body"]["force"][2]>0
 @test minus["coefficients"]["body"]["moment"][3]<0
 @test plus["force_N"][1] ≈ minus["force_N"][1]
 @test plus["force_N"][2] ≈ -minus["force_N"][2]
 @test plus["force_N"][3] ≈ minus["force_N"][3] atol=1e-9
 @test plus["residual_over_V"]<1e-9
 @test T[2,:]==[0.,1.,0.]
end
