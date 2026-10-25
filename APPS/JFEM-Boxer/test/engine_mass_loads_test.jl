# julia --startup-file=no --project=. APPS/JFEM-Boxer/test/engine_mass_loads_test.jl OUTPUT
using Test, LinearAlgebra, JSON, WingFEGen, OpenJFEM
const W=WingFEGen
const N=OpenJFEM
const OUT=abspath(only(ARGS));mkpath(OUT)

function engine_mass_params()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.end_eta"=>1.,
        "box.rib_pitch"=>1.,"box.stringer_pitch"=>.3,"mesh.elements_between_ribs"=>1,
        "mesh.elements_between_stringers"=>1,"mesh.elements_spar_height"=>1,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "loads.method"=>"analytic","loads.lift_total"=>100.,"loads.torque_y"=>0.,
        "loads.load_factor"=>1.5,"loads.structure_inertia"=>true,
        "loads.fuel_accel_x"=>.2,"loads.fuel_accel_y"=>-.3,"loads.fuel_accel_z"=>-2.,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"output.solution"=>"101",
        "engines.items"=>Any[Dict("name"=>"Test engine","x"=>-.4,"y"=>1.4,"z"=>-1.2,
            "mass"=>300.,"length"=>2.4,"front_rib"=>3,"aft_rib"=>3,"aft_xc"=>.55)]))
end
build(p)=W.build_model(first(W.normalize_params(p)))

