using Test, WingFEGen
const W=WingFEGen

function generation_fixture()
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.7,
        "box.end_eta"=>1.,"box.rib_pitch"=>.3,"box.stringer_pitch"=>.2,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,"mesh.elements_spar_height"=>1,
        "leading_edge.enabled"=>false,"fuel.enabled"=>false,"loads.method"=>"analytic",
        "loads.structure_inertia"=>true,"loads.cases"=>Any[Dict("id"=>2,"label"=>"Other acceleration","fuel_percent"=>60.,"fuel_accel_z"=>1.)]))
    first(W.normalize_params(p))
end

@testset "FEM generation prepares only requested optional work" begin
    p=generation_fixture();stages=String[]
    m=W.build_model(deepcopy(p);progress=s->push!(stages,s),summaries=false)
    @test "mass_references" in stages
    @test all(!startswith(stage,"fuel") for stage in stages)
    @test !("weights" in stages) # Summary is prepared once for the payload.
    @test !isempty(m.fuel_rbe3) # Dry structural inertia still has its required load path.
    model_before=(copy(m.node_ids),copy(m.xyz),[copy(g.conn) for g in m.groups])
    empty!(stages);payload=W.mesh_payload(m;progress=s->push!(stages,s))
    @test all(!startswith(stage,"fuel") for stage in stages)
    @test count(==("weights"),stages)==1
    @test model_before==(m.node_ids,m.xyz,[g.conn for g in m.groups])
    @test !payload["fuel"]["enabled"]
    @test payload["load_cases"][1]["weights"]["components"]===payload["load_cases"][2]["weights"]["components"]
    @test payload["load_cases"][1]["weights"]["fuel"]["fuel_percent"]==100.
    @test payload["load_cases"][2]["weights"]["fuel"]["fuel_percent"]==60.
    @test !haskey(payload["load_cases"][1]["weights"],"structural_inertia")
    @test haskey(payload["weights"],"structural_inertia")
    @test count(row->first(row)=="Dry half lifting surface mass",payload["info"])==1
    @test !any(row->startswith(first(row),"Fuel"),payload["info"])
    ordinary=W.build_model(deepcopy(p))
    @test any(row->first(row)=="Dry half lifting surface mass",ordinary.info)
    @test all(isapprox(v,payload["weights"]["totals"][k];rtol=1e-12) for (k,v) in W.weights_payload(ordinary)["totals"])
    @test ordinary.xyz==m.xyz

    dry=deepcopy(p);dry["loads.structure_inertia"]=false;dry["loads.cases"]=Any[]
    empty!(stages);unloaded=W.build_model(dry;progress=s->push!(stages,s),summaries=false)
    @test isempty(unloaded.fuel_rbe3)
    @test !("mass_references" in stages)
    @test all(!startswith(stage,"fuel") for stage in stages)
end

@testset "Defined fuel retains distinct case mass and exact geometry" begin
    p=generation_fixture();p["fuel.enabled"]=true;p["fuel.end_rib"]=3;p["loads.fuel_percent"]=0.
    p["loads.cases"]=Any[Dict("id"=>2,"label"=>"Full tank","fuel_percent"=>100.)]
    stages=String[];m=W.build_model(p;progress=s->push!(stages,s),summaries=false)
    @test "fuel_masses" in stages
    @test !("fuel" in stages) # No duplicate capacity summary during meshing.
    payload=W.mesh_payload(m;progress=s->push!(stages,s))
    @test "fuel_display" in stages
    @test payload["fuel"]["surface"]["count"]>0
    @test any(row->first(row)=="Fuel FE mass",payload["info"])
    @test payload["load_cases"][1]["fuel"]["mass_kg"]==0.
    @test payload["load_cases"][2]["fuel"]["mass_kg"]>0.
    @test payload["load_cases"][1]["weights"]["totals"]["loaded_mass_kg"]<payload["load_cases"][2]["weights"]["totals"]["loaded_mass_kg"]
    for (spec,row) in zip(W.load_case_specs(p),payload["load_cases"])
        fresh=W.weights_payload(W.model_for_load_case(m,spec))
        @test all(isapprox(row["weights"]["totals"][k],v;rtol=1e-12) for (k,v) in fresh["totals"])
        @test row["weights"]["mass_properties"]==fresh["mass_properties"]
    end
end
