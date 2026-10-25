using Test, TOML
using WingFEGen
const W=WingFEGen
function fixture()
    merge(W.default_params(),Dict{String,Any}("planform.area"=>20.,"planform.aspect_ratio"=>5.,
        "planform.taper_ratio"=>.7,"planform.sweep"=>2.,"box.end_eta"=>1.,"box.stringer_pitch"=>.25))
end
function physical_x(p,key,row)
    span=sqrt(p["planform.area"]*p["planform.aspect_ratio"]);s=span/2
    cr=2p["planform.area"]/(span*(1+p["planform.taper_ratio"]))
    return row["eta"]*s*tand(p["planform.sweep"])+(W.point_nominal(p,key)+row["dxc"]-p["planform.sweep_ref_xc"])*cr*(1-(1-p["planform.taper_ratio"])*row["eta"])
end
@testset "Physical segment angle constraints" begin
    for key in ("planform.leading_edge_points","planform.trailing_edge_points","box.front_spar_points","box.rear_spar_points")
        p=fixture();p[key]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.5,"dxc"=>.01,"incoming_angle_deg"=>0.),Dict("eta"=>1.,"dxc"=>.02,"incoming_angle_deg"=>3.)]
        original=deepcopy(p[key]);normalized,unknown=W.normalize_params(p)
        @test isempty(unknown)
        @test normalized[key][end]["dxc"]==original[end]["dxc"]
        for i in 2:3
            a,b=normalized[key][i-1:i];dy=(b["eta"]-a["eta"])*5
            @test atand((physical_x(normalized,key,b)-physical_x(normalized,key,a))/dy)≈b["incoming_angle_deg"] atol=1e-12
        end
        again,_=W.normalize_params(normalized)
        @test all(isapprox(again[key][i]["dxc"],normalized[key][i]["dxc"];atol=1e-14) for i in 1:3)
        parsed,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(normalized))))
        @test parsed[key][end]["incoming_angle_deg"]==3.
        @test parsed[key][2]["incoming_angle_deg"]==0.
        changed=deepcopy(normalized);changed["planform.sweep"]=3.;changed["planform.area"]=22.;changed,_=W.normalize_params(changed)
        a,b=changed[key][1:2];@test physical_x(changed,key,a)≈physical_x(changed,key,b) atol=1e-12
    end
    p=fixture();saved=deepcopy(p);W.apply_point_angle_constraints!(p);@test p==saved
    key="box.front_spar_points";p[key]=[Dict("eta"=>.5,"dxc"=>0.,"incoming_angle_deg"=>0.)];W.apply_point_angle_constraints!(p)
    @test getindex.(p[key],"eta")==[0.,.5,1.]
    @test p[key][2]["dxc"]==0.
    for angle in (-90.,90.,Inf,NaN)
        @test_throws ArgumentError W.normalize_planform_points([Dict("eta"=>.5,"dxc"=>0.,"incoming_angle_deg"=>angle)],key)
    end
    @test_throws ArgumentError W.normalize_planform_points([Dict("eta"=>0.,"dxc"=>0.,"incoming_angle_deg"=>0.)],key)
end
@testset "Selectable stringer reference" begin
    p=fixture();p["box.stringer_angle"]=7.
    legacy=W.stringer_path(p);p["box.stringer_angle_reference"]="rear_spar";@test W.stringer_path(p)==legacy
    p["box.stringer_angle_reference"]="global_y";path=W.stringer_path(p)
    @test path.directions==[7.];@test path.slopes[1]≈tand(7.)
    p["box.stringer_angle_reference"]="front_spar";path=W.stringer_path(p)
    @test path.slopes[1]≈tan(atan(tand(2.)+(.2-.25)*(W.planform_geometry(p).base_chord_tip-W.planform_geometry(p).base_chord_root)/5)+deg2rad(7.))
    p["box.front_spar_points"]=[Dict("eta"=>.6,"dxc"=>-.025)]
    p["box.rear_spar_points"]=[Dict("eta"=>.4,"dxc"=>.02,"stringer_angle"=>4.),Dict("eta"=>.8,"dxc"=>-.01,"stringer_angle"=>-3.)]
    path=W.stringer_path(p);@test .6 in path.etas
    spar=W.spar_geometry(p);w=W.make_wing(p)
    for eta in (.2,.5,.7,.9)
        epsilon=1e-6
        xx(t)=t*5*tand(2.)+(W.spar_xc(w,spar,t,:front)-.25)*W.base_chord(w,t)
        datum=atand((xx(eta+epsilon)-xx(eta-epsilon))/(10epsilon))
        entered=eta<=.4 ? 4. : -3.
        @test atand(W.stringer_slope(path,eta))≈datum+entered atol=1e-8
    end
    for eta in path.kink_etas[2:end-1]
        @test abs(W.stringer_offset(path,eta+1e-8)-W.stringer_offset(path,eta-1e-8))<1e-6
    end
    p["box.stringer_angle_reference"]="global_y";path=W.stringer_path(p)
    @test path.directions==[4.,-3.,-3.]
    normalized,_=W.normalize_params(p);@test normalized["box.stringer_angle_reference"]=="global_y"
    p["box.stringer_angle_reference"]="invalid";@test_throws ArgumentError W.stringer_path(p)
end
@testset "Meshes and saved panel properties with direction controls" begin
    base=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.9,"planform.sweep"=>2.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,"fuel.enabled"=>false,"loads.cases"=>Any[]))
    for reference in ("rear_spar","front_spar","global_y")
        p=deepcopy(base);p["box.stringer_angle_reference"]=reference
        p["box.front_spar_points"]=[Dict("eta"=>.5,"dxc"=>.01)]
        p["box.stringer_angle"]=1.
        model=W.build_model(p)
        @test W.all_checks_pass(model)
        @test model.params["box.stringer_angle_reference"]==reference
    end
    saved=W.build_model(base);layout=W.stiffened_panel_layout(saved.grid);token=W.panel_layout_token(saved.grid,layout)
    p=deepcopy(base);p["properties.panels"]=[Dict("key"=>W.panel_key(first(layout.panels)),"layout_token"=>token,"skin"=>Dict("thickness"=>.004))]
    for key in ("planform.leading_edge_points","planform.trailing_edge_points","box.front_spar_points","box.rear_spar_points")
        p[key]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>1.,"dxc"=>0.)]
    end
    model=W.build_model(p)
    @test W.all_checks_pass(model)
    @test only(model.params["properties.panels"])["skin"]["thickness"]==.004
    @test W.panel_layout_token(model.grid,W.stiffened_panel_layout(model.grid))==token
end
