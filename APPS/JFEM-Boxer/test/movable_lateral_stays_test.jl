using Test, LinearAlgebra, WingFEGen, OpenJFEM
const W=WingFEGen
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function stay_parameters(;box=true,movable=false,actuator=true)
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.end_eta"=>1.,"box.rib_pitch"=>.25,
        "box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic",
        "loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "leading_edge.enabled"=>false))
    p["movable_surfaces.items"]=[Dict("name"=>"Aileron","kind"=>"aileron","edge"=>"trailing","eta_start"=>.1,"eta_end"=>.9,
        "hinge_start"=>.7,"hinge_end"=>.7,"front_spar_start"=>.78,"front_spar_end"=>.78,
        "hinge_z_start"=>0.,"hinge_z_end"=>0.,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Aileron",
        "span_bays"=>3,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>2))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Aileron",
        "eta"=>eta,"fitting"=>"shell_lugs","actuator"=>actuator,"box_lateral_stay"=>box,
        "movable_lateral_stay"=>movable)) for eta in (.25,.75)]
    first(W.normalize_params(p))
end
reports=Any[]
suite=@testset "Optional same-body lateral stays preserve the relative hinge" begin
    @test W.MOVABLE_ATTACHMENT_DEFAULTS["box_lateral_stay"]
    @test !W.MOVABLE_ATTACHMENT_DEFAULTS["movable_lateral_stay"]
    for key in ("box_lateral_stay","movable_lateral_stay")
        p=stay_parameters();p["movable_structure.attachments"][1][key]=1
        @test_throws ArgumentError W.normalize_params(p)
    end
    for (box,movable) in ((false,false),(true,false),(false,true),(true,true))
        p=stay_parameters(;box,movable);m=W.build_model(p);aa=m.movable_structure["attachments"]
        file=joinpath(out,"stays_$(Int(box))_$(Int(movable)).bdf");W.write_reference(m,file;large_field=true)
        parsed=OpenJFEM.bdf_to_model(file);rbes=Dict(Int(r["ID"])=>r for r in values(parsed["RBE2s"]))
        @test length(rbes)==length(aa)*(1+Int(box)+Int(movable))
        @test length(parsed["CBUSHs"])==length(aa)
        dependents=[(n,c) for r in values(rbes) for n in r["GM"] for c in string(r["CM"])]
        @test length(unique(dependents))==length(dependents)
        for a in aa
            @test length(a["lateral_stays"])==Int(box)+Int(movable)
            @test rbes[a["joint_eid"]]["CM"]==12356
            surface=only(m.movable_structure["surfaces"])
            for stay in a["lateral_stays"]
                r=rbes[stay["eid"]];@test r["CM"]==123
                @test r["GN"]==m.node_ids[stay["independent"]]
                @test r["GM"]==[m.node_ids[stay["dependent"]]]
                if stay["side"]=="main box"
                    @test stay["target_rib"]==a["rib"]+1
                    @test m.node_keys[stay["cap_node"]]==(W.ni(m.grid),m.grid.ribs[a["rib"]+1],m.grid.nh)
                    @test stay["dependent"]==a["box_ref"]
                else
                    @test stay["target_rib"]==a["master_rib_index"]+1
                    @test stay["cap_node"]==surface["rib_sections"][a["master_rib_index"]+1]["front_upper"]
                    @test stay["independent"]==a["surface_ref"]
                end
                # A rigid rotation of the entire movable about its free hinge
                # must satisfy each stay. It must not become an actuator.
                point(n)=m.xyz[3n-2:3n]
                omega=stay["side"]=="movable surface" ? a["axis"] : zeros(3)
                motion(n)=cross(omega,point(n).-a["origin"])
                @test norm(motion(stay["dependent"])-motion(stay["independent"])-cross(omega,point(stay["dependent"])-point(stay["independent"])))<1e-12
            end
        end
        connections=W.movable_connection_payload(m)
        @test count(c->occursin("LATERAL_STAYS",c["name"]),connections)==Int(box)+Int(movable)
        push!(reports,Dict("box"=>box,"movable"=>movable,"rbe2_count"=>length(rbes),"deck"=>basename(file)))
    end
    # At the structural end there is no valid outboard target: do not silently
    # switch to a different rib or create a reversed stay.
    p=stay_parameters();p["movable_surfaces.items"][1]["eta_end"]=1.;p["movable_structure.attachments"][2]["eta"]=1.
    @test_throws r"main-box lateral stay needs an outboard rib" W.build_model(p)
    p=stay_parameters(;box=false,movable=true);p["movable_structure.surfaces"][1]["end_eta"]=.75
    @test_throws r"movable lateral stay needs an outboard rib" W.build_model(p)
    # Adjacent hinge coincident with the upper front cap: a requested movable
    # stay cannot duplicate the next hinge's dependent translations.
    p=stay_parameters(;box=false,movable=true)
    p["movable_surfaces.items"][1]["hinge_start"]=p["movable_surfaces.items"][1]["hinge_end"]=.78
    p["movable_surfaces.items"][1]["hinge_z_start"]=p["movable_surfaces.items"][1]["hinge_z_end"]=.5
    p["movable_structure.surfaces"][1]["span_bays"]=1
    @test_throws r"reuse translations already assigned" W.build_model(p)
    free=stay_parameters(;box=true,movable=true,actuator=false)
    @test_throws r"unrestrained movable-surface hinge" W.validate_movable_run(free;solution="101")
    @test W.validate_movable_run(free;solution="103")===nothing
end
write(joinpath(out,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>Test.get_test_counts(suite).passes+Test.get_test_counts(suite).cumulative_passes,"cases"=>reports)))