function native_mass(m,name)
    path=joinpath(OUT,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    model=N.bdf_to_model(path);ids=sort(parse.(Int,collect(keys(model["GRIDs"]))))
    id_map=Dict(id=>i for (i,id) in enumerate(ids))
    X=reduce(vcat,[transpose(Float64.(model["GRIDs"][string(id)]["X"])) for id in ids])
    R=[Matrix{Float64}(I,3,3) for _ in ids];ndof=6length(ids)
    M=N.Solver.assemble_mass(model,id_map,X,R,ndof)
    Q=zeros(ndof,6)
    for (i,_) in enumerate(ids)
        dofs=6(i-1).+(1:6)
        Q[dofs[1:3],1:3].=Matrix{Float64}(I,3,3)
        Q[dofs[1:3],4:6].=-N.Solver.skew3(X[i,:])
        Q[dofs[4:6],4:6].=Matrix{Float64}(I,3,3)
    end
    (;model,id_map,X,R,ndof,mass=Q'*M*Q)
end

function engine_rigid_mass(engine)
    mass=engine["mass_kg"];c=engine["center_of_gravity_m"];S=N.Solver.skew3(c)
    inertia=reduce(vcat,[transpose(r) for r in engine["inertia_kg_m2"]])
    result=zeros(6,6);result[1:3,1:3].=mass.*Matrix{Float64}(I,3,3)
    result[1:3,4:6].=-mass.*S;result[4:6,1:3].=mass.*S
    result[4:6,4:6].=inertia+mass.*(dot(c,c).*Matrix{Float64}(I,3,3)-c*c')
    result
end

records=Any[]
checks=@testset "Engine mass and direct CG inertia" begin
    p=engine_mass_params();m=build(p);engine=only(W.engine_records(m))
    noengine=build(merge(p,Dict("engines.items"=>Any[])))
    base=W.weights_payload(noengine);weights=W.weights_payload(m)
    @test weights["totals"]["structure_mass_kg"]≈base["totals"]["structure_mass_kg"] rtol=1e-13
    @test weights["totals"]["engine_mass_kg"]==300.
    @test weights["totals"]["loaded_mass_kg"]≈base["totals"]["loaded_mass_kg"]+300.
    @test weights["totals"]["deck_mass_kg"]≈base["totals"]["deck_mass_kg"]+300.
    @test sum(row["mass_kg"] for row in weights["components"])≈weights["totals"]["deck_mass_kg"]
    @test length(filter(row->row["kind"]=="engine_mass",weights["components"]))==1
    @test sum(row["mass_kg"] for row in W.structural_bay_mass_properties(m))≈base["totals"]["structure_mass_kg"]
    @test W.structural_mass_data(m).nodal_mass[1:noengine.n_struct]≈W.structural_mass_data(noengine).nodal_mass
    @test all(iszero,W.structural_mass_data(m).nodal_mass[noengine.n_struct+1:end])

    # Native mass assembly verifies that the separate engine mass is neither
    # suppressed nor duplicated by either wing structural mass representation.
    for representation in ("distributed","bay_concentrated")
        on=build(merge(p,Dict("mass.structural_representation"=>representation)))
        off=build(merge(p,Dict("mass.structural_representation"=>representation,"engines.items"=>Any[])))
        native=native_mass(on,"engine_"*representation);empty=native_mass(off,"bare_"*representation)
        expected=engine_rigid_mass(only(W.engine_records(on)))
        @test native.mass-empty.mass≈expected rtol=2e-12 atol=2e-9
        masses=native.model["CONM2s"]
        @test haskey(masses,string(engine["mass_eid"]))
        @test masses[string(engine["mass_eid"])]["M"]==300.
        push!(records,Dict("wing_mass_representation"=>representation,
            "engine_mass_increment_kg"=>native.mass[1,1]-empty.mass[1,1],
            "rigid_mass_matrix_error"=>norm(native.mass-empty.mass-expected)))
    end

    # Fuel and structural bay masses allocate IDs after the engine elements.
    # Positive fuel fill exercises real CONM2 cards, not just empty bay spiders.
    for representation in ("distributed","bay_concentrated")
        wet=build(merge(p,Dict("mass.structural_representation"=>representation,
            "fuel.enabled"=>true,"fuel.start_rib"=>2,"fuel.end_rib"=>3,"loads.fuel_percent"=>60.)))
        native=native_mass(wet,"engine_with_fuel_"*representation)
        fuel=W.fuel_mass_state(wet);totals=W.weights_payload(wet)["totals"]
        fuel_ids=Int[bay["conm2_eid"] for bay in fuel["bays"] if bay["mass_kg"]>0]
        structural_ids=representation=="bay_concentrated" ? Int[W.structural_conm2_eid(wet,sp) for sp in wet.fuel_rbe3] : Int[]
        engine_ids=W.engine_element_ids(wet)
        allocated=vcat(engine_ids,[sp.eid for sp in wet.fuel_rbe3],fuel_ids,structural_ids)
        @test fuel["mass_kg"]>0
        @test length(unique(allocated))==length(allocated)
        masses=native.model["CONM2s"]
        @test length(masses)==1+length(fuel_ids)+length(structural_ids)
        @test all(haskey(masses,string(id)) for id in vcat(fuel_ids,structural_ids))
        @test masses[string(only(W.engine_records(wet))["mass_eid"])]["M"]==300.
        expected_point_mass=300.0+fuel["mass_kg"]+(representation=="bay_concentrated" ? totals["structure_mass_kg"] : 0.)
        @test sum(card["M"] for card in values(masses))≈expected_point_mass rtol=2e-12
        @test totals["deck_mass_kg"]≈totals["structure_mass_kg"]+fuel["mass_kg"]+300. rtol=2e-12
        @test all(native.mass[i,i]≈totals["deck_mass_kg"] for i in 1:3)
        push!(records,Dict("wing_mass_representation"=>representation,"fuel_enabled"=>true,
            "fuel_mass_kg"=>fuel["mass_kg"],"engine_mass_kg"=>300.,"conm2_count"=>length(masses),
            "all_engine_and_bay_element_ids_unique"=>true,"native_total_mass_kg"=>native.mass[1,1]))
    end

    # Different selected cases share engine mass but have independent signs,
    # accelerations, and one multiplication by the load multiplier.
    p["loads.cases"]=Any[
        Dict("id"=>2,"label"=>"Reversed acceleration","load_factor"=>.7,"fuel_accel_z"=>3.,"fuel_accel_x"=>-.4),
        Dict("id"=>3,"label"=>"Inertia off","structure_inertia"=>false),
        Dict("id"=>4,"label"=>"Zero acceleration","fuel_accel_x"=>0.,"fuel_accel_y"=>0.,"fuel_accel_z"=>0.)]
    multicase=build(p)
    for spec in W.load_case_specs(multicase.params)
        model=W.model_for_load_case(multicase,spec);loads=W.aerodynamic_loads(model)
        applied=W.routed_applied_loads(model,loads);accel=collect(W.structure_acceleration(spec.params))
        engine_loads=W.engine_applied_loads(model)
        @test W.weights_payload(model)["totals"]["engine_mass_kg"]==300.
        if all(iszero,accel)
            @test isempty(engine_loads)
            @test isempty(applied.engine)
        else
            load=only(engine_loads)
            @test load.node==engine["cg_node"]-1
            @test collect(load.force)≈300accel rtol=1e-13
            @test load.moment==(0.,0.,0.)
            target=only(filter(s->s.target_kind=="engine_mass",applied.mass))
            @test target.gid==model.node_ids[engine["cg_node"]]
            @test target.target_rbe3_eid==first(engine["rbe3_eids"]) # CG is now the front-cap RBE3 reference
            @test target.source_forces.engine==load.force
            @test target.source_forces.structure==(0.,0.,0.)
            @test target.position==Tuple(engine["center_of_gravity_m"])
        end
        diagnostics=applied.diagnostics["sources"]["engine"]
        @test diagnostics["force_error_N"]==0.
        @test diagnostics["moment_error_Nm"]==0.
        @test diagnostics["applied_force_N"]≈300accel atol=1e-12
        @test diagnostics["applied_moment_origin_Nm"]≈cross(engine["center_of_gravity_m"],300accel) atol=1e-12
        plots=W.spanwise_load_data(model,loads)
        for scope in (plots["components"],plots["fe_resultants"])
            curve=scope["engine"]
            @test first(curve["shear_z_N"])≈300accel[3] atol=1e-10
            @test last(curve["shear_z_N"])≈0. atol=1e-10
            for key in ("shear_z_N","bending_x_Nm","torque_y_Nm")
                @test scope["total"][key]≈sum(scope[name][key] for name in ("aerodynamic","structure","fuel","engine")) atol=1e-9
                @test first(plots["components"]["total"][key])≈first(plots["fe_resultants"]["total"][key]) rtol=1e-10 atol=1e-9
            end
        end
    end

    # Engine mass survives inertia-off and each exported solution type.
    # Static/preload load decks use identical direct CG FORCE cards.
    for sol in ("101","103","105","106")
        model=build(merge(p,Dict("output.solution"=>sol,"loads.cases"=>Any[])))
        op=native_mass(model,"engine_sol"*sol)
        @test op.model["CONM2s"][string(engine["mass_eid"])]["M"]==300.
        cg=model.node_ids[engine["cg_node"]]
        forces=filter(f->get(f,"G",get(f,"GID",0))==cg,get(op.model,"FORCEs",Any[]))
        @test !isempty(forces)
        @test count(s->s.target_kind=="engine_mass",W.routed_applied_loads(model,W.aerodynamic_loads(model)).mass)==1
    end
    off=build(merge(p,Dict("loads.structure_inertia"=>false,"loads.cases"=>Any[],"output.solution"=>"103")))
    native=native_mass(off,"engine_inertia_off_modal")
    @test native.model["CONM2s"][string(engine["mass_eid"])]["M"]==300.
    @test isempty(W.engine_applied_loads(off))
end
write(joinpath(OUT,"summary.json"),JSON.json(Dict("checks"=>Test.get_test_counts(checks).passes,"mass_checks"=>records)))
println("Engine mass and load assertions: ",Test.get_test_counts(checks))
