using Test, LinearAlgebra, WingFEGen, OpenJFEM
const W=WingFEGen
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function axial_mesh_parameters(;kind="aileron",underside=false,deflected=false)
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","planform.sweep"=>12.,"planform.dihedral"=>2.,"planform.twist_tip"=>-3.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic","loads.lift_total"=>1.,
        "loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
    p["movable_surfaces.items"]=[Dict("name"=>"Control","kind"=>kind,"edge"=>"trailing","eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>underside ? .77 : .7,"hinge_end"=>underside ? .79 : .72,"front_spar_start"=>.78,"front_spar_end"=>.8,
        "hinge_z_start"=>underside ? -1. : -.3,"hinge_z_end"=>underside ? -.8 : .15,"deflection"=>15.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Control","span_bays"=>4,"span_elements"=>2,"chord_elements"=>4,"height_elements"=>2,"mesh_deflected"=>deflected))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Control","eta"=>eta,"rib"=>99,
        "fitting"=>"shell_lugs","actuator"=>true,"actuator_stiffness"=>1e7,"hinge_stiffness"=>123.)) for eta in (.26,.74)]
    first(W.normalize_params(p))
end
function axial_torque_check(m,name)
    path=joinpath(out,name*".bdf");W.write_reference(m,path;large_field=true)
    aa=m.movable_structure["attachments"];first_hinge=first(aa);torque=.1
    text=read(path,String)
    text=replace(text,r"(?m)^FORCE\*[^\r\n]*\r?\n\*[^\r\n]*\r?\n"=>"")
    text=replace(text,"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0.")
    # Load the actual rib with a balanced physical force couple. A point moment
    # at a shell-fitting tip can excite its unsupported drilling rotation;
    # artificial lateral stays must not be needed to make that load meaningful.
    surface=only(m.movable_structure["surfaces"])
    rib=surface["rib_sections"][first_hinge["master_rib_index"]]
    load_nodes=[rib["front_upper"],rib["front_lower"],last(rib["lower_nodes"])]
    balance=zeros(6,9)
    for (j,node) in enumerate(load_nodes)
        r=m.xyz[3node-2:3node].-first_hinge["origin"]
        balance[1:3,3j-2:3j].=Matrix{Float64}(I,3,3)
        balance[4:6,3j-2:3j].=[0. -r[3] r[2];r[3] 0. -r[1];-r[2] r[1] 0.]
    end
    target=vcat(zeros(3),torque.*first_hinge["axis"])
    forces=balance'*(balance*balance'\target)
    @test balance*forces ≈ target atol=1e-12
    force_cards=String[]
    for (j,node) in enumerate(load_nodes)
        f=forces[3j-2:3j];magnitude=norm(f)
        push!(force_cards,join(("FORCE",1,m.node_ids[node],0,magnitude,(f./magnitude)...),","))
    end
    text=replace(text,"ENDDATA"=>join(force_cards,"\n")*"\nENDDATA")
    write(path,text);parsed=OpenJFEM.bdf_to_model(path)
    @test parsed["PARAM_AUTOSPC"]=="YES"
    @test length(parsed["CBUSHs"])==2
    for joint in aa
        bush=parsed["CBUSHs"][string(joint["actuator_eid"])];property=parsed["PBUSHs"][string(joint["actuator_pid"])]
        @test property["K"]==[1e7,0,0,0,0,0]
        @test bush["GA"]==m.node_ids[joint["actuator_nodes"][1]]
        @test bush["GB"]==m.node_ids[joint["actuator_nodes"][2]]
        @test bush["CID"]==joint["actuator_cid"]
    end
    forward=OpenJFEM.solve_model(parsed);case=only(forward["subcases"]);diagnostics=case["solver_diagnostics"]
    @test diagnostics["bc_partition"]["autospc_enabled"]
    @test diagnostics["bc_partition"]["autospc_diagonal_translational_dofs"]==0
    @test diagnostics["bc_partition"]["autospc_gpst_translational_dofs"]==0
    @test diagnostics["bc_partition"]["post_factorization_singular_dofs"]==0
    @test diagnostics["linear_solver"]["backend"]=="direct_cholesky"
    @test diagnostics["linear_solver"]["regularization_shift"]==0
    @test diagnostics["linear_solver"]["relative_residual"]<1e-8
    by_grid=Dict(r["grid_id"]=>r for r in case["displacements"])
    motion(ref,fields)=[by_grid[m.node_ids[ref]][k] for k in fields]
    spring_moment=0.;springs=Any[]
    for joint in aa
        n1,n2=joint["actuator_nodes"]
        extension=dot(motion(n2,("t1","t2","t3"))-motion(n1,("t1","t2","t3")),joint["actuator_axis"])
        force=joint["K1_N_per_m"]*extension;spring_moment+=force*joint["actuator_hinge_arm_m"]
        dt=motion(joint["surface_ref"],("t1","t2","t3"))-motion(joint["box_ref"],("t1","t2","t3"))
        dr=motion(joint["surface_ref"],("r1","r2","r3"))-motion(joint["box_ref"],("r1","r2","r3"))
        @test norm(dt)<1e-9;@test norm(cross(dr,joint["axis"]))<1e-9
        push!(springs,Dict("extension_m"=>extension,"force_N"=>force,"hinge_arm_m"=>joint["actuator_hinge_arm_m"],"relative_hinge_rotation_rad"=>dot(dr,joint["axis"])))
    end
    @test spring_moment≈torque rtol=1e-5 atol=1e-9
    reactions=[(position=Tuple(m.xyz[3findfirst(==(r["grid_id"]),m.node_ids)-2:3findfirst(==(r["grid_id"]),m.node_ids)]),force=Tuple(r[k] for k in ("t1","t2","t3")),moment=Tuple(r[k] for k in ("r1","r2","r3"))) for r in case["spc_forces"]]
    rf,rm=W.load_resultant(reactions)
    @test norm(collect(rf))<1e-6
    @test norm(collect(rm).+torque.*first_hinge["axis"])<1e-6
    Dict("name"=>name,"springs"=>springs,"applied_torque_Nm"=>torque,"spring_moment_Nm"=>spring_moment,"load_method"=>"Balanced physical force couple on movable rib nodes","load_grids"=>m.node_ids[load_nodes],"solver_diagnostics"=>diagnostics)
