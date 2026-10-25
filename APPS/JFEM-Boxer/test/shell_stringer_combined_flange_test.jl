using Test, LinearAlgebra, JSON, WingFEGen, OpenJFEM
const W=WingFEGen;const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)
function fixture_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>5.,"planform.dihedral"=>2.,"planform.twist_tip"=>-1.,"box.end_eta"=>1.,
        "box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>1,
        "mesh.elements_between_stringers"=>1,"mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>1,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,"fuel.enabled"=>false,"leading_edge.enabled"=>false,
        "aero.enabled"=>false,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "output.solution"=>"101","output.n_modes"=>3,"stringers.model"=>"shell"))
    p
end
function build(p);W.build_model(first(W.normalize_params(p)));end
function export_model(m,name)
    path=joinpath(out,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    path,N.bdf_to_model(path)
end
function flange_properties(m)
    filter(row->get(row,"combined_flange",false),W.model_property_definitions(m))
end
function browser_fixture(m,name)
    path=joinpath(out,"frontend",name);mkpath(path)
    write(joinpath(path,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
    write(joinpath(path,"schema.json"),JSON.json(W.schema_payload(m.params,"combined_flange_fixture.toml")))
    write(joinpath(path,"params.json"),JSON.json(m.params))
end
results=Any[]
tests=@testset "Combined flange footprint, laminate, eccentricity and analysis" begin
    p=fixture_params();m=build(p);rows=W.stiffened_panels_payload(m);props=flange_properties(m)
    @test !isempty(props)
    @test W.all_checks_pass(m)
    @test all(row["type"]=="PSHELL" for row in props)
    @test all(row["thickness_m"]≈row["skin_thickness_m"]+p["properties.stringer_flange_thickness"] for row in props)
    faces=[Tuple(sort(group.conn[n*(e-1)+1:n*e])) for group in m.groups
        if W.component_base_pid(group.pid) in (W.PID_SKIN_UPPER,W.PID_SKIN_LOWER,W.PID_STRINGER_FLANGE)
        for n in (group.kind===:tria ? 3 : 4,) for e in eachindex(group.eids)]
    @test length(unique(faces))==length(faces)
    # A panel's flange spans both adjacent skin properties, and the thinner
    # skin wins even when its PID belongs to the neighboring panel.
    panel=first(filter(row->length(W.shell_stringer_skin_sources(m.params,row["stringer_flange_pid"]))==2,rows["panels"]))
    source=W.shell_stringer_skin_sources(m.params,panel["stringer_flange_pid"])
    @test length(source)==2
    keybyid=Dict(row["shell_pid"]=>row["key"] for row in rows["panels"])
    # Establish the thin local value as the permitted family minimum first.
    minimum_key=panel["skin"]=="upper" ? "properties.t_skin_upper" : "properties.t_skin_lower"
    nominal_skin_thickness=p[minimum_key];p[minimum_key]=.0015
    p["properties.panels"]=[Dict("key"=>keybyid[s["pid"]],"layout_token"=>rows["layout_token"],
        "skin"=>Dict("thickness"=>i==1 ? .005 : .0015)) for (i,s) in enumerate(source)]
    # Preserve untouched neighbors so the selected thin skin is a unique
    # section minimum, as required by the analytic derivative assertions.
    selected_keys=Set(row["key"] for row in p["properties.panels"])
    for row in rows["panels"]
        row["skin"]==panel["skin"]&&!(row["key"] in selected_keys)||continue
        push!(p["properties.panels"],Dict("key"=>row["key"],"layout_token"=>rows["layout_token"],
            "skin"=>Dict("thickness"=>nominal_skin_thickness)))
    end
    changed=build(p);combined=W.shell_material_definition(changed.params,panel["stringer_flange_pid"])
    @test combined["underlying_skin_pid"]==last(source)["pid"]
    @test combined["skin_thickness_m"]==.0015
    @test combined["thickness_m"]≈.0015+p["properties.stringer_flange_thickness"]
    @test W.all_checks_pass(changed)
    # Shared thickness directions are smooth at equal skins. Independent
    # tied-panel directions are not falsely advertised as exact derivatives.
    catalog=W.sensitivity_catalog(m)
    shared=only(filter(d->d["id"]=="properties.t_skin_lower",catalog["variables"]))
    @test any(W.component_base_pid(pid)==W.PID_STRINGER_FLANGE for pid in shared["pids"])
    tied_id="properties.panels#$(keybyid[first(source)["pid"]])#skin#thickness"
    @test !any(d->d["id"]==tied_id,catalog["variables"])
    unique_catalog=W.sensitivity_catalog(changed)
    thin_id="properties.panels#$(keybyid[last(source)["pid"]])#skin#thickness"
    thin=only(filter(d->d["id"]==thin_id,unique_catalog["variables"]))
    @test panel["stringer_flange_pid"] in thin["pids"]
    directions=W.sensitivity_analytic_property_directions(changed,thin)
    @test directions[panel["stringer_flange_pid"]]["thickness"]==1.
    @test directions[panel["stringer_flange_pid"]]["areal_mass"]≈p["material.rho"]
    # Source skin NSM moves to the combined section exactly once.
    p=fixture_params();p["nonstructural.upper_skin"]=.7;p["nonstructural.lower_skin"]=.9
    nsm=build(p)
    expected=sum(W.weight_shell_area(W.element_points(nsm,g,e))*W.shell_material_definition(nsm.params,g.pid)["nonstructural_mass_kg_m2"]
        for g in nsm.groups if g.kind!==:bar for e in eachindex(g.eids))
    @test W.weights_payload(nsm)["totals"]["nonstructural_mass_kg"]≈expected
    @test all(row["nonstructural_mass_kg_m2"] in (.7,.9) for row in flange_properties(nsm))
    # Different materials retain separate plies. Offset direction is inward
    # on both skins; the outer skin face stays at +skin thickness/2.
    p=fixture_params();only(filter(r->r["component"]=="stringer",p["materials.bars"]))["material"]=2
    p["stringers.shell_offsets"]=true;mixed=build(p)
    for row in flange_properties(mixed)
        @test row["type"]=="PCOMP"
        @test [ply["material_id"] for ply in row["plies"]]==[2,1]
        @test row["z0_m"]≈-row["skin_thickness_m"]/2-row["added_flange_thickness_m"]
        @test row["z_top_m"]≈row["skin_thickness_m"]/2
        @test row["shell_offset_m"]<0
    end
    path,native=export_model(mixed,"mixed_offset")
    @test native["PARAM_COUPMASS"]==1
    @test N.Solver.sol103_shell_mass_formulation(native)==:coupled_consistent
    for row in flange_properties(mixed)
        prop=native["PSHELLs"][string(row["pid"])]
        @test prop["PCOMP_Z0"]≈row["z0_m"]
        @test prop["TYPE"]=="PCOMP_CLT"
        @test prop["Bmb"]!==nothing&&norm(prop["Bmb"])>0
    end
    ids=sort(parse.(Int,collect(keys(native["GRIDs"]))))
    index=Dict(id=>i for (i,id) in enumerate(ids));xyz=reduce(vcat,[transpose(Float64.(native["GRIDs"][string(id)]["X"])) for id in ids])
    matrix=N.Solver.assemble_mass(native,index,xyz,[Matrix{Float64}(I,3,3) for _ in ids],6length(ids))
    rigid=zeros(6length(ids),6)
    for i in eachindex(ids)
        rigid[6i-5:6i-3,1:3].=Matrix{Float64}(I,3,3)
        rigid[6i-5:6i-3,4:6].=-N.Solver.skew3(xyz[i,:]);rigid[6i-2:6i,4:6].=Matrix{Float64}(I,3,3)
    end
    moments=[W.structural_element_mass_moments(mixed,g,e) for g in mixed.groups for e in eachindex(g.eids)]
    mass=sum(v.mass for v in moments);first_moment=sum(v.first for v in moments);second=sum(v.second for v in moments)
    expected_mass=zeros(6,6);expected_mass[1:3,1:3].=mass*Matrix{Float64}(I,3,3)
    expected_mass[1:3,4:6].=-N.Solver.skew3(first_moment);expected_mass[4:6,1:3].=N.Solver.skew3(first_moment)
    expected_mass[4:6,4:6].=tr(second)*Matrix{Float64}(I,3,3)-second
    # This export explicitly selects consistent mass, retaining the nonzero
    # laminate first density moment as well as the actual shell centroid.
    @test (rigid'*matrix*rigid)[1:3,:]≈expected_mass[1:3,:] rtol=1e-10 atol=1e-10
    # The generated laminate consists solely of isotropic plies, so their
    # angle is preserved exactly in the shared skin-aligned material frame.
    for component in ("upper_skin","lower_skin")
        assignment=only(filter(r->r["component"]==component,p["materials.shells"]))
        assignment["kind"]="sandwich";assignment["face_thickness"]=.0004;assignment["core_thickness"]=.002
    end
    push!(p["materials.shells"],Dict("component"=>"stringer_flange","kind"=>"sandwich","material"=>2,
        "face_material"=>2,"core_material"=>3,"face_thickness"=>.0003,"core_thickness"=>.1))
    laminate=build(p)
    for row in flange_properties(laminate)
        @test length(row["plies"])==6
        @test [ply["material_id"] for ply in row["plies"]]==[2,3,2,1,3,1]
        @test all(ply["angle_deg"]==0. for ply in row["plies"])
        @test sum(ply["thickness_m"] for ply in row["plies"][1:3])≈p["properties.stringer_flange_thickness"]
        @test sum(ply["thickness_m"] for ply in row["plies"][4:6])≈.0028
    end
    # Eccentric density produces body-force couples at original GRID points,
    # conserved again when routed to bay references and integrated in plots.
    q=deepcopy(mixed.params);q["loads.structure_inertia"]=true
    q["loads.fuel_accel_x"]=.23;q["loads.fuel_accel_y"]=-.37;q["loads.fuel_accel_z"]=-.81
    loaded=build(q);acceleration=collect(W.structure_acceleration(loaded.params))
    physical=[W.structural_element_mass_moments(loaded,g,e) for g in loaded.groups for e in eachindex(g.eids)]
    total_mass=sum(v.mass for v in physical);first_moment=sum(v.first for v in physical)
    expected_force=total_mass*acceleration;expected_moment=cross(first_moment,acceleration)
    nodal=W.structure_applied_loads(loaded)
    nodal_force=sum(collect(v.force) for v in nodal)
    nodal_moment=sum(cross(loaded.xyz[3v.node+1:3v.node+3],collect(v.force))+collect(v.moment) for v in nodal)
    @test nodal_force≈expected_force rtol=1e-12
    @test nodal_moment≈expected_moment rtol=1e-12
    @test any(norm(v.moment)>0 for v in nodal)
    positions=[Tuple(loaded.xyz[3sp.ref-2:3sp.ref]) for sp in loaded.fuel_rbe3]
    sources=[(position=Tuple(loaded.xyz[3v.node+1:3v.node+3]),force=v.force,moment=v.moment) for v in nodal]
    routed=W.transfer_load_wrenches(positions,sources)
    @test sum(collect(v) for v in routed.force)≈expected_force rtol=1e-12
    @test sum(cross(collect(x),collect(f))+collect(c) for (x,f,c) in zip(positions,routed.force,routed.moment))≈expected_moment rtol=1e-12
    density_sources=W.structural_mass_sources(loaded)
    cuts=[W.structural_source_moments(v,-Inf,"inboard") for v in density_sources]
    @test sum(first(v) for v in cuts)≈total_mass rtol=1e-12
    @test sum(collect(last(v)) for v in cuts)≈first_moment rtol=1e-12
    @test endswith(W.APPLIED_LOAD_VERSION,"combinedflanges_v6")
    browser_fixture(mixed,"shell");browser_fixture(laminate,"laminate")
    p=fixture_params();p["properties.stringer_flange_width"]=0.;blade=build(p)
    @test isempty(flange_properties(blade))
    @test W.all_checks_pass(blade)
    browser_fixture(blade,"blade")
    # SOL101 and SOL103 run the actual mixed-material eccentric PCOMP deck.
    for solution in ("101","103")
        q=deepcopy(mixed.params);q["output.solution"]=solution;model=build(q)
        deck,parsed=export_model(model,"mixed_offset_sol"*solution)
        forward=N.solve_model(parsed)
        objective=solution=="101" ? Dict("type"=>"displacement","node_id"=>last(model.node_ids),"component"=>"magnitude") : Dict("type"=>"frequency_eigenvalue","mode"=>1)
        response=W.sensitivity_response(forward,model,objective)
        @test isfinite(response.value)&&response.value>0
        push!(results,Dict("solution"=>solution,"response"=>response.value,"deck"=>deck))
    end
    selected=first(W.sensitivity_catalog(mixed)["variables"])
    request=Dict("solution"=>"101","case_id"=>1,"objective"=>Dict("type"=>"displacement","node_id"=>last(mixed.node_ids),"component"=>"z"),
        "variables"=>[selected["id"]],"derivative_method"=>"analytic")
    failure=try W.sensitivity_request(mixed,request);nothing catch error;error end
    @test failure isa ArgumentError
    @test occursin("combined PCOMP",sprint(showerror,failure))
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"analyses"=>results)))
