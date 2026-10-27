using Test, LinearAlgebra, TOML, WingFEGen, OpenJFEM
const W=WingFEGen
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function refinement_parameters(kind="aileron")
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","planform.sweep"=>22.,"planform.dihedral"=>4.,"planform.twist_tip"=>-7.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic","loads.lift_total"=>1.,
        "loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
    p["movable_surfaces.items"]=[Dict("name"=>"Control","kind"=>kind,"edge"=>"trailing","eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>.7,"hinge_end"=>.72,"front_spar_start"=>.78,"front_spar_end"=>.8,"hinge_z_start"=>-.3,"hinge_z_end"=>.15,"deflection"=>15.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Control","span_bays"=>3,"span_elements"=>2,"chord_elements"=>2,"height_elements"=>2))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Control","eta"=>eta,"rib"=>99,
        "fitting"=>"shell_lugs","actuator"=>true)) for eta in (.26,.74)]
    first(W.normalize_params(p))
end
function solve_patch(m,path)
    W.write_reference(m,path;large_field=true)
    text=read(path,String)
    text=replace(text,"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0.")
    write(path,text);parsed=OpenJFEM.bdf_to_model(path)
    # Recover the exact generated interpolation equations from the exported deck.
    links=[l for a in m.movable_structure["attachments"] for l in a["interpolation_links"]]
    @test length(parsed["MPCs"])==6length(links)
    @test all(length(e["TERMS"])==3 for e in parsed["MPCs"])
    for mode in (:small,:free)
        companion=replace(path,".bdf"=>"_$(mode).bdf")
        open(companion,"w") do io
            W.write_deck(mode===:free ? IOContext(io,:full_precision=>true) : io,m)
        end
        other=OpenJFEM.bdf_to_model(companion)
        @test length(other["MPCs"])==6length(links)
        @test all(length(e["TERMS"])==3 for e in other["MPCs"])
    end
    @test occursin("MPC = 80000001",text)==!isempty(links)
    grids=Dict(Int(n["ID"])=>n for n in values(parsed["GRIDs"]))
    coordinates=Dict(m.node_ids[n]=>m.xyz[3n-2:3n] for n in eachindex(m.node_ids))
    translation=[.12,-.34,.56];omega=[.023,-.017,.011]
    rigid(g,c)=c<=3 ? (translation+cross(omega,coordinates[g]))[c] : omega[c-3]
    for equation in parsed["MPCs"]
        terms=equation["TERMS"]
        @test abs(sum(t["A"]*rigid(t["G"],t["C"]) for t in terms))<2e-10
        @test grids[terms[1]["G"]]["CD"]==0
    end
    # A non-rigid linear strain/rotation field must also interpolate exactly.
    gradient=[.001 .002 -.003;-.004 .005 .006;.007 -.008 .009]
    linear(g,c)=c<=3 ? (gradient*coordinates[g])[c] : (gradient*coordinates[g])[c-3]
    @test all(abs(sum(t["A"]*linear(t["G"],t["C"]) for t in e["TERMS"]))<1e-10 for e in parsed["MPCs"])
    forward=OpenJFEM.solve_model(parsed)
    nodes=only(m.movable_structure["surfaces"])["nodes"]
    response=W.sensitivity_response(forward,m,Dict("type"=>"displacement","node_id"=>m.node_ids[last(nodes)],"component"=>"z"))
    @test isfinite(response.value)
    # Apply only a hinge torque. Rib-interior shell drilling DOFs require the
    # usual rotational AUTOSPC treatment; no translation may be auto-constrained.
    first_hinge=first(m.movable_structure["attachments"]);torque=.1
    moment="MOMENT,1,$(m.node_ids[first_hinge["surface_ref"]]),$(first_hinge["cid"]),$torque,1.,0.,0.\n"
    torque_text=replace(text,r"(?m)^FORCE\*[^\r\n]*\r?\n\*[^\r\n]*\r?\n"=>"")
    torque_text=replace(torque_text,"ENDDATA"=>moment*"ENDDATA")
    torque_path=replace(path,".bdf"=>"_torque.bdf");write(torque_path,torque_text)
    torque_input=OpenJFEM.bdf_to_model(torque_path);@test torque_input["PARAM_AUTOSPC"]=="YES"
    torque_result=OpenJFEM.solve_model(torque_input);tc=only(torque_result["subcases"])
    diagnostics=tc["solver_diagnostics"]
    @test diagnostics["bc_partition"]["autospc_enabled"]
    @test diagnostics["bc_partition"]["autospc_diagonal_translational_dofs"]==0
    @test diagnostics["bc_partition"]["autospc_gpst_translational_dofs"]==0
    @test diagnostics["bc_partition"]["post_factorization_singular_dofs"]==0
    @test diagnostics["linear_solver"]["backend"]=="direct_cholesky"
    @test diagnostics["linear_solver"]["regularization_shift"]==0.
    @test diagnostics["linear_solver"]["relative_residual"]<1e-9
    by_grid=Dict(r["grid_id"]=>r for r in tc["displacements"])
    movement(ref,fields)=[by_grid[m.node_ids[ref]][k] for k in fields]
    joint_results=Any[]
    for joint in m.movable_structure["attachments"]
        dt=movement(joint["surface_ref"],("t1","t2","t3"))-movement(joint["box_ref"],("t1","t2","t3"))
        dr=movement(joint["surface_ref"],("r1","r2","r3"))-movement(joint["box_ref"],("r1","r2","r3"))
        @test norm(dt)<1e-9
        @test norm(cross(dr,joint["axis"]))<1e-9
        a,b=joint["actuator_nodes"]
        extension=dot(movement(b,("t1","t2","t3"))-movement(a,("t1","t2","t3")),joint["actuator_axis"])
        force=joint["K1_N_per_m"]*extension
        push!(joint_results,Dict("angle_rad"=>dot(dr,joint["axis"]),"axial_force_N"=>force,"hinge_arm_m"=>joint["actuator_hinge_arm_m"]))
    end
    recovered_torque=sum(j["axial_force_N"]*j["hinge_arm_m"] for j in joint_results)
    @test recovered_torque≈torque rtol=1e-6 atol=1e-9
    reactions=[(position=Tuple(m.xyz[3findfirst(==(r["grid_id"]),m.node_ids)-2:3findfirst(==(r["grid_id"]),m.node_ids)]),
        force=Tuple(r[k] for k in ("t1","t2","t3")),moment=Tuple(r[k] for k in ("r1","r2","r3"))) for r in tc["spc_forces"]]
    rf,rm=W.load_resultant(reactions)
    force_error=norm(collect(rf));moment_error=norm(collect(rm).+torque.*first_hinge["axis"])
    @test force_error<1e-6
    @test moment_error<1e-6
    write(replace(path,".bdf"=>"_torque_receipt.json"),W.JSON.json(Dict("AUTOSPC"=>true,"K6ROT"=>0.,
        "applied_torque_Nm"=>torque,"actuator_torque_sum_Nm"=>recovered_torque,"force_balance_N"=>force_error,"moment_balance_Nm"=>moment_error,
        "joints"=>joint_results,"solver_diagnostics"=>get(tc,"solver_diagnostics",Dict()))))
    response.value
