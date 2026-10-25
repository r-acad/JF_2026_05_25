# julia --project=. --startup-file=no APPS/JFEM-Boxer/test/engine_thrust_test.jl OUTPUT
using Test, LinearAlgebra, JSON, TOML, WingFEGen, OpenJFEM
const W=WingFEGen
const OUT=abspath(only(ARGS));mkpath(OUT)
thrust(name,value)=Dict("engine"=>name,"thrust_n"=>value)
function thrust_params()
    merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "planform.taper_ratio"=>.8,"airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412",
        "planform.sweep"=>12.,"planform.dihedral"=>3.,"planform.twist_tip"=>-2.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>2,
        "mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>0.,"loads.torque_y"=>0.,
        "loads.load_factor"=>1.5,"loads.structure_inertia"=>false,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"output.solution"=>"101",
        "engines.items"=>Any[
            merge(W.ENGINE_DEFAULTS,Dict("name"=>"Inner engine","x"=>.1,"y"=>.45,"z"=>-.5,
                "mass"=>25.,"length"=>.6,"front_rib"=>2,"aft_rib"=>3,"aft_xc"=>.55)),
            merge(W.ENGINE_DEFAULTS,Dict("name"=>"Outer engine","x"=>.2,"y"=>.7,"z"=>-.7,
                "mass"=>30.,"length"=>.6,"front_rib"=>3,"aft_rib"=>3,"aft_xc"=>.6))],
        "loads.engine_thrust"=>Any[thrust("Inner engine",400.),thrust("Outer engine",250.)]))
end
build(p)=W.build_model(first(W.normalize_params(p)))
force(card)=card["Mag"].*card["Dir"]
function exported(m,name;frozen=nothing)
    path=joinpath(OUT,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m;frozen_load_cases=frozen);end
    path,OpenJFEM.bdf_to_model(path)
