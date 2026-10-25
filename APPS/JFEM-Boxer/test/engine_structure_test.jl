using Test, LinearAlgebra, WingFEGen, OpenJFEM
const W=WingFEGen
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function engine_test_params(;oriented=false)
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","planform.sweep"=>12.,"planform.dihedral"=>3.,"planform.twist_tip"=>-2.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic","loads.lift_total"=>1.,
        "loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
    p["engines.items"]=[merge(W.ENGINE_DEFAULTS,Dict("name"=>"Test engine","x"=>.1,"y"=>.5,"z"=>-.5,
        "mass"=>25.,"length"=>.6,"front_rib"=>2,"aft_rib"=>3,"aft_xc"=>.55))]
    if oriented
        p["planform.sweep"]=12.;p["planform.dihedral"]=3.;p["planform.twist_tip"]=-2.;p["planform.taper_ratio"]=.8
        p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>90.,"pitch"=>.25)]
    end
    first(W.normalize_params(p))
end
function engine_deck(m,name)
    path=joinpath(out,name*".bdf");W.write_reference(m,path;large_field=true)
    # Remove shell drilling stabilization for the stringent global-moment
    # equilibrium check; this is independent of the new interpolation path.
    write(path,replace(read(path,String),"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0."))
    path,OpenJFEM.bdf_to_model(path)
end
function engine_rigid_checks(m,parsed;units_sweep=false)
    ids=Dict(id=>i for (i,id) in enumerate(m.node_ids));n=length(m.node_ids)
    X=permutedims(reshape(m.xyz,3,n));Id=Matrix{Float64}(I,3,3)
    map=OpenJFEM.Solver.assemble_constraints(parsed,ids,X,[Id for _ in 1:n],Int[],Int[],Float64[])[1]
    @test all(!haskey(map,independent) for pairs in values(map) for (independent,_) in pairs)
    @test all(!haskey(map,6(node-1)+c) for gr in m.groups for node in gr.conn for c in 1:6)
    engine=only(W.engine_records(m));nodes=engine["beam_nodes"][[2,3]]
    @test [mount["ref"] for mount in engine["mounts"]]==nodes
    @test all(!haskey(map,6(first(engine["beam_nodes"])-1)+c) for c in 1:6)
    # Extreme length-unit sweeps amplify floating-point cancellation in the
    # generic interpolation inverse. Ordinary fixtures retain strict limits.
    rigid_tolerance=units_sweep ? 1e-9 : 1e-10
    wrench_rtol=units_sweep ? 1e-10 : 1e-11
    rigid=zeros(6n,6)
    for i in 1:n,j in 1:3
        rigid[6(i-1)+j,j]=1.
        rigid[6(i-1).+(1:3),j+3]=cross(Id[:,j],X[i,:]);rigid[6(i-1)+3+j,j+3]=1.
    end
    for node in nodes,c in 1:6
        dof=6(node-1)+c;@test haskey(map,dof)
        recovered=sum(coefficient.*rigid[independent,:] for (independent,coefficient) in map[dof])
        @test recovered≈rigid[dof,:] atol=rigid_tolerance rtol=rigid_tolerance
    end
    # Direct cap interpolation must conserve arbitrary forces AND moments
    # applied at either dependent engine station, including collinear caps.
    for endnode in nodes
        f=[12.,-15.,-250.];moment=[3.,4.,-2.];applied=vcat(f,moment);terminal=zeros(6n)
        for c in 1:6,(independent,coefficient) in map[6(endnode-1)+c]
            terminal[independent]+=coefficient*applied[c]
        end
        force=zeros(3);torque=zeros(3)
        for i in 1:n
            fi=terminal[6(i-1).+(1:3)];mi=terminal[6(i-1).+(4:6)]
            force+=fi;torque+=mi+cross(X[i,:],fi)
        end
        @test isapprox(force,f;atol=1e-9,rtol=wrench_rtol)
        @test isapprox(torque,moment+cross(X[endnode,:],f);atol=1e-9,rtol=wrench_rtol)
    end
