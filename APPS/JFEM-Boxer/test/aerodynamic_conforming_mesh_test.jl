using Test, WingFEGen, LinearAlgebra
const CM=WingFEGen

function conforming_fixture()
    p=CM.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","movable_surfaces.items"=>Any[]))
    p
end
function conforming_control(name,a,b,x,y=x;edge="trailing")
    Dict{String,Any}("name"=>name,"kind"=>"flap","edge"=>edge,"eta_start"=>a,"eta_end"=>b,
        "front_spar_start"=>x,"front_spar_end"=>y,"hinge_start"=>x,"hinge_end"=>y,
        "hinge_z_start"=>.2,"hinge_z_end"=>.2,"deflection"=>10.,"color"=>"#ffcc00")
end
function conforming_model(rows)
    p=conforming_fixture();p["movable_surfaces.items"]=rows
    _,w,controls=CM.aerodynamic_geometry(p)
    s=CM.aerodynamic_settings(Dict{String,Any}("chord_panels"=>4,"span_panels"=>4,"control_chord_panels"=>1,"derivatives"=>false),controls)
    w,controls,s,CM.aerodynamic_mesh(w,controls,s)
end
function check_shared_edges(patches)
    fixed=filter(p->p.element_name=="fixed wing",patches);checked=0
    for i in eachindex(fixed),j in i+1:length(fixed)
        a,b=fixed[i],fixed[j];a.side==b.side||continue
        for ja in (1,length(a.etas)),jb in (1,length(b.etas))
            abs(a.etas[ja]-b.etas[jb])<1e-12||continue
            xa=a.chord_coordinates[:,ja];xb=b.chord_coordinates[:,jb]
            lo=max(first(xa),first(xb));hi=min(last(xa),last(xb));hi>lo+1e-12||continue
            ia=findall(x->lo-1e-12<=x<=hi+1e-12,xa);ib=findall(x->lo-1e-12<=x<=hi+1e-12,xb)
            @test length(ia)==length(ib)
            @test xa[ia]≈xb[ib] atol=1e-13
            @test a.grid[:,ia,ja]≈b.grid[:,ib,jb] atol=1e-12
            checked+=1
        end
    end
    checked
end

@testset "Conforming lanes bridge inactive gaps and retain material coordinates" begin
    w,controls,s,patches=conforming_model([conforming_control("inner",.1,.38,.77,.79),
        conforming_control("middle",.4,.694,.75,.72),conforming_control("outer",.72,1.,.73,.69)])
    @test check_shared_edges(patches)==10
    @test all(maximum(last(CM.aerodynamic_aspect(m)) for m in p.metrics)<=1.5+1e-8 for p in patches)
    @test all(size(p.chord_coordinates)==size(p.grid)[2:3] for p in patches)
    @test all(first(p.chord_coordinates[:,1])==0. && last(p.chord_coordinates[:,1])==1. for p in patches if isempty(p.active))
    @test length(patches)==18 # virtual chord zones do not create extra sheets/wakes
    @test all(a.grid==b.grid for (a,b) in zip(patches,CM.aerodynamic_recontrol(w,patches,s)))
    changed=deepcopy(s)
    changed["controls"]["middle"]["right"]+=.01;changed["controls"]["middle"]["left"]+=.01
    moved=CM.aerodynamic_recontrol(w,patches,changed)
    @test all(a.grid==b.grid for (a,b) in zip(patches,moved) if a.element_name=="fixed wing")
    @test any(a.grid!=b.grid for (a,b) in zip(patches,moved) if a.element_name=="control: middle")
    payload=CM.aerodynamic_mesh_payload(patches,w,s)
    for p in payload["panels"]
        patch=patches[p["patch"]];i=p["chord"];j=p["strip"]
        @test p["chord_fraction"]≈sum(patch.chord_coordinates[i:i+1,j:j+1])/4
    end
end

@testset "Touching variable cuts use finite ordered lanes" begin
    w,controls,s,patches=conforming_model([conforming_control("first",.1,.5,.5,.8),conforming_control("second",.5,.9,.6,.7)])
    @test check_shared_edges(patches)==6
    @test all(a.grid==b.grid for (a,b) in zip(patches,CM.aerodynamic_recontrol(w,patches,s)))
    # Coincident touching cuts reuse one lane even when their slopes differ.
    _,_,_,equal=conforming_model([conforming_control("first",.1,.5,.6,.7),conforming_control("second",.5,.9,.7,.8)])
    @test check_shared_edges(equal)==6
end

@testset "Virtual crossings preserve valid leading/trailing definitions" begin
    rows=[conforming_control("slat",.1,.3,.8,.7;edge="leading"),conforming_control("flap",.6,.9,.3,.4)]
    w,controls,s,patches=conforming_model(rows)
    @test check_shared_edges(patches)==8
    for p in patches,(j,e) in enumerate(p.etas)
        @test all(diff(p.chord_coordinates[:,j]).>0)
    end
    # Simultaneous, nonoverlapping leading/trailing controls retain both cuts.
    _,_,_,overlap=conforming_model([conforming_control("slat",.1,.7,.2,.3;edge="leading"),conforming_control("flap",.3,.9,.8,.6)])
    @test check_shared_edges(overlap)>0
    # Disjoint fixed regions across a touching station do not force an
    # impossible ordering between unrelated leading/trailing virtual lanes.
    _,_,_,disconnected=conforming_model([conforming_control("slat",0.,.5,.8;edge="leading"),conforming_control("flap",.5,1.,.2)])
    @test length(disconnected)==8
    @test check_shared_edges(disconnected)==0
end
