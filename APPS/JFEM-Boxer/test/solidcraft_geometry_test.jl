using Test, JSON, WingFEGen
const W=WingFEGen
isdefined(W,:solidcraft_geometry) || Base.include(W,joinpath(@__DIR__,"..","src","solidcraft_geometry.jl"))

function profile_world(profile,point)
    (profile["origin_mm"].+point[1].*profile["x_dir"].+point[2].*profile["y_dir"])./1000
end

function polygon_sections_world(body)
    commands=body["commands"]
    sections=Vector{Vector{Float64}}[]
    for i in eachindex(commands)
        commands[i]["command"]=="sketch.create" || continue
        @test commands[i+1]["command"]=="sketch.line"
        plane=commands[i]["params"]["plane"]
        push!(sections,[(plane["origin"].+q[1].*plane["x_dir"].+q[2].*plane["y_dir"])./1000
            for q in commands[i+1]["params"]["points"]])
    end
    sections
end

# Body counts alone can pass when structural bays are absent or repeated.
# Independently derive every physical bay and check every actual rib/mesh row,
# including the exact end sections and overlap between CAD loft chunks.
function check_box_bay_coverage(p,plan)
    w=W.make_wing(p);xcs,_=W.chord_stations(w,p);etas,ribs,_=W.span_stations(w,p)
    nh=W.vertical_mesh_count(p["mesh.elements_spar_height"])
    coarse=W.stringer_grid(w,p,xcs,etas,ribs,nh)
    g=W.refine_stringer_bays(coarse,get(p,"mesh.elements_between_stringers",1))
    properties=W.resolved_component_properties(p,length(ribs))
    @test length(ribs)>6
    for reflected in (false,true),bay in 1:length(ribs)-1
        side=reflected ? "Left" : "Right"
        rows=collect(ribs[bay]:ribs[bay+1])
        for (component,group,index,k) in (("Front_Spar_Web","Spar webs",0,0),
                ("Rear_Spar_Web","Spar webs",W.ni(g),0),
                ("Lower_Skin","Box skins",0,0),("Upper_Skin","Box skins",0,nh))
            pattern=Regex("^"*side*"_"*component*"_Bay_"*string(bay)*"_([0-9]+)\$")
            bodies=filter(body->body["group"]==group && occursin(pattern,body["label"]),plan["bodies"])
            sort!(bodies;by=body->parse(Int,match(pattern,body["label"]).captures[1]))
            @test !isempty(bodies)
            sections=Vector{Vector{Float64}}[]
            for (chunk,body) in enumerate(bodies)
                profiles=polygon_sections_world(body)
                if chunk>1
                    @test length(last(sections))==length(first(profiles))
                    @test all(a≈b for (a,b) in zip(last(sections),first(profiles)))
                end
                append!(sections,chunk==1 ? profiles : profiles[2:end])
                commands=[c["command"] for c in body["commands"]]
                if group=="Spar webs"
                    @test "surface.loft" in commands
                    @test count(==("surface.patch"),commands)==2
                    @test count(==("surface.stitch"),commands)==1
                    @test !("solid.loft" in commands)
                else
                    @test "solid.loft" in commands
                end
            end
            @test length(sections)==length(rows)
            for (section,row) in zip(sections,rows)
                anchor=group=="Spar webs" ?
                    (collect(W.grid_point(g,index,row,0)).+collect(W.grid_point(g,index,row,nh)))./2 :
                    collect(W.grid_point(g,0,row,k))
                expected=collect(W.solidcraft_reflect(anchor,reflected,w.root_ref_y))
                actual=group=="Spar webs" ? sum(section)./4 : (first(section).+last(section))./2
                @test actual≈expected atol=3e-10
                if group=="Spar webs"
                    gauge=index==0 ? properties.bays[bay].front_thickness : properties.bays[bay].rear_thickness
                    @test W.norm3(section[1].-section[4])≈gauge atol=3e-10
                    @test W.norm3(section[2].-section[3])≈gauge atol=3e-10
                else
                    gauge=W.shell_thickness(p,k==0 ? W.PID_SKIN_LOWER : W.PID_SKIN_UPPER)
                    @test W.norm3(first(section).-last(section))≈gauge atol=3e-10
                end
            end
        end
    end