end
reports=Any[]
tests=@testset "Named engine thrust and conservative case routing" begin
    p=thrust_params();m=build(p)
    @test W.all_checks_pass(m)
    @test W.normalize_engine_thrust(reverse(p["loads.engine_thrust"]))==p["loads.engine_thrust"]
    for invalid in (Any[thrust("Inner engine",NaN)],Any[thrust("Inner engine",true)],
                    Any[thrust("",1.)],Any[thrust("Inner engine",1.),thrust("Inner engine",2.)],
                    Any[Dict("engine"=>"Inner engine","thrust_n"=>1.,"other"=>2.)])
        @test_throws ArgumentError W.normalize_engine_thrust(invalid)
    end
    orphan=merge(p,Dict("loads.engine_thrust"=>Any[thrust("Deleted engine",1.)]))
    @test_throws r"missing engine.*Deleted engine" W.normalize_params(orphan)
    orphan_case=merge(p,Dict("loads.cases"=>Any[Dict("id"=>2,"engine_thrust"=>Any[thrust("Renamed engine",1.)])]))
    @test_throws r"load case 2.*missing engine" W.normalize_params(orphan_case)
    overflow=merge(p,Dict("loads.engine_thrust"=>Any[thrust("Inner engine",1e308)],"loads.load_factor"=>1e308))
    @test_throws ArgumentError W.normalize_params(overflow)
    # TOML round trip includes both base and override arrays, preserving signs.
    p["loads.cases"]=Any[
        Dict("id"=>2,"label"=>"Asymmetric reverse thrust","load_factor"=>.7,
            "engine_thrust"=>Any[thrust("Outer engine",-80.)]),
        Dict("id"=>3,"label"=>"Inherit thrust","load_factor"=>2.),
        Dict("id"=>4,"label"=>"Explicit engines off","engine_thrust"=>Any[],"lift_total"=>1.),
        Dict("id"=>5,"label"=>"Combined inertia and thrust","structure_inertia"=>true,
            "fuel_accel_x"=>.2,"fuel_accel_y"=>-.3,"fuel_accel_z"=>-2.),
        Dict("id"=>6,"label"=>"Negative multiplier","load_factor"=>-1.)]
    normalized=first(W.normalize_params(p));toml=W.params_to_toml(normalized)
    roundtrip=first(W.normalize_params(W.flatten_toml(TOML.parse(toml))))
    @test roundtrip["loads.engine_thrust"]==normalized["loads.engine_thrust"]
    @test roundtrip["loads.cases"]==normalized["loads.cases"]
    m=build(p);mass=W.weights_payload(m)["totals"]["deck_mass_kg"]
    expected_unscaled=Dict(1=>[-400.,-250.],2=>[0.,80.],3=>[-400.,-250.],4=>[0.,0.],5=>[-400.,-250.],6=>[-400.,-250.])
    expected_forces=Dict{Int,Dict{Int,Vector{Float64}}}()
    for spec in W.load_case_specs(m.params)
        cm=W.model_for_load_case(m,spec);aero=W.aerodynamic_loads(cm);applied=W.routed_applied_loads(cm,aero)
        records=W.engine_applied_loads(cm);accel=collect(W.structure_acceleration(spec.params))
        expected=Dict{Int,Vector{Float64}}();expectedF=zeros(3);expectedM=zeros(3)
        @test W.weights_payload(cm)["totals"]["deck_mass_kg"]==mass
        for (i,e) in enumerate(W.engine_records(cm))
            f=e["mass_kg"].*accel+[expected_unscaled[spec.id][i]*spec.params["loads.load_factor"],0.,0.]
            gid=cm.node_ids[e["cg_node"]];expected[gid]=f;expectedF+=f;expectedM+=cross(e["center_of_gravity_m"],f)
            actual=filter(s->s.gid==gid,records)
            if all(iszero,f)
                @test isempty(actual)
            else
                r=only(actual);@test collect(r.force)≈f atol=1e-12
                @test r.name==e["name"]
                @test collect(r.thrust_force)≈[expected_unscaled[spec.id][i]*spec.params["loads.load_factor"],0.,0.] atol=1e-12
                @test collect(r.inertia_force)≈e["mass_kg"].*accel atol=1e-12
            end
        end
        expected_forces[spec.id]=expected
        diagnostics=applied.diagnostics["sources"]["engine"]
        @test diagnostics["applied_force_N"]≈expectedF atol=1e-10
        @test diagnostics["applied_moment_origin_Nm"]≈expectedM atol=1e-10
        @test diagnostics["force_error_N"]==diagnostics["moment_error_Nm"]==0.
        payload=W.load_payload(aero;model=cm)
        @test length(payload["engine_loads"])==length(records)
        @test all(!s["follower_forces"] for s in payload["engine_stations"])
        @test sum((s["force"] for s in payload["engine_stations"]);init=zeros(3))≈expectedF atol=1e-10
        plot=payload["spanwise"]
        @test first(plot["components"]["engine"]["torque_y_Nm"])≈first(plot["fe_resultants"]["engine"]["torque_y_Nm"]) atol=1e-10
        push!(reports,Dict("case"=>spec.id,"force_N"=>expectedF,"origin_moment_Nm"=>expectedM,
            "mass_kg"=>mass,"thrust_records"=>payload["engine_loads"]))
    end
    # Same loads reach static, modal deck load records, buckling preloads and nonlinear cases.
    for sol in ("101","103","105","106")
        sm=build(merge(p,Dict("output.solution"=>sol)));path,native=exported(sm,"engine_thrust_sol"*sol)
        @test length(native["CONM2s"])==2
        @test sum(card["M"] for card in values(native["CONM2s"]))==55.
        for (id,expected) in expected_forces,(gid,vector) in expected
            cards=filter(c->c["SID"]==id&&c["GID"]==gid,native["FORCEs"])
            @test sum(force.(cards);init=zeros(3))≈vector atol=1e-10
            @test all(get(c,"FLLW","")!="ROT" for c in cards)
        end
        if sol=="105"
            subs=native["CASE_CONTROL"]["SUBCASES"]
            for id in keys(expected_forces)
                @test subs[2id-1]["LOAD"]==id
                @test subs[2id]["STATSUB"]==2id-1
            end
        end
    end
    # Sensitivity's frozen-aerodynamic export uses the chosen case's thrust.
    spec=W.load_case_specs(m.params)[2];sp=deepcopy(spec.params);sp["loads.cases"]=Any[]
    baseline=W.sensitivity_model(m,sp);aero=W.aerodynamic_loads(baseline)
    _,native=exported(baseline,"sensitivity_thrust_baseline";frozen=[(id=1,label=spec.label,params=sp,loads=aero)])
    for (gid,vector) in expected_forces[2]
        cards=filter(c->c["SID"]==1&&c["GID"]==gid,native["FORCEs"])
        @test sum(force.(cards);init=zeros(3))≈vector atol=1e-10
    end
    # Disabling an engine retains its entered thrust but removes its physical force/mass.
    off=thrust_params();off["engines.items"][2]["enabled"]=false;om=build(off)
    @test length(W.engine_records(om))==1
    @test only(W.engine_applied_loads(om)).name=="Inner engine"
    @test length(om.params["loads.engine_thrust"])==2
    # No thrust defaults and explicit zeros produce the identical model/mass.
    zero=merge(thrust_params(),Dict("loads.lift_total"=>1.,"loads.engine_thrust"=>Any[]));zm=build(zero)
    explicit=build(merge(zero,Dict("loads.engine_thrust"=>Any[thrust("Inner engine",0.),thrust("Outer engine",0.)])))
    @test isempty(W.engine_applied_loads(zm))&&isempty(W.engine_applied_loads(explicit))
    @test zm.xyz==explicit.xyz
    @test zm.xyz[1:3zm.n_struct]==m.xyz[1:3m.n_struct]
    @test W.weights_payload(zm)["totals"]["deck_mass_kg"]==mass
    # Solve the actual two-engine thrust-only structure and balance the full wrench.
    stat=build(thrust_params());path,_=exported(stat,"engine_thrust_static_equilibrium")
    text=replace(read(path,String),"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0.")
    write(path,text);result=OpenJFEM.solve_model(OpenJFEM.bdf_to_model(path));case=only(result["subcases"])
    @test case["solver_diagnostics"]["linear_solver"]["regularization_shift"]==0
    @test case["solver_diagnostics"]["bc_partition"]["post_factorization_singular_dofs"]==0
    reactionF=zeros(3);reactionM=zeros(3)
    for rr in case["spc_forces"]
        i=findfirst(==(rr["grid_id"]),stat.node_ids);f=[rr[k] for k in ("t1","t2","t3")]
        reactionF+=f;reactionM+=[rr[k] for k in ("r1","r2","r3")]+cross(stat.xyz[3i-2:3i],f)
    end
    loads=W.engine_applied_loads(stat);F=sum((collect(s.force) for s in loads);init=zeros(3))
    M=sum((cross(stat.xyz[3s.node+1:3s.node+3],collect(s.force)) for s in loads);init=zeros(3))
    @test reactionF≈-F atol=1e-6
    @test reactionM≈-M atol=1e-6
    push!(reports,Dict("case"=>"native_static_equilibrium","force_residual_N"=>norm(reactionF+F),
        "moment_residual_Nm"=>norm(reactionM+M)))
end
counts=Test.get_test_counts(tests)
write(joinpath(OUT,"engine_thrust_summary.json"),JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports)))
