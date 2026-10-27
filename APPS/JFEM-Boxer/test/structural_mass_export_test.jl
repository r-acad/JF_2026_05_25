# From the repository root:
# julia --startup-file=no --project=. APPS/JFEM-Boxer/test/structural_mass_export_test.jl OUTPUT
# Native mass assembly checks; all generated evidence stays in the explicit directory.
using Test, LinearAlgebra, JSON
using WingFEGen, OpenJFEM
const W=WingFEGen
const N=OpenJFEM
length(ARGS)==1||error("Usage: structural_mass_export_test.jl OUTPUT")
const OUT=abspath(only(ARGS));mkpath(OUT)

function native_mass(m,name)
    path=joinpath(OUT,name*".bdf")
    open(path,"w") do io
        W.write_deck(IOContext(io,:full_precision=>true),m)
    end
    model=N.bdf_to_model(path)
    ids=sort(parse.(Int,collect(keys(model["GRIDs"]))))
    id_map=Dict(id=>i for (i,id) in enumerate(ids))
    X=reduce(vcat,[transpose(Float64.(model["GRIDs"][string(id)]["X"])) for id in ids])
    R=[Matrix{Float64}(I,3,3) for _ in ids];ndof=6length(ids)
    M=N.Solver.assemble_mass(model,id_map,X,R,ndof)
    (;model,ids,id_map,X,R,ndof,M)
end

function rigid_motion(op)
    Q=zeros(op.ndof,6)
    for (i,_) in enumerate(op.ids)
        dofs=6(i-1).+(1:6)
        Q[dofs[1:3],1:3].=Matrix{Float64}(I,3,3)
        Q[dofs[1:3],4:6].=-N.Solver.skew3(op.X[i,:])
        Q[dofs[4:6],4:6].=Matrix{Float64}(I,3,3)
    end
    Q
end