end
function clamped_engine_response(m,name;scale_E=1.,force=[0.,0.,-1000.])
    r=only(W.engine_records(m));path=joinpath(out,name*".bdf")
    patches=sort!(unique(vcat([mount["nodes"] for mount in r["mounts"]]...)))
    allnodes=sort!(unique(vcat(patches,r["beam_nodes"],[mount["ref"] for mount in r["mounts"]])))
    open(path,"w") do base
        io=IOContext(base,:large_field=>true)
        println(io,"SOL 101\nCEND\nSPC=1\nLOAD=1\nDISPLACEMENT=ALL\nSPCFORCES=ALL\nBEGIN BULK\nPARAM,AUTOSPC,NO")
        for n in allnodes;W.card!(io,"GRID",(m.node_ids[n],nothing,m.xyz[3n-2:3n]...));end
        W.write_engine_structure(io,m)
        W.card!(io,"SPC1",Any[1,123456,m.node_ids[patches]...])
        W.card!(io,"FORCE",(1,m.node_ids[first(r["beam_nodes"])],0,1.,force...))
        println(io,"ENDDATA")
    end
    deck=OpenJFEM.bdf_to_model(path);deck["MATs"][string(r["mid"])]["E"]*=scale_E
    result=OpenJFEM.solve_model(deck);case=only(result["subcases"])
    displacement=only(filter(d->d["grid_id"]==m.node_ids[first(r["beam_nodes"])],case["displacements"]))
    @test case["solver_diagnostics"]["linear_solver"]["regularization_shift"]==0
    @test case["solver_diagnostics"]["bc_partition"]["post_factorization_singular_dofs"]==0
    [displacement[k] for k in ("t1","t2","t3")]
