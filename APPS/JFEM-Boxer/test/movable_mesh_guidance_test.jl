using Test, WingFEGen
const W=WingFEGen
@testset "Movable geometry proportions warn without removing physical stations" begin
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.14,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>21,
        "loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[]))
    p["movable_surfaces.items"]=[Dict("name"=>"Test control","kind"=>"aileron","edge"=>"trailing","eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>.72,"hinge_end"=>.72,"front_spar_start"=>.8,"front_spar_end"=>.8,"hinge_z_start"=>0.,"hinge_z_end"=>0.,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Test control","span_bays"=>3,"span_elements"=>2,"chord_elements"=>4,"height_elements"=>2,"secondary_spar"=>.999))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Test control","eta"=>eta,"fitting"=>"shell_lugs","actuator"=>true)) for eta in (.25,.75)]
    p=first(W.normalize_params(p));snapshot=deepcopy(p)
    m=W.build_model(p)
    @test m.mesh_quality["status"]=="warning"
    @test m.mesh_quality["analysis_allowed"]
    @test p==snapshot
    @test .999 in W.movable_chord_stations(p["movable_structure.surfaces"][1])
    issues=filter(i->get(i,"rib_reference","")=="movable",m.mesh_quality["issues"])
    @test !isempty(issues)
    @test all(i->i["surface"]=="Test control"&&i["severity"]=="warning",issues)
    @test maximum(i["maximum_edge_ratio"] for i in issues)>100
    actions=filter(a->a["kind"]=="review_movable_rib_bay",m.mesh_quality["actions"])
    @test length(actions)==1
    @test occursin("Structure / Movable surfaces",only(actions)["message"])
    @test all(a->!a["automatic"],actions)
    @test W.model_for_load_case(m,first(W.case_loads(m))).mesh_quality==m.mesh_quality
    mktempdir() do directory
        result=W.write_reference(m,joinpath(directory,"valid_with_warnings.bdf"))
        @test result["ok"]
        @test result["mesh_quality"]==m.mesh_quality
        @test isfile(result["path"])
    end
    @test any(row->first(row)=="Mesh quality warnings",m.info)
    q=deepcopy(p);q["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.500000001,"twist"=>1.),Dict("eta"=>1.,"twist"=>0.)]
    stations=W.movable_span_stations(W.make_wing(q),q["movable_structure.surfaces"][1],[0.,.5,1.])
    @test .5 in stations&&.500000001 in stations
    slender=(;xyz=[0.,0.,0.,1.,0.,0.,0.,.0001,0.])
    @test W.validate_movable_skin_cell(slender,[1,2,3],"test control")===nothing
    folded=(;xyz=[0.,0.,0.,1.,0.,0.,1.,1.,0.,0.,1.,0.])
    @test_throws ArgumentError W.validate_movable_skin_cell(folded,[1,3,2,4],"test control")
end