end
summaries=Any[]
tests=@testset "Planar connected fittings and local-thickness hinge offsets" begin
    p=refinement_parameters();s=only(p["movable_surfaces.items"]);w=W.make_wing(p)
    for ratio in (0.,.5,-2.),side in ("start","end")
        q=deepcopy(s);q["hinge_z_"*side]=ratio
        endpoint=W.movable_hinge_endpoints(w,q)[side=="start" ? 1 : 2]
        eta=q["eta_"*side];xc=q["hinge_"*side];lo=W.lower_point(w,eta,xc);up=W.upper_point(w,eta,xc)
        @test collect(endpoint)≈collect((up.+lo)./2 .+ ratio.*(up.-lo)) atol=1e-13
    end
    q=deepcopy(s);delete!(q,"hinge_z_start");delete!(q,"hinge_z_end")
    normalized=only(W.normalize_movable_surfaces([q]));@test normalized["hinge_z_start"]==normalized["hinge_z_end"]==0.
    for invalid in (NaN,Inf,true)
        q=merge(s,Dict("hinge_z_start"=>invalid));@test_throws ArgumentError W.normalize_movable_surfaces([q])
    end
    for kind in ("aileron","flap")
        p=refinement_parameters(kind);original=deepcopy(p);m=W.build_model(p);@test p==original;@test W.all_checks_pass(m)
        aa=m.movable_structure["attachments"];@test [a["rib"] for a in aa]==[2,4]
        @test [a["eta"] for a in aa]==[.25,.75]
        @test [a["requested_eta"] for a in aa]==[.26,.74]
        @test all(a->isempty(a["interpolation_links"])==(kind=="flap"),aa) # constant-y flap cuts reuse existing rib GRIDs
        for a in aa
            normal=kind=="flap" ? [0.,1.,0.] : a["axis"]
            @test a["lug_plane_normal"]≈normal
            lugs=only(filter(g->g.pid==a["lug_pid"],m.groups))
            for n in lugs.conn
                @test abs(dot(normal,m.xyz[3n-2:3n].-a["origin"]))<1e-9
            end
            for link in a["interpolation_links"]
                @test all(0 .< link["weights"] .< 1)
                @test sum(link["weights"])≈1
                @test m.xyz[3link["ref"]-2:3link["ref"]]≈sum(weight.*m.xyz[3n-2:3n] for (n,weight) in zip(link["nodes"],link["weights"]))
                @test all(n->any(g->n in g.conn,m.groups),link["nodes"])
            end
        end
        preview=only(W.movable_surfaces_preview(p)["surfaces"])
        @test aa[1]["frame_origin"]≈collect(preview["hinge"][1])
        restored,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p))))
        @test W.build_model(restored).xyz==m.xyz
        value=solve_patch(m,joinpath(out,kind*"_planar_hinges.bdf"))
        push!(summaries,Dict("kind"=>kind,"static_z_m"=>value,"cut_nodes"=>sum(length(a["interpolation_links"]) for a in aa),"lug_triangles"=>sum(length(a["lug_eids"]) for a in aa)))
    end
    p=refinement_parameters();p["movable_structure.attachments"][2]["eta"]=.27
    @test_throws ArgumentError W.build_model(p)
    p=refinement_parameters("flap");p["movable_surfaces.items"][1]["hinge_start"]=p["movable_surfaces.items"][1]["front_spar_start"]
    p["movable_surfaces.items"][1]["hinge_end"]=p["movable_surfaces.items"][1]["front_spar_end"]
    p["movable_surfaces.items"][1]["hinge_z_start"]=p["movable_surfaces.items"][1]["hinge_z_end"]=0.
    # Camber/twist make a straight hinge differ from the spar, so the simple
    # exactly coincident rectangular case is covered by movable_hinge_geometry_test.
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"refinement_summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>summaries)))
