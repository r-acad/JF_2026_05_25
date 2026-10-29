using Test, WingFEGen
const W=WingFEGen

@testset "Fixed-load sizing updates sections without building a FEM" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.08,"airfoil.root"=>"NACA0012",
        "airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"loads.structure_inertia"=>false))
    m=W.build_model(first(W.normalize_params(p)))
    xyz=copy(m.xyz);source=deepcopy(m.params);groups=[(g.pid,copy(g.conn),copy(g.eids)) for g in m.groups]
    for factor in (1.5,3.)
        edited=deepcopy(source);edited["properties.t_skin_upper"]*=factor
        update=W.rf_section_update(m,edited)
        @test update["fixed_geometry"]
        upper=filter(g->W.component_base_pid(g["pid"])==W.PID_SKIN_UPPER,update["groups"])
        @test !isempty(upper)
        @test all(g->isapprox(g["properties"]["thickness_m"],factor*source["properties.t_skin_upper"]),upper)
        @test update["stiffened_panels"]["layout_token"]==W.panel_layout_token(m.grid,W.stiffened_panel_layout(m.grid))
        @test m.params==source && m.xyz==xyz
        @test [(g.pid,g.conn,g.eids) for g in m.groups]==groups
    end
    for (key,value) in (("box.stringer_pitch",.1),("properties.rib_stiffeners_enabled",false),("loads.lift_total",123.))
        edited=deepcopy(source);edited[key]=value
        @test_throws ArgumentError W.rf_section_update(m,edited)
    end
    equivalent=deepcopy(source)
    for key in ("planform.leading_edge_points","planform.trailing_edge_points","box.front_spar_points","box.rear_spar_points")
        equivalent[key]=[merge(Dict("eta"=>eta,"dxc"=>0.),key=="box.rear_spar_points" ? Dict("stringer_angle"=>0.) : Dict()) for eta in (0.,1.)]
    end
    equivalent["sensitivity.settings"]="{}"
    @test W.rf_section_update(m,equivalent)["fixed_geometry"]
    equivalent["box.front_spar_points"][1]["dxc"]=.01
    @test_throws ArgumentError W.rf_section_update(m,equivalent)
    shell=deepcopy(p);shell["stringers.model"]="shell";shell["mesh.elements_stringer_height"]=2
    sm=W.build_model(first(W.normalize_params(shell)))
    edited=deepcopy(sm.params);edited["properties.stringer_height"]*=1.1
    @test_throws ArgumentError W.rf_section_update(sm,edited)
end
