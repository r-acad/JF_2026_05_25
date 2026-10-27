using Test, LinearAlgebra, JSON, WingFEGen
const W=WingFEGen
module ConversionParser end
Base.include(ConversionParser,joinpath(first(W.find_jfem(dirname(@__DIR__))),"src","parsing","ReferenceParser.jl"))
const N=ConversionParser.ReferenceParser
isdefined(W,:sensitivity_analytic_section)||Base.include(W,joinpath(@__DIR__,"..","src","sensitivity_analytic_beams.jl"))
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function conversion_parameters()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.14,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>2,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "mesh.aero_chord_points"=>11,"leading_edge.enabled"=>false,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "stringers.model"=>"shell","stringers.orientation"=>"coordinate_axis",
        "stringers.axis_cid"=>0,"stringers.axis"=>"z","properties.stringer_flange_width"=>0.,
        "properties.stringer_flange_thickness"=>0.,"properties.stringer_height"=>.04,
        "properties.stringer_web_thickness"=>.002,"output.solution"=>"101"))
end
build(p)=W.build_model(first(W.normalize_params(p)))
suite=@testset "Physical blade shell/beam representation conversion" begin
    p=conversion_parameters();shell=build(p)
    @test W.all_checks_pass(shell)
    beam=build(merge(p,Dict("stringers.model"=>"beam")))
    @test W.all_checks_pass(beam)
    back=build(merge(beam.params,Dict("stringers.model"=>"shell")))
    @test W.all_checks_pass(back)
    for key in (W.STRINGER_DIMENSION_KEYS...,"stringers.orientation","stringers.axis_cid","stringers.axis")
        @test shell.params[key]==beam.params[key]==back.params[key]==p[key]
    end
    @test shell.xyz==back.xyz
    @test [(g.pid,g.kind,g.conn) for g in shell.groups]==[(g.pid,g.kind,g.conn) for g in back.groups]
    @test !any(W.component_base_pid(g.pid) in (W.PID_STRINGER_WEB,W.PID_STRINGER_FLANGE) for g in beam.groups)
    groups=filter(g->g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_STRINGER,beam.groups)
    @test !isempty(groups)
    deck=sprint(io->W.write_deck(IOContext(io,:full_precision=>true),beam))
    write(joinpath(out,"beam_blade.bdf"),deck)
    _,bulk=N.read_bulk_and_case(String.(split(deck,'\n')));cards=N.process_cards(bulk)
    properties=N.extract_pbarl(cards["PBARL"]);bars=N.extract_cbar(cards["CBAR"])
    h=.04;tw=.002;area=h*tw
    for group in groups
        section=W.section_definition(beam.params,group.pid);native=properties[string(group.pid)]
        @test native["TYPE"]==section["shape"]=="BAR"
        @test native["DIMS"]==section["dimensions_m"]==[tw,h]
        @test section["area_m2"]≈area
        @test section["I1_m4"]≈tw*h^3/12
        @test section["I2_m4"]≈h*tw^3/12
        for (field,key) in (("area_m2","A"),("I1_m4","I1"),("I2_m4","I2"),("J_m4","J"))
            @test section[field]≈native[key] rtol=1e-12
        end
        ys=first.(section["polygon_yz_m"]).+section["offset_y_m"]
        @test extrema(ys)==(-h,0.)
        for e in eachindex(group.eids)
            pa,pb=collect.(W.element_points(beam,group,e));d=pb-pa;L=norm(d)
            upper=(pa[3]+pb[3])>0;outward=upper ? [0.,0.,1.] : [0.,0.,-1.]
            @test group.orient[3*e-2:3*e]≈outward atol=1e-12
            x=d/L;y=normalize(outward-dot(outward,x)*x);z=cross(x,y)
            offset=-h/2*y
            @test collect(W.bar_section_offset(beam,group,e))≈offset atol=1e-12
            @test bars[string(group.eids[e])]["WA"]≈offset atol=1e-12
            @test bars[string(group.eids[e])]["WB"]≈offset atol=1e-12
            rho=W.bar_material_definition(beam.params,group.pid)["rho"]
            expected_mass=rho*area*L;center=(pa+pb)/2+offset
            expected_second=expected_mass*(center*center'+d*d'/12+(h^2*y*y'+tw^2*z*z')/12)
            moments=W.structural_element_mass_moments(beam,group,e)
            @test moments.mass≈expected_mass rtol=1e-12
            @test moments.first≈expected_mass*center rtol=1e-12
            @test moments.second≈expected_second rtol=1e-12
        end
    end
    skin=first(filter(g->W.component_base_pid(g.pid)==W.PID_SKIN_UPPER,beam.groups))
    cid=first(skin.eids);selected=build(merge(p,Dict("stringers.model"=>"beam","stringers.axis_cid"=>cid)))
    selected_skin=only(filter(g->cid in g.eids,selected.groups));e=findfirst(==(cid),selected_skin.eids)
    _,_,selected_axis=W.shell_material_frame(selected,selected_skin,e)
    @test selected.grid.shell_columns===nothing
    for group in selected.groups
        group.kind===:bar&&W.component_base_pid(group.pid)==W.PID_STRINGER||continue
        for e in eachindex(group.eids)
            v=group.orient[3*e-2:3*e]
            @test norm(cross(v,collect(selected_axis)))<1e-12
            pa,pb=W.element_points(selected,group,e)
            @test v[3]*((pa[3]+pb[3])>0 ? 1 : -1)>0
        end
    end
    unavailable=try build(merge(p,Dict("stringers.model"=>"beam","stringers.axis_cid"=>999999999)));nothing catch error;error end
    @test unavailable isa ArgumentError
    @test occursin("stringers.axis_cid",sprint(showerror,unavailable))
    @test occursin("Select BASIC",sprint(showerror,unavailable))
    blades=W.stringer_blade_payload(beam);@test !isempty(blades)
    @test all(r->r["status"]=="ready",blades)
    @test all(b->b["section_shape"]=="BAR"&&b["web_height_m"]==h&&b["web_thickness_m"]==tw,vcat(getindex.(blades,"bars")...))
    columns=W.stringer_euler_payload(beam);@test !isempty(columns)
    @test all(r->r["status"]=="ready"&&r["membership_complete"],columns)
    catalog=W.sensitivity_catalog(beam)["variables"]
    locals=filter(d->get(d,"group","")=="Panel stringers",catalog)
    @test !isempty(locals)
    @test Set(last.(getindex.(locals,"path")))==Set(("height","web_thickness"))
    defs=Dict(d["pid"]=>d for d in W.model_property_definitions(beam))
    for variable in locals
        definition=defs[only(variable["pids"])];direction=W.sensitivity_analytic_property_direction(beam,variable,definition)
        expected=last(variable["path"])=="height" ? [0.,1.] : [1.,0.]
        @test direction["dimensions"]==expected
    end
    for direction in ([1.,0.],[0.,1.])
        analytic=W.sensitivity_analytic_section("BAR",[tw,h],direction);step=1e-7
        minus=W.sensitivity_analytic_section("BAR",[tw,h].-step.*direction)
        plus=W.sensitivity_analytic_section("BAR",[tw,h].+step.*direction)
        for (value,derivative) in ((:area,:darea),(:I1,:dI1),(:I2,:dI2),(:J,:dJ),(:offset_y,:doffset_y))
            @test getproperty(analytic,derivative)≈(getproperty(plus,value)-getproperty(minus,value))/(2step) rtol=1e-8 atol=1e-14
        end
    end
    # A local true T keeps its real flange; other zero-width panels remain BAR.
    panels=W.stiffened_panels_payload(beam);row=first(panels["panels"])
    overridden=build(merge(p,Dict("stringers.model"=>"beam","properties.panels"=>[Dict(
        "key"=>row["key"],"layout_token"=>panels["layout_token"],
        "stringer"=>Dict("flange_width"=>.03,"flange_thickness"=>.002))])))
    @test W.section_definition(overridden.params,row["stringer_pid"])["shape"]=="T"
    @test any(W.section_definition(overridden.params,g.pid)["shape"]=="BAR" for g in overridden.groups if g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_STRINGER)
    for (key,value,field) in (("properties.stringer_height",0.,"height"),("properties.stringer_web_thickness",0.,"web thickness"),("properties.stringer_flange_width",-.01,"flange width"))
        error=try W.normalize_params(merge(p,Dict("stringers.model"=>"beam",key=>value)));nothing catch e;e end
        @test error isa ArgumentError
        @test occursin(field,lowercase(sprint(showerror,error)))
    end
    view=Dict("controls"=>Dict("auto-mesh"=>false,"auto-save"=>false),"layers"=>Dict(),"activeCase"=>1,
        "camera"=>Dict("target"=>[.5,.5,0.],"alpha"=>-1.,"beta"=>1.,"radius"=>2.),
        "workspace"=>Dict("activeTab"=>"stringerlayout","width"=>400.,"collapsed"=>false))
    write(joinpath(out,"shell_blade.wingfem.json"),JSON.json(Dict("format"=>"wingfegen-workspace","version"=>1,"parameters"=>p,"references"=>Any[],"view"=>view)))
    write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(beam)))
end
c=Test.get_test_counts(suite)
write(joinpath(out,"conversion_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes)))