end
reports=Any[]
tests=@testset "Elastic engine beam, attachment geometry and native constraints" begin
    @test W.normalize_engines(Any[])==Any[]
    @test_throws ArgumentError W.normalize_engines([Dict("mass"=>-1.)])
    @test_throws ArgumentError W.normalize_engines([Dict("length"=>0.)])
    @test_throws ArgumentError W.normalize_engines([Dict("front_rib"=>1.5)])
    @test_throws ArgumentError W.normalize_engines([Dict("x"=>NaN)])
    @test_throws ArgumentError W.normalize_engines([Dict("unknown"=>1)])
    @test_throws ArgumentError W.normalize_engines([Dict("I1"=>0.)])
    @test_throws ArgumentError W.normalize_engines([Dict("E"=>-1.)])
    @test_throws ArgumentError W.normalize_engines([Dict("name"=>"same"),Dict("name"=>"same")])
    p=engine_test_params();m=W.build_model(p);r=only(W.engine_records(m))
    @test W.all_checks_pass(m)
    @test r["mass_kg"]==25.
    @test r["length_m"]==.6
    @test r["inertia_kg_m2"]==[[0.,0.,0.],[0.,.75,0.],[0.,0.,.75]]
    @test m.xyz[3r["cg_node"]-2:3r["cg_node"]]==[.1,.5,-.5]
    @test m.xyz[3r["beam_nodes"][1]-2:3r["beam_nodes"][1]]≈[-.2,.5,-.5]
    @test m.xyz[3r["beam_nodes"][3]-2:3r["beam_nodes"][3]]≈[.4,.5,-.5]
    @test length(W.engine_element_ids(m))==5
    @test all(!occursin("ENGINE",g.name) for g in m.groups)
    front,aft=r["mounts"];@test front["rib"]==2;@test aft["rib"]==3;@test aft["xc"]==.55
    @test front["ref"]==r["cg_node"]
    @test aft["ref"]==last(r["beam_nodes"])
    frontj=m.grid.ribs[2];aftj=m.grid.ribs[3]
    @test Set(m.node_keys[n] for n in front["nodes"])==Set((0,j,m.grid.nh) for j in (frontj-2,frontj-1,frontj+1,frontj+2))
    aftcaps=Set((0,j,0) for j in (aftj-2,aftj-1,aftj+1,aftj+2))
    @test length(aft["nodes"])==5
    @test issubset(aftcaps,Set(m.node_keys[n] for n in aft["nodes"]))
    ribnode=only(filter(n->m.node_keys[n][2]==aftj,aft["nodes"]))
    @test m.node_keys[ribnode][3]==0
    ix=m.node_keys[ribnode][1]
    @test isapprox(abs(m.grid.lower_xcs[ix+1,aftj+1]-.55),minimum(abs.(m.grid.lower_xcs[:,aftj+1].-.55)))
    @test isempty(r["arm_eids"])
    payload=W.engine_structure_payload(m);@test only(payload["engines"])["cg_node"]==r["cg_node"]-1
    @test only(payload["engines"])["cg_grid"]==m.node_ids[r["cg_node"]]
    @test length(vcat([c["elements"] for c in W.engine_connection_payload(m)]...))==5
    for collection in W.engine_connection_payload(m),element in collection["elements"]
        @test haskey(element["properties"],"PID")== (collection["card"]=="CBAR")
    end
    path,parsed=engine_deck(m,"engine_static")
    @test length(parsed["CONM2s"])==1
    @test isempty(parsed["RBE2s"])
    @test length(parsed["RBE3s"])==length(m.rbe3)+2
    @test parsed["PBARLs"][string(r["pid"])]["I1"]==r["I1"]
    @test parsed["PBARLs"][string(r["pid"])]["I2"]==r["I2"]
    @test parsed["MATs"][string(r["mid"])]["RHO"]==0.
    @test all(parsed["CBARs"][string(id)]["PID"]==r["pid"] for id in r["beam_eids"])
    engine_rigid_checks(m,parsed)
    # Root equilibrium is checked against the engine-applied force/couple,
    # without post-factorization repairs or artificial beam stiffness. Shell
    # drilling DOFs may still use the solver's existing grid-point AUTOSPC.
    force=[12.,-15.,-250.];moment=[3.,4.,-2.];cg=m.node_ids[r["cg_node"]]
    text=replace(read(path,String),r"(?m)^(?:FORCE|MOMENT)\*[^\r\n]*\r?\n\*[^\r\n]*\r?\n"=>"")
    text=replace(text,"ENDDATA"=>"FORCE,1,$cg,0,1.,12.,-15.,-250.\nMOMENT,1,$cg,0,1.,3.,4.,-2.\nENDDATA")
    write(path,text);forward=OpenJFEM.solve_model(OpenJFEM.bdf_to_model(path));case=only(forward["subcases"])
    diagnostics=case["solver_diagnostics"]
    @test diagnostics["bc_partition"]["post_factorization_singular_dofs"]==0
    @test diagnostics["linear_solver"]["regularization_shift"]==0
    @test diagnostics["linear_solver"]["relative_residual"]<1e-8
    reactionF=zeros(3);reactionM=zeros(3)
    for rr in case["spc_forces"]
        i=findfirst(==(rr["grid_id"]),m.node_ids);f=[rr[k] for k in ("t1","t2","t3")]
        reactionF+=f;reactionM+=[rr[k] for k in ("r1","r2","r3")]+cross(m.xyz[3i-2:3i],f)
    end
    @test reactionF≈-force atol=1e-6
    @test reactionM≈-(moment+cross(r["center_of_gravity_m"],force)) atol=1e-6
    push!(reports,Dict("case"=>"engine_static","reaction_force_N"=>reactionF,"reaction_moment_Nm"=>reactionM,"solver_diagnostics"=>diagnostics))
    modalp=deepcopy(p);modalp["output.solution"]="103";modalp["output.n_modes"]=6
    modalmodel=W.build_model(modalp);modalpath,modaldeck=engine_deck(modalmodel,"engine_modal")
    modal=OpenJFEM.solve_model(modaldeck)
    eigen=W.sensitivity_response(modal,modalmodel,Dict("type"=>"frequency_eigenvalue","mode"=>1)).value
    @test isfinite(eigen)&&eigen>0
    push!(reports,Dict("case"=>"engine_modal","first_eigenvalue"=>eigen))
    # The forward half remains an elastic cantilever when the two cap patches
    # are clamped: F (L/2)^3 / (3 E I). I1 bends in XY and I2 in XZ.
    # This proves the new CG interpolation does not rigidize the whole beam.
    anisop=deepcopy(p);anisop["engines.items"][1]["I2"]=2e-4
    anisom=W.build_model(anisop);ar=only(W.engine_records(anisom))
    displ=clamped_engine_response(anisom,"engine_clamped_vertical")
    expected=-1000(ar["length_m"]/2)^3/(3ar["E"]*ar["I2"])
    @test displ[3]≈expected rtol=1e-8 atol=1e-13
    stiffer=clamped_engine_response(anisom,"engine_clamped_double_E";scale_E=2.)
    @test stiffer[3]≈displ[3]/2 rtol=1e-8 atol=1e-13
    lateral=clamped_engine_response(anisom,"engine_clamped_lateral";force=[0.,-1000.,0.])
    @test lateral[2]≈-1000(ar["length_m"]/2)^3/(3ar["E"]*ar["I1"]) rtol=1e-8 atol=1e-13
    push!(reports,Dict("case"=>"forward_half_cantilever","computed_vertical_m"=>displ[3],"analytical_vertical_m"=>expected,"double_E_vertical_m"=>stiffer[3]))
    # Same-rib mounts, edge x/c, disabled rows, changed physical rib layout and
    # both lower and upper invalid bounds are exercised explicitly.
    same=deepcopy(p);same["engines.items"][1]["aft_rib"]=2
    same_model=W.build_model(same);_,same_parsed=engine_deck(same_model,"engine_same_rib");engine_rigid_checks(same_model,same_parsed)
    for xc in (0.,1.)
        edge_xc=deepcopy(p);edge_xc["engines.items"][1]["aft_xc"]=xc
        edge_model=W.build_model(edge_xc);edge_mount=last(only(W.engine_records(edge_model))["mounts"])
        @test edge_mount["xc"]==xc
        @test isapprox(edge_mount["actual_xc"],xc==0. ? first(m.grid.lower_xcs[:,aftj+1]) : last(m.grid.lower_xcs[:,aftj+1]))
        @test length(edge_model.node_ids)==length(m.node_ids)
        _,edge_deck=engine_deck(edge_model,"engine_aft_snap_"*string(Int(xc)))
        engine_rigid_checks(edge_model,edge_deck)
    end
    bad=deepcopy(p);bad["engines.items"][1]["front_rib"]=999;@test_throws ArgumentError W.validate_engine_structure(bad)
    disabled=deepcopy(p);disabled["engines.items"][1]["enabled"]=false
    @test isempty(W.engine_records(W.build_model(disabled)))
    # Front-cap translation nodes are collinear in this straight fixture;
    # their rotations must retain rigid-roll and moment transfer exactly.
    straight=deepcopy(p)
    for key in ("planform.sweep","planform.dihedral","planform.twist_tip");straight[key]=0.;end
    straight["planform.taper_ratio"]=1.
    straight_model=W.build_model(straight)
    _,straight_parsed=engine_deck(straight_model,"engine_straight_caps")
    engine_rigid_checks(straight_model,straight_parsed)
    # Identical geometry expressed at different length scales must preserve
    # all six rigid motions and wrench equilibrium, including cap roll.
    for scale in (1e-2,1e2)
        scaled=deepcopy(straight);scaled["planform.area"]*=scale^2
        for key in ("box.rib_pitch","box.stringer_pitch");scaled[key]*=scale;end
        for key in ("x","y","z","length");scaled["engines.items"][1][key]*=scale;end
        scaled_model=W.build_model(scaled)
        _,scaled_parsed=engine_deck(scaled_model,"engine_units_"*string(scale))
        engine_rigid_checks(scaled_model,scaled_parsed;units_sweep=true)
    end
    # Two real nodes must exist on each side; do not silently broaden or shift
    # a boundary attachment to a different rib or to the opposite surface.
    for key in ("front_rib","aft_rib"),rib in (1,length(m.grid.ribs))
        invalid=deepcopy(p);invalid["engines.items"][1][key]=rib
        @test_throws ArgumentError W.build_model(invalid)
    end
    sparse=deepcopy(p);sparse["mesh.elements_between_ribs"]=1
    @test_throws ArgumentError W.build_model(sparse)
    # At the front-spar x/c, the nominal-rib lower point remains distinct from
    # the four flanking cap nodes and no interpolation membership duplicates.
    edge=deepcopy(p);edge["engines.items"][1]["aft_xc"]=m.grid.lower_xcs[1,aftj+1]
    edge_model=W.build_model(edge);edge_mount=last(only(W.engine_records(edge_model))["mounts"])
    @test length(edge_mount["nodes"])==length(unique(edge_mount["nodes"]))==5
    _,edge_parsed=engine_deck(edge_model,"engine_front_edge_aft_point")
    engine_rigid_checks(edge_model,edge_parsed)
    oriented=W.build_model(engine_test_params(;oriented=true));@test W.all_checks_pass(oriented)
    _,oriented_parsed=engine_deck(oriented,"engine_oriented_rib");engine_rigid_checks(oriented,oriented_parsed)
    multiple=deepcopy(p);push!(multiple["engines.items"],merge(W.ENGINE_DEFAULTS,Dict("name"=>"Second engine","y"=>.7,"mass"=>30.)))
    multiple["loads.structure_inertia"]=true;multiple["output.include_aero_shells"]=true
    multiple_model=W.build_model(multiple);@test length(W.engine_records(multiple_model))==2
    @test W.all_checks_pass(multiple_model)
    _,multiple_parsed=engine_deck(multiple_model,"engine_two_with_bay_references")
    @test length(multiple_parsed["CONM2s"])==2
    ids=vcat([gr.eids for gr in multiple_model.groups]...,[sp.eid for sp in multiple_model.rbe3],
        [sp.eid for sp in multiple_model.fuel_rbe3],W.engine_element_ids(multiple_model))
    @test length(ids)==length(unique(ids))
    @test isempty(multiple_parsed["RBE2s"])
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"engine_structure_summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports)))
