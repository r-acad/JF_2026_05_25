# From the repository root:
# julia --project=. APPS/JFEM-Boxer/test/nonstructural_mass_test.jl <scratch-output-directory>
# Checks exported NSM against native mass assembly and existing analytic
# property/load derivatives. Generated decks and the summary stay in scratch.
using Test, LinearAlgebra, JSON
using WingFEGen, OpenJFEM
const W=WingFEGen
const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)

function native_model(m,name)
    path=joinpath(out,name*".bdf")
    open(path,"w") do io
        W.write_deck(IOContext(io,:full_precision=>true),m)
    end
    model=N.bdf_to_model(path)
    ids=sort(parse.(Int,collect(keys(model["GRIDs"]))))
    id_map=Dict(id=>i for (i,id) in enumerate(ids))
    X=reduce(vcat,[transpose(Float64.(model["GRIDs"][string(id)]["X"])) for id in ids])
    node_R=[Matrix{Float64}(I,3,3) for _ in ids]
    (;model,id_map,X,node_R,ndof=6length(ids),load_id=nothing)
end
mass_matrix(op)=N.Solver.assemble_mass(op.model,op.id_map,op.X,op.node_R,op.ndof)
function bar_only_mass(op,g)
    model=deepcopy(op.model)
    model["CBARs"]=Dict(string(first(g.eids))=>model["CBARs"][string(first(g.eids))])
    for key in ("CSHELLs","CBEAMs","CRODs","CONRODs","CONM2s","CMASSs","CONM1s")
        model[key]=Dict()
    end
    mass_matrix(merge(op,(;model)))
end

