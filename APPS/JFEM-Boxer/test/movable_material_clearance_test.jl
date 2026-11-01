using Test,TOML,WingFEGen,LinearAlgebra
const MC=WingFEGen

function material_fixture()
    p=merge(MC.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[]))
    p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.1,"eta_end"=>.9,
        "hinge_start"=>.72,"hinge_end"=>.75,"front_spar_start"=>.65,"front_spar_end"=>.7,"hinge_z_start"=>-.2,"hinge_z_end"=>-.1,"deflection"=>15.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(MC.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap","span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1,"mesh_deflected"=>true))]
    p["movable_structure.attachments"]=[merge(MC.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap","eta"=>eta)) for eta in (.25,.75)]
    first(MC.normalize_params(p))
end

@testset "Material end clearances preserve authored anchors and geometry" begin
    p=material_fixture();s=only(p["movable_surfaces.items"]);w=MC.make_wing(p)
    @test s["clearance_inboard_m"]==s["clearance_outboard_m"]==0.
    hinges=MC.movable_hinge_endpoints(w,s);original=deepcopy(s)
    s["clearance_inboard_m"]=.02;s["clearance_outboard_m"]=.03
    a,b=MC.movable_material_interval(w,s)
    @test [a,b]≈[.12,.87]
    @test MC.movable_hinge_endpoints(w,s)==hinges
    @test MC.movable_chord_coordinate(s,"front_spar",a)==MC.movable_chord_coordinate(original,"front_spar",a)
    preview=only(MC.movable_surfaces_preview(p)["surfaces"])
    @test preview["hinge"]==collect(hinges)
    @test preview["material_eta_start"]==a&&preview["material_eta_end"]==b
    expected=MC.movable_kinematics(w,original).transform(MC.upper_point(w,a,MC.movable_chord_coordinate(original,"front_spar",a)))
    @test preview["xyz"][1:3]≈collect(expected)
    restored=first(MC.normalize_params(MC.flatten_toml(TOML.parse(MC.params_to_toml(p)))))
    @test restored["movable_surfaces.items"]==p["movable_surfaces.items"]
    for value in (-.1,NaN,Inf,true)
        bad=merge(s,Dict("clearance_outboard_m"=>value))
        @test_throws ArgumentError MC.normalize_movable_surfaces([bad])
    end
    @test_throws ArgumentError MC.movable_material_interval(w,merge(s,Dict("clearance_outboard_m"=>1.)))
end

@testset "Detached aerodynamic material trims do not split the fixed wing" begin
    p=material_fixture();_,w,rows=MC.aerodynamic_geometry(p)
    settings=MC.aerodynamic_settings(Dict("chord_panels"=>4,"span_panels"=>4,"control_chord_panels"=>1,"derivatives"=>false),rows)
    base=MC.aerodynamic_mesh(w,rows,settings)
    row=only(rows);row["clearance_inboard_m"]=.02;row["clearance_outboard_m"]=.03
    a,b=MC.movable_material_interval(w,row);trimmed=MC.aerodynamic_mesh(w,rows,settings)
    @test length(trimmed)==length(base)
    for (old,new) in zip(base,trimmed)
        if old.element_name=="fixed wing"
            @test old.grid==new.grid
        else
            @test extrema(new.etas)==(a,b)
            @test size(new.chord_coordinates)==size(new.grid)[2:3]
        end
    end
    @test all(a.grid==b.grid for (a,b) in zip(trimmed,MC.aerodynamic_recontrol(w,trimmed,settings)))
    @test row["eta_start"]==.1&&row["eta_end"]==.9
end

@testset "Sealed controls retain real end holes without internal chord wakes" begin
    p=material_fixture();p["airfoil.root"]=p["airfoil.tip"]="NACA0012"
    row=only(p["movable_surfaces.items"]);row["front_spar_start"]=row["front_spar_end"]=row["hinge_start"]=row["hinge_end"]=.7
    row["hinge_z_start"]=row["hinge_z_end"]=row["deflection"]=0.
    row["clearance_inboard_m"]=.02;row["clearance_outboard_m"]=.03
    _,w,rows=MC.aerodynamic_geometry(p);@test !MC.aerodynamic_control_gap(w,only(rows))
    s=MC.aerodynamic_settings(Dict("chord_panels"=>4,"span_panels"=>4,"derivatives"=>false),rows)
    patches=MC.aerodynamic_mesh(w,rows,s)
    for patch in patches
        e=sum(extrema(patch.etas))/2
        if .1<e<.12||.87<e<.9
            @test all(patch.chord_coordinates[end,:].≈.7)
        elseif .12<e<.87
            @test all(patch.chord_coordinates[1,:].==0.)&&all(patch.chord_coordinates[end,:].==1.)
            @test length(patch.zone_range)==2
        end
    end
    @test all(a.grid==b.grid for (a,b) in zip(patches,MC.aerodynamic_recontrol(w,patches,s)))
end

@testset "Control FE material trims keep existing hinge attachments" begin
    p=material_fixture();base=MC.build_model(p);hinges=MC.movable_structure_data(base)["attachments"]
    row=only(p["movable_surfaces.items"]);row["clearance_inboard_m"]=.02;row["clearance_outboard_m"]=.03
    m=MC.build_model(p);data=MC.movable_structure_data(m);surface=only(data["surfaces"])
    @test [surface["structural_eta_start"],surface["structural_eta_end"]]≈[.12,.87]
    @test surface["cutout_eta_start"]==.1&&surface["cutout_eta_end"]==.9
    @test all(.12-1e-12<=data["node_etas"][n]<=.87+1e-12 for n in surface["nodes"])
    @test [a["origin"] for a in data["attachments"]]==[a["origin"] for a in hinges]
    @test [a["rib"] for a in data["attachments"]]==[a["rib"] for a in hinges]
    # A clearance never silently moves an attachment to the next main rib.
    row["clearance_inboard_m"]=.2
    @test_throws ArgumentError MC.build_model(p)
end
