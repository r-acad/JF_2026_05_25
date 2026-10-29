using Test,WingFEGen,LinearAlgebra
const W=WingFEGen
function kinematic_fixture()
 p=W.default_params();merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,"planform.sweep"=>4.,"planform.dihedral"=>2.,"planform.twist_tip"=>-3.,"airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","movable_surfaces.items"=>Any[]))
 p
end
@testset "True cosine chord coordinates and stated quality policy" begin
 p=kinematic_fixture();p["planform.sweep"]=0.;p["planform.dihedral"]=0.;p["planform.twist_tip"]=0.;p["airfoil.root"]="NACA0012";p["airfoil.tip"]="NACA0012"
 _,w,controls=W.aerodynamic_geometry(p);s=W.aerodynamic_settings(Dict{String,Any}("chord_panels"=>6,"span_panels"=>4,"derivatives"=>false),controls);patches=W.aerodynamic_mesh(w,controls,s)
 for patch in patches
  @test patch.xis ≈ [(1-cospi(k/6))/2 for k in 0:6]
  @test maximum(last(W.aerodynamic_aspect(m)) for m in patch.metrics)<=1.5+1e-8
 end
 c=W.aerodynamic_mesh_payload(patches,w,s);@test c["min_panel_aspect_ratio"]<.7
 @test occursin("True cosine",c["aspect_policy"])
end
@testset "Authored general hinge motion and discontinuous control boundaries" begin
 p=kinematic_fixture();p["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),Dict("eta"=>.5,"shift_percent"=>3.),Dict("eta"=>1.,"shift_percent"=>10.)]
 p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"General flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.25,"eta_end"=>.75,"hinge_start"=>.69,"hinge_end"=>.72,"front_spar_start"=>.57,"front_spar_end"=>.61,"hinge_z_start"=>.42,"hinge_z_end"=>-.2,"deflection"=>18.,"color"=>"#ffcc00")]
 _,w,rows=W.aerodynamic_geometry(p);row=only(rows)
 endpoint(side)=begin e=row["eta_"*side];xc=row["hinge_"*side];lo=collect(W.lower_point(w,e,xc));up=collect(W.upper_point(w,e,xc));lo+(.5+row["hinge_z_"*side])*(up-lo);end
 h0,h1=endpoint("start"),endpoint("end");axis=normalize(h1-h0);x,y,z=axis;K=[0. -z y;z 0. -x;-y x 0.];R=I*cosd(18.)+sind(18.)*K+(1-cosd(18.))*(axis*axis')
 expected(point)=h0+R*(collect(point)-h0)
 s=W.aerodynamic_settings(Dict{String,Any}("chord_panels"=>3,"span_panels"=>4,"control_chord_panels"=>1,"derivatives"=>false,"speed"=>30.),rows)
 @test s["controls"][row["name"]]["source"]=="geometry"
 @test s["controls"][row["name"]]["right"]==18.
 @test W.aerodynamic_control_gap(w,row)
 patches=W.aerodynamic_mesh(w,rows,s);moving=0;fixed=0
 for patch in patches
  isempty(patch.active)&&continue
  for (j,e) in enumerate(patch.etas)
   mirror(v)=patch.side=="left" ? [v[1],2w.root_ref_y-v[2],v[3]] : collect(v)
   if first(patch.zone_range)==2
    moving+=1;@test patch.grid[:,end,j] ≈ mirror(expected(W.camber_point(w,e,1.)))
   else
    fixed+=1;cut=W.movable_chord_coordinate(row,"front_spar",e)
    @test patch.grid[:,end,j] ≈ mirror(W.camber_point(w,e,cut))
   end
  end
 end
 @test moving>0&&fixed>0
 preview=only(W.movable_surfaces_preview(p)["surfaces"]);xyz=reshape(preview["xyz"],3,:)
 @test (xyz[:,9]+xyz[:,10])/2 ≈ expected(W.camber_point(w,row["eta_start"],1.))
 result=only(W.run_aerodynamic_study(p,s)["cases"])
 @test all(isfinite,result["force_N"])
 @test result["residual_over_V"]<1e-8
 # A geometry-sourced derivative perturbs the common authored rotation while
 # retaining exactly the same split topology and fixed-skin coordinates.
 changed=deepcopy(s);changed["controls"][row["name"]]["right"]=changed["controls"][row["name"]]["left"]=18.01
 moved=W.aerodynamic_recontrol(w,patches,changed)
 for (base,new) in zip(patches,moved)
  if !isempty(base.active)&&first(base.zone_range)==1;@test base.grid==new.grid;end
 end
end

@testset "Control sheets receive modest extra chordwise resolution" begin
 p=kinematic_fixture();p["planform.sweep"]=0.;p["planform.dihedral"]=0.;p["planform.twist_tip"]=0.
 p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Refined flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.2,"eta_end"=>.8,"hinge_start"=>.7,"hinge_end"=>.7,"front_spar_start"=>.7,"front_spar_end"=>.7,"deflection"=>0.,"color"=>"#ffcc00")]
 _,w,rows=W.aerodynamic_geometry(p)
 s=W.aerodynamic_settings(Dict{String,Any}("chord_panels"=>3,"span_panels"=>4,"control_chord_panels"=>3,"derivatives"=>false),rows)
 patches=W.aerodynamic_mesh(w,rows,s);controlled=filter(p->!isempty(p.active)&&last(p.zone_range)==2,patches)
 @test !isempty(controlled)
 for patch in controlled
  # Integer xi=1 is the hinge; the last zone is the moving trailing surface.
  @test count(x->x>=1-1e-10,patch.xis)-1>=4
  @test maximum(last(W.aerodynamic_aspect(m)) for m in patch.metrics)<=1.5+1e-8
 end
end