end

@testset "SolidCraft authored geometry" begin
    p=W.read_input(joinpath(@__DIR__,"..","input","wing_input.toml"))
    p["properties.panels"]=Any[]
    p["planform.area"]=4.;p["planform.aspect_ratio"]=4.
    p["box.rib_pitch"]=.8;p["box.stringer_pitch"]=.2
    p["properties.rib_stiffeners_enabled"]=false
    p["leading_edge.enabled"]=false
    w=W.make_wing(p)
    profile=W.solidcraft_airfoil_profile(w,.37,.15,.72)
    fractions=[(1-cospi(k/64))/2 for k in 0:64]
    for (index,fraction) in enumerate(fractions)
        actual=profile_world(profile,profile["curves_mm"][1][index])
        expected=collect(W.upper_point(w,.37,.15+(.72-.15)*fraction))
        @test actual≈expected atol=2e-10
    end
    @test_throws ArgumentError W.solidcraft_polygon([(0.,0.,0.),(1.,0.,0.),(2.,0.,0.)])
    @test_throws ArgumentError W.solidcraft_polygon([(0.,0.,0.),(1.,0.,0.),(1.,1.,0.),(0.,1.,.1)])
    before=deepcopy(p)
    plan=W.solidcraft_geometry(p;include_structure=true,mirror=true)
    @test p==before
    @test plan["cad_units"]=="mm"
    @test plan["body_count"]==length(plan["bodies"])
    @test length(unique(body["name"] for body in plan["bodies"]))==plan["body_count"]
    @test any(body["group"]=="Ribs" for body in plan["bodies"])
    @test any(body["group"]=="Spar webs" for body in plan["bodies"])
    @test any(body["group"]=="Box skins" for body in plan["bodies"])
    @test any(body["group"]=="Stringers" for body in plan["bodies"])
    @test any(body["group"]=="Spar caps" for body in plan["bodies"])
    @test plan["bbox_mm"]["min"][2]≈1000*(w.root_ref_y-w.semispan)
    @test plan["bbox_mm"]["max"][2]≈1000*(w.root_ref_y+w.semispan)
    @test JSON.parse(JSON.json(plan))["body_count"]==plan["body_count"]
    for body in plan["bodies"]
        operations=[command for command in body["commands"] if command["command"] in ("solid.loft","surface.loft","solid.extrude")]
        @test length(operations)==1
        @test only(operations)["params"]["body_name"]==body["name"]
        @test get(only(operations)["params"],"operation","new")=="new"
        if only(operations)["command"] in ("solid.loft","surface.loft")
            @test 2<=length(only(operations)["params"]["sections"])<=50
        end
        if only(operations)["command"]=="surface.loft"
            @test count(command->command["command"]=="surface.patch",body["commands"])==2
            @test count(command->command["command"]=="surface.stitch",body["commands"])==1
        end
    end

    surface=Dict{String,Any}("name"=>"Aileron","kind"=>"aileron","edge"=>"trailing",
        "eta_start"=>.3,"eta_end"=>.85,"front_spar_start"=>.72,"front_spar_end"=>.72,
        "hinge_start"=>.7,"hinge_end"=>.7,"hinge_z_start"=>-.75,"hinge_z_end"=>-.75,
        "deflection"=>20.,"color"=>"#5588cc")
    p["movable_surfaces.items"]=[surface]
    neutral=W.solidcraft_geometry(p;include_structure=false,deflected=false)
    deflected=W.solidcraft_geometry(p;include_structure=false,deflected=true)
    controls=[body for body in deflected["bodies"] if body["group"]=="Movable surfaces"]
    @test !isempty(controls)
    @test all(body["metadata"]["deflection_deg"]==20. for body in controls)
    @test neutral["bodies"]!=deflected["bodies"]
    @test_throws ArgumentError W.solidcraft_geometry(p;tolerance_m=0.)
    oldmaterials=deepcopy(p)
    oldmaterials["properties.panels"]=[Dict("key"=>"old panel","layout_token"=>"earlier layout","stringer"=>Dict{String,Any}("material"=>2))]
    materialplan=W.solidcraft_geometry(oldmaterials;include_structure=true)
    @test oldmaterials["properties.panels"][1]["layout_token"]=="earlier layout"
    @test materialplan["body_count"]>0
    oldmaterials["properties.panels"][1]["stringer"]["height"]=.05
    @test_throws W.PanelOverrideConflict W.solidcraft_geometry(oldmaterials;include_structure=true)

    advanced=deepcopy(p)
    advanced["leading_edge.enabled"]=true
    advanced["engines.items"]=[merge(W.ENGINE_DEFAULTS,Dict("name"=>"Test engine","mass"=>500.,"length"=>.8,"x"=>-.4,"y"=>.6,"z"=>-.8))]
    advanced["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.5,"twist"=>2.),Dict("eta"=>1.,"twist"=>-4.)]
    advanced["loft.twist_interpolation"]="cosine"
    advanced["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),Dict("eta"=>.5,"shift_percent"=>1.),Dict("eta"=>1.,"shift_percent"=>2.)]
    advanced["loft.vertical_shift_interpolation"]="linear"
    advanced["loft.thickness_stations"]=[Dict("eta"=>0.,"tc"=>.16),Dict("eta"=>.4,"tc"=>.14),Dict("eta"=>1.,"tc"=>.10)]
    advanced["loft.thickness_interpolation"]="cosine"
    advanced["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Aileron","span_bays"=>2))]
    advanced["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Aileron","eta"=>.5,"actuator"=>true))]
    advancedplan=W.solidcraft_geometry(advanced;include_structure=true)
    @test any(body["group"]=="Leading edge skins" for body in advancedplan["bodies"])
    @test any(body["group"]=="Leading edge ribs" for body in advancedplan["bodies"])
    engine=only(filter(body->body["group"]=="Engine beams",advancedplan["bodies"]))
    @test engine["metadata"]["mass_kg"]==500.
    @test engine["metadata"]["area_m2"]==advanced["engines.items"][1]["A"]
    @test advancedplan["bbox_mm"]["min"][3]<=-800.
    @test any(body["group"]=="Movable ribs" for body in advancedplan["bodies"])
    @test any(body["group"]=="Movable skins" for body in advancedplan["bodies"])
    @test any(body["group"]=="Movable spars" for body in advancedplan["bodies"])
    @test count(body->body["group"]=="Actuator symbols",advancedplan["bodies"])==2
    advanceddeflected=W.solidcraft_geometry(advanced;include_structure=true,deflected=true)
    movinggroups=("Movable surfaces","Movable ribs","Movable skins","Movable spars")
    moving=[body for body in advanceddeflected["bodies"] if body["group"] in movinggroups]
    @test all(count(command->command["command"]=="solid.move",body["commands"])==3 for body in moving)
    @test only(filter(body->body["group"]=="Engine beams",advanceddeflected["bodies"]))["commands"]==engine["commands"]
    blades=W.default_params()
    blades["planform.area"]=4.;blades["planform.aspect_ratio"]=4.;blades["planform.taper"]=1.
    blades["planform.sweep"]=0.;blades["planform.dihedral"]=0.
    blades["box.rib_pitch"]=.8;blades["box.stringer_pitch"]=.1;blades["mesh.stringer_runout_ratio"]=.05
    blades["properties.rib_stiffeners_enabled"]=false
    blades["movable_surfaces.items"]=Any[]
    blades["stringers.model"]="shell"
    blades["stringers.orientation"]="coordinate_axis"
    blades["stringers.axis"]="z";blades["stringers.axis_cid"]=0
    blades["properties.stringer_flange_width"]=0.
    blades["properties.stringer_flange_thickness"]=0.
    blades["properties.stringer_height"]=.05
    bladeplan=W.solidcraft_geometry(blades;include_structure=true)
    blade=first(body for body in bladeplan["bodies"] if body["group"]=="Stringers" && body["metadata"]["section_shape"]=="Shell blade")
    plane=blade["commands"][1]["params"]["plane"]
    coordinates=blade["commands"][2]["params"]["points"]
    world=[(plane["origin"].+q[1].*plane["x_dir"].+q[2].*plane["y_dir"])./1000 for q in coordinates]
    direction=(world[2].+world[3].-world[1].-world[4])./2
    @test abs(direction[1])<2e-10
    @test abs(direction[2])<2e-10
    @test abs(direction[3])≈.05 atol=2e-10
    @test blade["metadata"]["axis_cid"]==0
    flanges=deepcopy(blades)
    flanges["properties.stringer_flange_width"]=.04
    flanges["properties.stringer_flange_thickness"]=.002
    flanges["stringers.shell_offsets"]=true
    flangeplan=W.solidcraft_geometry(flanges;include_structure=true)
    @test any(body["group"]=="Box skins" && any(id->id÷W.COMPONENT_PID_STRIDE==20,body["metadata"]["property_ids"]) for body in flangeplan["bodies"])
    custom=deepcopy(blades);custom["stringers.axis_cid"]=1
    customplan=W.solidcraft_geometry(custom;include_structure=true)
    @test any(body["group"]=="Stringers" && body["metadata"]["axis_cid"]==1 for body in customplan["bodies"])
    crop=deepcopy(blades);crop["airfoil.root"]="0012";crop["airfoil.tip"]="0012"
    cropwing=W.make_wing(crop)
    bounds(eta)=(.3+.3eta,1.)
    cropped_samples=W.solidcraft_span_samples(cropwing,0.,1.,Float64[],2.5e-5;bounds)
    @test length(cropped_samples)>2
    @test maximum(W.norm3(W.upper_point(cropwing,(a+b)/2,first(bounds((a+b)/2))).-
        (W.upper_point(cropwing,a,first(bounds(a))).+W.upper_point(cropwing,b,first(bounds(b))))./2)
        for (a,b) in zip(cropped_samples[1:end-1],cropped_samples[2:end]))<=2.5e-5

    coverage=deepcopy(blades)
    coverage["stringers.model"]="beam"
    coverage["properties.stringer_flange_width"]=.03
    coverage["properties.stringer_flange_thickness"]=.0015
    coverage["box.rib_pitch"]=.25
    coverage["mesh.elements_between_ribs"]=3
    coverage["ribs.plane"]="normal_to_midplane"
    coverage["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.4,"twist"=>2.),Dict("eta"=>1.,"twist"=>-3.)]
    coverage["loft.twist_interpolation"]="cosine"
    coverage["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),Dict("eta"=>1.,"shift_percent"=>3.)]
    coverage["properties.spar_bays"]=[Dict("bay"=>3,"front_thickness"=>.0025,"rear_thickness"=>.003)]
    coverageplan=W.solidcraft_geometry(coverage;include_structure=true,mirror=true)
    check_box_bay_coverage(coverage,coverageplan)

    # A long bay must retain the shared boundary section when split at the
    # native fifty-section limit; it must not skip or duplicate an interval.
    profiles=[W.solidcraft_polygon([(0.,y,0.),(0.,y,.1),(.0015,y,.1),(.0015,y,0.)]) for y in range(0.,1.;length=103)]
    chunks=Any[]
    W.solidcraft_loft_chunks!(chunks,"Long_Spar_Web","Spar webs",profiles)
    @test length(chunks)==3
    allsections=polygon_sections_world.(chunks)
    @test last(allsections[1])==first(allsections[2])
    @test last(allsections[2])==first(allsections[3])
    rows=vcat(first(allsections),allsections[2][2:end],allsections[3][2:end])
    @test length(rows)==103
    @test all(isapprox(first(section)[2],y;atol=2e-10) for (section,y) in zip(rows,range(0.,1.;length=103)))
    if !isempty(ARGS)
        mkpath(ARGS[1]);open(io->JSON.print(io,plan,2),joinpath(ARGS[1],"small_wing_plan.json"),"w")
        open(io->JSON.print(io,deflected,2),joinpath(ARGS[1],"deflected_wing_plan.json"),"w")
        open(io->JSON.print(io,advancedplan,2),joinpath(ARGS[1],"advanced_wing_plan.json"),"w")
        open(io->JSON.print(io,advanceddeflected,2),joinpath(ARGS[1],"advanced_deflected_wing_plan.json"),"w")
        open(io->JSON.print(io,bladeplan,2),joinpath(ARGS[1],"shell_blade_wing_plan.json"),"w")
        open(io->JSON.print(io,flangeplan,2),joinpath(ARGS[1],"shell_flange_wing_plan.json"),"w")
    end
end

@testset "SolidCraft rotating spar-web sections retain authored geometry" begin
    # Reproduce the curved, normal-to-midplane rib layout from problem2 without
    # depending on a user Study or any private workspace/native CAD installation.
    curved=W.default_params()
    curved["planform.area"]=40.;curved["planform.aspect_ratio"]=8.
    curved["planform.taper_ratio"]=.45;curved["planform.sweep"]=15.
    curved["planform.dihedral"]=5.;curved["planform.twist_tip"]=-3.
    curved["airfoil.root"]="NACA2412";curved["airfoil.tip"]="NACA2410"
    curved["box.end_eta"]=.9;curved["box.rib_pitch"]=.6
    curved["box.front_spar_xc"]=.2;curved["box.rear_spar_xc"]=.55
    curved["box.stringer_pitch"]=.15;curved["mesh.stringer_runout_ratio"]=.75
    curved["mesh.elements_between_ribs"]=3;curved["mesh.elements_between_stringers"]=1
    curved["mesh.elements_spar_height"]=3
    curved["ribs.plane"]="normal_to_midplane"
    curved["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),
        Dict("eta"=>.5,"shift_percent"=>0.),Dict("eta"=>1.,"shift_percent"=>21.)]
    curved["loft.vertical_shift_interpolation"]="cosine"
    curved["properties.t_spar_web"]=.0015
    curved["properties.panels"]=Any[];curved["properties.ribs"]=Any[]
    curved["properties.spar_bays"]=Any[];curved["properties.components"]=Any[]
    curved["movable_surfaces.items"]=Any[];curved["leading_edge.enabled"]=false
    original=deepcopy(curved)
    plan=W.solidcraft_geometry(curved;include_structure=true,mirror=true)
    @test curved==original
    check_box_bay_coverage(curved,plan)
    turn_by_bay=Dict{Int,Vector{Float64}}()
    for body in filter(body->body["group"]=="Spar webs",plan["bodies"])
        sections=polygon_sections_world(body)
        normals=Vector{Float64}[]
        for section in sections
            @test length(section)==4
            first_edge=section[2].-section[1]
            gauge_edge=section[4].-section[1]
            area=W.cross3(first_edge,gauge_edge)
            @test W.norm3(area)>1e-6
            normal=collect(W.unit3(area));push!(normals,normal)
            # The narrow dimension remains 1.5 mm and every loop is planar,
            # including the strongly turning inboard/outboard cap planes.
            @test W.norm3(gauge_edge)≈.0015 atol=2e-10
            @test abs(sum(first_edge.*gauge_edge))<=1e-10
            @test maximum(abs(sum((point.-section[1]).*normal)) for point in section)<=2e-10
            for point in section,k in 1:3
                @test plan["bbox_mm"]["min"][k]-1e-6<=1000point[k]<=plan["bbox_mm"]["max"][k]+1e-6
            end
        end
        bay=parse(Int,match(r"_Bay_(\d+)_",body["label"]).captures[1])
        turns=[acosd(clamp(sum(a.*b),-1.,1.)) for (a,b) in zip(normals[1:end-1],normals[2:end])]
        append!(get!(()->Float64[],turn_by_bay,bay),turns)
    end
    @test maximum(turn_by_bay[1])>5.
    @test all(maximum(turn_by_bay[bay])>.5 for bay in 8:13)
    @test all(maximum(turn_by_bay[bay])<.1 for bay in 2:7)
end