function moment_matrix(rows)
    result=zeros(6,6)
    for row in rows
        mass=row["mass_kg"];c=row["center_of_gravity_m"];S=N.Solver.skew3(c)
        inertia=reduce(vcat,[transpose(r) for r in row["inertia_kg_m2"]])
        result[1:3,1:3].+=mass.*Matrix{Float64}(I,3,3)
        result[1:3,4:6].-=mass.*S
        result[4:6,1:3].+=mass.*S
        result[4:6,4:6].+=inertia+mass.*(dot(c,c).*Matrix{Float64}(I,3,3)-c*c')
    end
    result
end

tests=@testset "Structural bay CONM2 export and native mass" begin
    p=W.default_params()
    @test p["mass.structural_representation"]=="distributed"
    legacy=copy(p);delete!(legacy,"mass.structural_representation")
    @test W.normalize_params(legacy)[1]["mass.structural_representation"]=="distributed"
    bad=copy(p);bad["mass.structural_representation"]="invalid"
    @test_throws ArgumentError W.normalize_params(bad)
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.65,
        "planform.sweep"=>18.,"planform.twist_tip"=>-5.,"box.end_eta"=>1.,"box.rib_pitch"=>.3,
        # Two span cells keep the tapered leading-edge strips below the
        # application's 15:1 edge-ratio gate; mass checks use the same geometry.
        "box.stringer_pitch"=>.15,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "fuel.enabled"=>false,"leading_edge.enabled"=>true,"loads.cases"=>Any[],
        "aero.enabled"=>false,"loads.structure_inertia"=>false,"output.solution"=>"103"))
    first(p["materials.shells"])["kind"]="sandwich"
    for (i,(component,_,unit)) in enumerate(W.NONSTRUCTURAL_COMPONENTS)
        p["nonstructural."*component]=i*(unit=="kg/m2" ? .7 : .13)
    end
    distributed=W.build_model(W.normalize_params(p)[1]);native_d=native_mass(distributed,"distributed")
    p["mass.structural_representation"]="bay_concentrated"
    m=W.build_model(W.normalize_params(p)[1]);native=native_mass(m,"bay_concentrated")
    nbays=length(m.grid.ribs)-1;bays=W.structural_bay_mass_properties(m)
    @test length(m.fuel_rbe3)==nbays==length(bays)
    @test [sp.start_rib for sp in m.fuel_rbe3]==collect(1:nbays)
    @test m.xyz[1:3m.n_struct]==distributed.xyz[1:3distributed.n_struct]
    @test all(a.conn==b.conn&&a.eids==b.eids for (a,b) in zip(m.groups,distributed.groups))
    @test W.model_material_definitions(m)==W.model_material_definitions(distributed)
    @test W.model_property_definitions(m)==W.model_property_definitions(distributed)
    @test length(native.model["CONM2s"])==nbays
    @test Set(parse.(Int,collect(keys(native.model["CONM2s"]))))==Set(W.structural_conm2_eid(m,sp) for sp in m.fuel_rbe3)
    for (key,field) in (("MATs","RHO"),("PSHELLs","NSM"),("PBARs","NSM"),("PBARLs","NSM"))
        for (id,prop) in get(native.model,key,Dict())
            @test get(prop,field,0.)==0.
            a=deepcopy(prop);b=deepcopy(native_d.model[key][id]);pop!(a,field,nothing);pop!(b,field,nothing)
            @test a==b
        end
    end
    # No hidden distributed mass remains after moving material and NSM mass.
    without=deepcopy(native.model);without["CONM2s"]=Dict()
    @test iszero(norm(N.Solver.assemble_mass(without,native.id_map,native.X,native.R,native.ndof)))
    Q=rigid_motion(native);Qd=rigid_motion(native_d)
    G=Q'*native.M*Q;Gd=Qd'*native_d.M*Qd
    @test G≈moment_matrix(bays) rtol=1e-11 atol=1e-10
    @test G[1:3,1:3]≈Gd[1:3,1:3] rtol=1e-11
    @test G[1,1]≈W.weights_payload(m)["totals"]["structure_mass_kg"] rtol=1e-11
    @test eigmin(Symmetric(G))>0
    path=joinpath(OUT,"roundtrip.toml");write(path,W.params_to_toml(p))
    @test W.read_input(path)["mass.structural_representation"]=="bay_concentrated"
    write(joinpath(OUT,"input_schema.json"),JSON.json(W.schema_payload(m.params,path)))

    # Fuel only in an interior bay must attach by physical bay index, not list position.
    wet=deepcopy(p);merge!(wet,Dict("fuel.enabled"=>true,"fuel.start_rib"=>2,"fuel.end_rib"=>3,"loads.fuel_percent"=>60.))
    wm=W.build_model(W.normalize_params(wet)[1]);wn=native_mass(wm,"structural_plus_fuel")
    fuel=W.fuel_mass_state(wm);@test length(fuel["bays"])==1
    f=only(fuel["bays"]);sp=only(filter(s->s.start_rib==2,wm.fuel_rbe3))
    @test f["reference_grid"]==wm.node_ids[sp.ref]
    @test f["rbe3_eid"]==sp.eid
    @test f["conm2_eid"]==sp.mass_eid
    @test length(wn.model["CONM2s"])==nbays+1
    Qw=rigid_motion(wn);Gw=Qw'*wn.M*Qw
    @test Gw≈moment_matrix(vcat(W.structural_bay_mass_properties(wm),fuel["bays"])) rtol=1e-11 atol=1e-10
    @test Gw[1,1]≈G[1,1]+fuel["mass_kg"] rtol=1e-11
    @test all(sp->W.structural_conm2_eid(wm,sp)!=sp.mass_eid,wm.fuel_rbe3)

    # Optional disconnected aero loft is separate; its previous density is retained.
    aero=deepcopy(p);aero["output.include_aero_shells"]=true
    am=W.build_model(W.normalize_params(aero)[1]);an=native_mass(am,"with_optional_aero")
    ap=an.model["PSHELLs"][string(W.PID_AERO)]
    @test an.model["MATs"][string(ap["MID"])]["RHO"]≈W.material_definition(p,W.MID_STRUCT)["rho"]
    @test isempty(intersect(Set(keys(an.model["CSHELLs"])),Set(keys(an.model["CONM2s"]))))
    Qa=rigid_motion(an);@test (Qa'*an.M*Qa)[1,1]>G[1,1]
    write(joinpath(OUT,"summary.json"),JSON.json(Dict("physical_bays"=>nbays,"structural_mass_kg"=>G[1,1],
        "fuel_mass_kg"=>fuel["mass_kg"],"structural_rigid_mass_matrix"=>G,"combined_rigid_mass_matrix"=>Gw,
        "default"=>"distributed","representation"=>"bay_concentrated")))
end
println("Native mass export assertions: ",Test.get_test_counts(tests))