end
reports=Any[]
tests=@testset "Axial actuators, relocated conforming ribs and underside lugs" begin
    row=merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"test","span_bays"=>4))
    layout=W.movable_master_rib_layout(0.,1.,row,[Dict("eta"=>.24),Dict("eta"=>.76)])
    @test [r["eta"] for r in layout]==[0.,.24,.5,.76,1.]
    @test first(layout)["closure"]&&last(layout)["closure"]
    @test [r["eta"] for r in W.movable_master_rib_layout(0.,1.,row,Any[])]==[0.,.25,.5,.75,1.]
    crowded=W.movable_master_rib_layout(0.,1.,row,[Dict("eta"=>.1),Dict("eta"=>.2),Dict("eta"=>.3)])
    @test all(diff([r["eta"] for r in crowded]).<=.375+1e-12)
    @test any(get(r,"gap_refinement",false) for r in crowded)
    for (kind,underside,deflected,knee) in (("aileron",false,false,false),("flap",true,true,false),("flap",true,true,true))
        name=knee ? "close_front_spar_flap" : underside ? "underside_flap" : "front_spar_aileron"
        p=axial_mesh_parameters(;kind,underside,deflected)
        if knee;p["movable_surfaces.items"][1]["hinge_z_start"]=p["movable_surfaces.items"][1]["hinge_z_end"]=0.;end
        write(joinpath(out,name*"_parameters.json"),W.JSON.json(p))
        m=W.build_model(p);@test W.all_checks_pass(m)
        surface=only(m.movable_structure["surfaces"]);aa=m.movable_structure["attachments"]
        @test length(surface["rib_sections"])==5
        @test all(diff(surface["rib_etas"]).<=surface["nominal_rib_pitch_eta"]*1.5+1e-12)
        for joint in aa
            rib=surface["rib_sections"][joint["master_rib_index"]]
            @test joint["underside_lug"]==(underside&&!knee)
            @test joint["actuator_nodes"][2]==rib["front_upper"]
            @test joint["actuator_nodes"][1]==findfirst(==((W.ni(m.grid),m.grid.ribs[joint["rib"]],m.grid.nh)),m.node_keys)
            @test joint["actuator_pid"]!=joint["pid"]
            @test joint["actuator_cid"]!=joint["cid"]
            @test joint["K1_N_per_m"]==1e7 # legacy123 Nm/rad was not reinterpreted
            @test joint["actuator_length_m"]>0
            @test abs(joint["actuator_hinge_arm_m"])>1e-5
            for n in rib["perimeter_nodes"]
                @test abs(dot(m.xyz[3n-2:3n].-joint["origin"],joint["lug_plane_normal"]))<1e-9
            end
            for n in joint["surface_nodes"]
                @test n in (underside&&!knee ? rib["lower_nodes"] : rib["perimeter_nodes"])
            end
            if underside&&!knee;@test joint["lug_plane_normal"]≈joint["axis"];end
            if knee
                # A small x/c clearance alone no longer moves the fitting to
                # the underside: hinges inside the foil attach to the spar.
                @test joint["control_lug_attachment"]=="front spar"
                @test rib["front_lower"] in joint["surface_nodes"]
                @test rib["front_upper"] in joint["surface_nodes"]
            end
        end
        @test W.validate_movable_actuator_paths(m)===nothing
        push!(reports,axial_torque_check(m,name))
        write(joinpath(out,"axial_mesh_diagnostics.json"),W.JSON.json(reports))
        if knee
            p["output.solution"]="103";p["output.n_modes"]=6
            modal_model=W.build_model(p);modal_path=joinpath(out,"close_front_spar_modal.bdf")
            W.write_reference(modal_model,modal_path;large_field=true)
            write(modal_path,replace(read(modal_path,String),"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0."))
            modal=OpenJFEM.solve_model(OpenJFEM.bdf_to_model(modal_path))
            eigen=W.sensitivity_response(modal,modal_model,Dict("type"=>"frequency_eigenvalue","mode"=>1)).value
            @test isfinite(eigen)&&eigen>0
            last(reports)["first_modal_eigenvalue"]=eigen
        end
    end
    coincident=axial_mesh_parameters(;kind="flap")
    merge!(coincident,Dict("airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.))
    cs=only(coincident["movable_surfaces.items"])
    cs["front_spar_end"]=cs["front_spar_start"];cs["hinge_start"]=cs["hinge_end"]=cs["front_spar_start"]
    cs["hinge_z_start"]=cs["hinge_z_end"]=-.5
    cm=W.build_model(coincident);surface=only(cm.movable_structure["surfaces"])
    for joint in cm.movable_structure["attachments"]
        rib=surface["rib_sections"][joint["master_rib_index"]]
        @test joint["surface_ref"]==rib["front_lower"]
        @test !joint["underside_lug"]
        lugs=only(filter(g->g.pid==joint["lug_pid"],cm.groups))
        for j in eachindex(lugs.eids)
            ns=lugs.conn[3j-2:3j];points=[cm.xyz[3n-2:3n] for n in ns]
            @test norm(cross(points[2]-points[1],points[3]-points[1]))>1e-12
        end
    end
    push!(reports,axial_torque_check(cm,"coincident_front_lower_hinge"))
    inside=axial_mesh_parameters(;kind="flap",underside=true)
    inside["movable_surfaces.items"][1]["hinge_start"]=.81;inside["movable_surfaces.items"][1]["hinge_end"]=.83
    inside["movable_surfaces.items"][1]["hinge_z_start"]=inside["movable_surfaces.items"][1]["hinge_z_end"]=0.
    @test all(!a["underside_lug"] for a in W.build_model(inside).movable_structure["attachments"])
    missing=axial_mesh_parameters();empty!(missing["movable_structure.attachments"])
    @test_throws ArgumentError W.build_model(missing)
    collision=axial_mesh_parameters();collision["movable_structure.attachments"][2]["eta"]=.27
    @test_throws ArgumentError W.build_model(collision)
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"axial_mesh_summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports)))
