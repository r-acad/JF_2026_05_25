using Test, JSON, TOML
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
function parameters(;sandwich=false)
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.15,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "leading_edge.enabled"=>true,"leading_edge.chord_elements"=>2,
        "loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[]))
    if sandwich
        for row in p["materials.shells"];row["kind"]="sandwich";end
        # These legacy total-thickness settings constrain the inherited core.
        p["properties.ribs"]=[Dict("rib"=>1,"thickness"=>.018)]
        p["properties.spar_bays"]=[Dict("bay"=>1,"front_thickness"=>.020,"rear_thickness"=>.019)]
    end
    p
end
pid(part,index)=W.component_table_family(part)*W.COMPONENT_PID_STRIDE+index
tests=@testset "Independent inherited physical component properties" begin
    p=parameters();original=deepcopy(p);m=W.build_model(p)
    @test p==original # Inheritance must stay live rather than writing frozen overrides.
    defs=Dict(d["pid"]=>d for d in W.model_property_definitions(m));nr=length(m.grid.ribs)
    catalogue=W.sensitivity_catalog(m)["variables"]
    @test length(unique(d["id"] for d in catalogue))==length(catalogue)
    for part in W.COMPONENT_TABLE_PARTS,index in 1:(W.component_table_isrib(part) ? nr : nr-1)
        id=pid(part,index);@test haskey(defs,id)
        localvars=filter(d->get(d,"component_key",nothing)==W.component_table_key(part,index),catalogue)
        @test length(localvars)==(part=="rib_stiffener" ? 4 : 1)
        @test all(d->d["pids"]==[id]&&d["inherited"],localvars)
        @test all(d->d["element_count"]==sum(length(g.eids) for g in m.groups if g.pid==id),localvars)
    end
    @test all(g->W.component_table_part(g.pid)!==nothing,
        filter(g->W.component_base_pid(g.pid) in (W.PID_SPAR_WEB,W.PID_SPAR_CAP,W.PID_RIB_WEB,W.PID_RIB_STIFFENER,W.PID_LE_SKIN,W.PID_LE_RIB),m.groups))
    # A shared default controls all inherited cards; a local DV changes just one.
    shared=only(filter(d->d["id"]=="properties.spar_cap_side",catalogue))
    @test Set(shared["pids"])==Set(pid(part,bay) for part in W.COMPONENT_TABLE_PARTS if W.component_table_iscap(part) for bay in 1:nr-1)
    localcap=only(filter(d->d["id"]=="properties.components#front_upper_cap:1#side",catalogue))
    changed=W.sensitivity_set!(deepcopy(p),localcap,.031)
    @test changed["properties.components"]==[Dict("key"=>"front_upper_cap:1","side"=>.031)]
    changedmodel=W.build_model(changed);@test changedmodel.xyz==m.xyz
    @test [(g.pid,g.eids,g.conn) for g in changedmodel.groups]==[(g.pid,g.eids,g.conn) for g in m.groups]
    changedvars=W.sensitivity_catalog(changedmodel)["variables"]
    @test !(pid("front_upper_cap",1) in only(filter(d->d["id"]=="properties.spar_cap_side",changedvars))["pids"])
    roundtrip,unknown=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(changed))))
    @test isempty(unknown);@test W.model_property_definitions(W.build_model(roundtrip))==W.model_property_definitions(changedmodel)
    refined=W.build_model(merge(deepcopy(p),Dict("mesh.elements_between_ribs"=>2)))
    @test Set(d["id"] for d in W.sensitivity_catalog(refined)["variables"] if haskey(d,"component_key"))==Set(d["id"] for d in catalogue if haskey(d,"component_key"))
    for sandwich in (false,true)
        model=W.build_model(parameters(;sandwich));definitions=W.model_property_definitions(model)
        variables=W.sensitivity_catalog(model)["variables"]
        locals=filter(d->haskey(d,"component_key")&&endswith(d["component_key"],":1"),variables)
        for d in locals
            h=max(abs(d["value"])*1e-5,1e-9)
            plus=W.sensitivity_model(model,W.sensitivity_set!(deepcopy(model.params),d,d["value"]+h))
            minus=W.sensitivity_model(model,W.sensitivity_set!(deepcopy(model.params),d,d["value"]-h))
            pp=Dict(x["pid"]=>x for x in W.model_property_definitions(plus));pm=Dict(x["pid"]=>x for x in W.model_property_definitions(minus))
            @test Set(keys(W.sensitivity_analytic_property_directions(model,d;properties=definitions)))==Set(d["pids"])
            for property in definitions
                id=property["pid"];direction=W.sensitivity_analytic_property_direction(model,d,property)
                if property["kind"]=="bar"
                    @test direction["dimensions"]≈(pp[id]["section"]["dimensions_m"]-pm[id]["section"]["dimensions_m"])/(2h) atol=1e-7
                else
                    @test direction["thickness"]≈(pp[id]["thickness_m"]-pm[id]["thickness_m"])/(2h) atol=1e-7
                    @test direction["areal_mass"]≈(pp[id]["areal_mass_kg_m2"]-pm[id]["areal_mass_kg_m2"])/(2h) atol=1e-5
                    if property["type"]=="PCOMP"
                        @test direction["ply_thicknesses"]≈[(a["thickness_m"]-b["thickness_m"])/(2h) for (a,b) in zip(pp[id]["plies"],pm[id]["plies"])] atol=1e-7
                    end
                end
            end
        end
    end
    write(joinpath(out,"default_components.toml"),W.params_to_toml(p))
    write(joinpath(out,"default_components.bdf"),sprint(io->W.write_deck(IOContext(io,:full_precision=>true),m)))
end
c=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes)))
