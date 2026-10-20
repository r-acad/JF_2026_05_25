using Test, TOML, WingFEGen
const W=WingFEGen
surface(;kw...)=merge(Dict{String,Any}("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
    "eta_start"=>.2,"eta_end"=>.7,"hinge_start"=>.7,"hinge_end"=>.8,"deflection"=>15.,"color"=>"#29B6D1"),Dict(string(k)=>v for (k,v) in kw))

@testset "Movable surface definitions and portable input" begin
    @test isempty(W.default_params()["movable_surfaces.items"])
    @test isempty(first(W.normalize_params(Dict("planform.twist_tip"=>-4.)))["movable_surfaces.items"])
    p=W.default_params();p["movable_surfaces.items"]=[surface(name=" Flap \"one\" ")]
    p,unknown=W.normalize_params(p);@test isempty(unknown)
    @test p["movable_surfaces.items"][1]["name"]=="Flap \"one\""
    @test p["movable_surfaces.items"][1]["color"]=="#29b6d1"
    restored,unknown=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p))))
    @test isempty(unknown)
    @test restored["movable_surfaces.items"]==p["movable_surfaces.items"]
    drawings=W.normalize_drawings(W.JSON.json(Dict("movable-surfaces-plan"=>Dict())))
    @test haskey(W.JSON.parse(drawings),"movable-surfaces-plan")
    for change in [Dict("eta_start"=>-.1),Dict("eta_end"=>1.01),Dict("eta_start"=>.7),Dict("hinge_start"=>0),
        Dict("hinge_end"=>1),Dict("deflection"=>91),Dict("deflection"=>NaN),Dict("name"=>""),Dict("extra"=>1),
        Dict("color"=>"red"),Dict("kind"=>"spoiler"),Dict("eta_start"=>true)]
        @test_throws ArgumentError W.normalize_movable_surfaces([merge(surface(),change)])
    end
    @test_throws ArgumentError W.normalize_movable_surfaces([surface(),surface(name="FLAP",eta_start=.7,eta_end=1.)])
    @test_throws ArgumentError W.normalize_movable_surfaces([surface(),surface(name="Aileron",eta_start=.6,eta_end=1.)])
    @test length(W.normalize_movable_surfaces([surface(),surface(name="Aileron",eta_start=.7,eta_end=1.)]))==2
    @test length(W.normalize_movable_surfaces([surface(),surface(name="Slat",edge="leading",hinge_start=.1,hinge_end=.2)]))==2
    @test_throws ArgumentError W.normalize_movable_surfaces([surface(),surface(name="Slat",edge="leading",hinge_start=.1,hinge_end=.9)])
end

@testset "Loft trimming and rigid hinge rotation without model changes" begin
    p=W.default_params();p["planform.twist_tip"]=0.;p["planform.dihedral"]=0.;p["planform.sweep"]=0.
    p["airfoil.root"]="NACA0012";p["airfoil.tip"]="NACA0012"
    p["movable_surfaces.items"]=[surface(deflection=0.,hinge_start=.75,hinge_end=.75)]
    original=deepcopy(p);neutral=W.movable_surfaces_preview(p);@test p==original
    @test neutral["geometry_only"]===true
    s=only(neutral["surfaces"]);w=W.make_wing(p)
    @test s["xyz"][1:3]≈collect(W.upper_point(w,.2,.75))
    @test collect(s["hinge"][1])≈collect(W.section_point(w,.2,.75,0.))
    @test length(s["triangles"])%3==0
    @test all(i->0<=i<length(s["xyz"])÷3,s["triangles"])
    p["movable_surfaces.items"][1]["deflection"]=90.
    rotated=only(W.movable_surfaces_preview(p)["surfaces"])
    @test rotated["hinge"]==s["hinge"]
    @test rotated["outline"]==s["outline"] # neutral plan footprint
    # Inboard TE upper node: positive span-axis rotation lowers its x lever.
    te=3*8+1;@test rotated["xyz"][te+2]<s["xyz"][te+2]
    for i in 1:3:length(s["xyz"])
        a=s["xyz"][i:i+2].-s["hinge"][1];b=rotated["xyz"][i:i+2].-s["hinge"][1]
        @test sum(abs2,a)≈sum(abs2,b) rtol=3e-12 atol=1e-12
    end
    # The preview follows refined edges, airfoil blending and twist schedules.
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>3.),Dict("eta"=>1.,"twist"=>-9.)]
    p["planform.leading_edge_points"]=[Dict("eta"=>.4,"dxc"=>.08)]
    p["movable_surfaces.items"][1]["deflection"]=0.
    curved=only(W.movable_surfaces_preview(p)["surfaces"]);w=W.make_wing(p)
    @test curved["xyz"][1:3]≈collect(W.upper_point(w,.2,.75))
    @test all(isfinite,curved["xyz"])
    # Defining a movable surface does not change the original loft used by FE.
    plain=deepcopy(p);plain["movable_surfaces.items"]=Any[];base=W.make_wing(plain)
    @test W.upper_point(base,.6,.8)==W.upper_point(w,.6,.8)
    @test W.lower_point(base,.6,.8)==W.lower_point(w,.6,.8)
end
