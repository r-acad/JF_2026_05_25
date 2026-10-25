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
        "fitting"=>"shell_lugs","lateral_stay"=>true,"actuator"=>true,"actuator_stiffness"=>1e7,"hinge_stiffness"=>123.)) for eta in (.26,.74)]
    first(W.normalize_params(p))
end
function axial_torque_check(m,name)
    path=joinpath(out,name*".bdf");W.write_reference(m,path;large_field=true)
    aa=m.movable_structure["attachments"];first_hinge=first(aa);torque=.1
    text=read(path,String)
    text=replace(text,r"(?m)^FORCE\*[^\r\n]*\r?\n\*[^\r\n]*\r?\n"=>"")
    text=replace(text,"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0.")
    text=replace(text,"ENDDATA"=>"MOMENT,1,$(m.node_ids[first_hinge["surface_ref"]]),$(first_hinge["cid"]),$torque,1.,0.,0.\nENDDATA")
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
    Dict("name"=>name,"springs"=>springs,"applied_torque_Nm"=>torque,"spring_moment_Nm"=>spring_moment,"solver_diagnostics"=>diagnostics)
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
        name=knee ? "exterior_knee_flap" : underside ? "underside_flap" : "front_spar_aileron"
        p=axial_mesh_parameters(;kind,underside,deflected)
        if knee;p["movable_surfaces.items"][1]["hinge_z_start"]=p["movable_surfaces.items"][1]["hinge_z_end"]=0.;end
        write(joinpath(out,name*"_parameters.json"),W.JSON.json(p))
        m=W.build_model(p);@test W.all_checks_pass(m)
        surface=only(m.movable_structure["surfaces"]);aa=m.movable_structure["attachments"]
        @test length(surface["rib_sections"])==5
        @test all(diff(surface["rib_etas"]).<=surface["nominal_rib_pitch_eta"]*1.5+1e-12)
        for joint in aa
            rib=surface["rib_sections"][joint["master_rib_index"]]
            @test joint["underside_lug"]==underside
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
                @test n in (underside ? rib["lower_nodes"] : rib["perimeter_nodes"])
            end
            if underside;@test joint["lug_plane_normal"]≈joint["axis"];end
            if knee
                @test joint["lug_shape"]=="exterior knee"
                n=joint["lug_knee_node"]
                @test abs(dot(m.xyz[3n-2:3n].-joint["origin"],joint["lug_plane_normal"]))<1e-9
                @test haskey(m.movable_structure["node_etas"],n)
            end
        end
        @test W.validate_movable_actuator_paths(m)===nothing
        push!(reports,axial_torque_check(m,name))
        write(joinpath(out,"axial_mesh_diagnostics.json"),W.JSON.json(reports))
        if knee
            p["output.solution"]="103";p["output.n_modes"]=6
            modal_model=W.build_model(p);modal_path=joinpath(out,"exterior_knee_modal.bdf")
            W.write_reference(modal_model,modal_path;large_field=true)
            write(modal_path,replace(read(modal_path,String),"BEGIN BULK"=>"BEGIN BULK\nPARAM,K6ROT,0."))
            modal=OpenJFEM.solve_model(OpenJFEM.bdf_to_model(modal_path))
            eigen=W.sensitivity_response(modal,modal_model,Dict("type"=>"frequency_eigenvalue","mode"=>1)).value
            @test isfinite(eigen)&&eigen>0
            last(reports)["first_modal_eigenvalue"]=eigen
        end
    end
    inside=axial_mesh_parameters(;kind="flap",underside=true)
    inside["movable_surfaces.items"][1]["hinge_start"]=.81;inside["movable_surfaces.items"][1]["hinge_end"]=.83
    inside["movable_surfaces.items"][1]["hinge_z_start"]=inside["movable_surfaces.items"][1]["hinge_z_end"]=0.
    @test_throws ArgumentError W.build_model(inside)
    missing=axial_mesh_parameters();empty!(missing["movable_structure.attachments"])
    @test_throws ArgumentError W.build_model(missing)
    collision=axial_mesh_parameters();collision["movable_structure.attachments"][2]["eta"]=.27
    @test_throws ArgumentError W.build_model(collision)
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"axial_mesh_summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports)))