tests=@testset "Non-structural surface and line mass" begin
    # Raw JSON and BDF import must both retain a laminate's added surface mass.
    raw=Dict("case_control"=>Dict("SOL"=>103),"bulk_data"=>Dict(
        "MAT1"=>Dict("1"=>Dict("MID"=>1,"E"=>70e9,"NU"=>.3,"RHO"=>2700.)),
        "PCOMP"=>Dict("10"=>Dict("PID"=>10,"NSM"=>2.5,
            "PLIES"=>[Dict("MID"=>1,"T"=>.01,"THETA"=>0.)]))))
    laminate=N.build_model_from_json(raw)
    @test laminate["PSHELLs"]["10"]["NSM"]==2.5
    raw["bulk_data"]["PCOMP"]["10"]["NSM"]=0.
    unweighted=N.build_model_from_json(raw)
    for key in ("Cm","Bmb","Cb","Cs")
        @test laminate["PSHELLs"]["10"][key]==unweighted["PSHELLs"]["10"][key]
    end
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.65,
        "planform.sweep"=>18.,"planform.twist_tip"=>-5.,"box.end_eta"=>1.,"box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.1,"mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "fuel.enabled"=>false,"leading_edge.enabled"=>true,"loads.cases"=>Any[],
        "aero.enabled"=>false,"loads.structure_inertia"=>true,"loads.fuel_accel_x"=>.3,
        "loads.fuel_accel_y"=>-.2,"loads.fuel_accel_z"=>-1.,"output.solution"=>"101"))
    # Exercise PCOMP and PSHELL together, plus T/BAR PBARL and run-out PBAR.
    first(p["materials.shells"])["kind"]="sandwich"
    m0=W.build_model(W.normalize_params(p)[1])
    p=deepcopy(m0.params)
    for (i,(component,_,unit)) in enumerate(W.NONSTRUCTURAL_COMPONENTS)
        p["nonstructural."*component]=i*(unit=="kg/m2" ? .7 : .13)
    end
    m=W.build_model(W.normalize_params(p)[1])
    @test m.node_ids==m0.node_ids
    @test m.xyz==m0.xyz
    @test all(a.conn==b.conn for (a,b) in zip(m.groups,m0.groups))
    weights0=W.weights_payload(m0);weights=W.weights_payload(m)
    expected=0.
    for g in m.groups
        measure=sum((g.kind===:bar ? norm(collect(q[2].-q[1])) : W.weight_shell_area(q)
            for q in (W.element_points(m,g,e) for e in 1:W.n_elements(g)));init=0.)
        expected+=measure*W.nonstructural_mass_density(p,g.pid)
        props=W.element_properties(m,g)
        key=g.kind===:bar ? "nonstructural_mass_kg_m" : "nonstructural_mass_kg_m2"
        @test props[key]==W.nonstructural_mass_density(p,g.pid)
    end
    @test expected>0
    @test weights["totals"]["nonstructural_mass_kg"]≈expected rtol=1e-12
    @test weights["totals"]["structure_mass_kg"]-weights0["totals"]["structure_mass_kg"]≈expected rtol=1e-12
    @test weights["totals"]["material_mass_kg"]≈weights0["totals"]["structure_mass_kg"] rtol=1e-12
    @test sum(r["mass_kg"] for r in W.structural_inertia_payload(m))≈weights["totals"]["structure_mass_kg"] rtol=1e-11
    f0=sum(collect(row.force) for row in W.structure_applied_loads(m0))
    f1=sum(collect(row.force) for row in W.structure_applied_loads(m))
    @test f1-f0≈expected.*collect(W.structure_acceleration(p)) rtol=1e-11
    # The cache must track a mass edit even if nodes and groups are reused.
    changed=deepcopy(p);changed["nonstructural.stringer"]+=.5
    samegeometry=W.sensitivity_model(m,changed)
    @test sum(W.structural_mass_data(samegeometry).nodal_mass)>sum(W.structural_mass_data(m).nodal_mass)
    roundtrip=joinpath(out,"nonstructural.toml");write(roundtrip,W.params_to_toml(p));restored=W.read_input(roundtrip)
    for (component,_,_) in W.NONSTRUCTURAL_COMPONENTS
        key="nonstructural."*component
        @test restored[key]==p[key]
        bad=deepcopy(p);bad[key]=-1.;@test_throws ArgumentError W.normalize_params(bad)
    end
    @test W.nonstructural_mass_density(p,W.PID_AERO)==0.

    op0=native_model(m0,"material_only");op=native_model(m,"distributed_mass")
    for (name,props) in (("PSHELLs",op.model["PSHELLs"]),("PBARLs",op.model["PBARLs"]))
        for (pid,prop) in props
            @test prop["NSM"]≈W.nonstructural_mass_density(p,parse(Int,pid))
            # NSM must not alter any of the stiffness-defining card fields.
            base=deepcopy(op0.model[name][pid]);added=deepcopy(prop)
            pop!(base,"NSM",nothing);pop!(added,"NSM",nothing)
            @test base==added
        end
    end
    M0=mass_matrix(op0);M=mass_matrix(op)
    for axis in 1:3
        translation=zeros(op.ndof);translation[axis:6:end].=1
        @test dot(translation,(M-M0)*translation)≈expected rtol=1e-10
    end
    # Exact existing structural-property derivatives remain correct with NSM.
    g=first(filter(g->g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_STRINGER,m.groups))
    d=Dict("dimensions"=>[0.,1.,0.,0.]);h=1e-7
    plus=deepcopy(p);minus=deepcopy(p)
    plus["properties.stringer_height"]+=h;minus["properties.stringer_height"]-=h
    opplus=native_model(W.sensitivity_model(m,plus),"height_plus")
    opminus=native_model(W.sensitivity_model(m,minus),"height_minus")
    for coupled in (false,true)
        for x in (op,opplus,opminus);x.model["PARAM_COUPMASS"]=coupled;end
        exact=W.sensitivity_analytic_bar(N,op,m,g,1,d)
        @test exact.Me≈Matrix(bar_only_mass(op,g)[exact.dofs,exact.dofs]) rtol=1e-11
        fd=(bar_only_mass(opplus,g)-bar_only_mass(opminus,g))/(2h)
        @test exact.dMe≈Matrix(fd[exact.dofs,exact.dofs]) rtol=1e-7 atol=1e-9
    end
    vars=W.sensitivity_catalog(m)["variables"]
    for id in ("properties.t_skin_lower","materials.shells#upper_skin#core_thickness")
        variable=only(filter(d->d["id"]==id,vars));step=1e-7
        plus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),variable,variable["value"]+step))
        minus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),variable,variable["value"]-step))
        ap=native_model(plus,"shell_plus_"*replace(id,r"[^a-zA-Z]"=>"_"))
        am=native_model(minus,"shell_minus_"*replace(id,r"[^a-zA-Z]"=>"_"))
        ap.model["PARAM_COUPMASS"]=true;am.model["PARAM_COUPMASS"]=true
        directions=W.sensitivity_analytic_property_directions(m,variable)
        exact=W.sensitivity_analytic_shell_mass(N,op,directions)
        modal_mass(x)=N.Solver.assemble_modal_mass(x.model,x.id_map,x.X,x.node_R,x.ndof)
        fd=(modal_mass(ap)-modal_mass(am))/(2step)
        @test norm(exact-fd)<=1e-7max(norm(fd),1.)
    end
    # Body-load moments include fixed NSM moving with dimension-dependent offsets.
    variable=only(filter(d->d["id"]=="properties.stringer_height",vars))
    directions=W.sensitivity_analytic_property_directions(m,variable)
    for (pid,dir) in directions
        group=first(filter(g->g.pid==pid,m.groups))
        beam=W.sensitivity_analytic_bar(N,op,m,group,1,dir)
        dir["area"]=beam.section.darea;dir["density"]=dir["rho"];dir["offset_y"]=beam.section.doffset_y
    end
    tangent=W.sensitivity_analytic_load_tangent(m,directions)
    @test all(isfinite,tangent.force)
    function resultant(model)
        force=zeros(3);moment=zeros(3)
        for row in W.structure_applied_loads(model)
            xyz=model.xyz[3row.node+1:3row.node+3]
            force.+=row.force;moment.+=collect(row.moment)+cross(xyz,collect(row.force))
        end
        vcat(force,moment)
    end
    step=1e-7
    mp=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),variable,variable["value"]+step))
    mm=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),variable,variable["value"]-step))
    exact=zeros(6)
    for node in eachindex(m.node_ids)
        force=tangent.force[6node-5:6node-3];moment=tangent.force[6node-2:6node]
        exact[1:3].+=force;exact[4:6].+=moment+cross(m.xyz[3node-2:3node],force)
    end
    @test exact≈(resultant(mp)-resultant(mm))/(2step) rtol=1e-7 atol=1e-7
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
