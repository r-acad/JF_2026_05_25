using Test, TOML, JSON, LinearAlgebra
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W=WingFEGen
base=merge(W.default_params(),Dict{String,Any}(
    "planform.area"=>4.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>1.,
    "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
    "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.15,
    "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
    "leading_edge.enabled"=>true,"leading_edge.start_rib"=>2,"leading_edge.end_rib"=>4,
    "leading_edge.chord_elements"=>3,"leading_edge.rib_orientation"=>"front_spar_angle",
    "leading_edge.rib_angle"=>90.,"box.front_spar_points"=>[Dict("eta"=>.5,"dxc"=>.04)],
    "loads.cases"=>Any[]))
suite=@testset "Local front-spar reference and kink-side selection" begin
    pin=copy(base); pout=merge(base,Dict("leading_edge.rib_kink_side"=>"outboard"))
    mi=W.build_model(pin);mo=W.build_model(pout)
    ri=Dict(r["rib"]=>r for r in mi.le_rib_metadata);ro=Dict(r["rib"]=>r for r in mo.le_rib_metadata)
    @test sort(collect(keys(ri)))==[2,3,4]
    for records in (ri,ro),rib in (2,3,4)
        row=records[rib]
        @test !row["fallback"]
        @test abs(dot(row["reference_tangent"],row["plane_direction"]))<1e-12
        @test row["reference_eta"]≈(rib-1)/4
    end
    @test ri[2]["reference_segment_eta"]==[0.,.5]
    @test ri[4]["reference_segment_eta"]==[.5,1.]
    @test ri[3]["reference_segment_eta"]==[0.,.5]
    @test ro[3]["reference_segment_eta"]==[.5,1.]
    @test ri[2]["plane_direction"]≈ro[2]["plane_direction"]
    @test ri[4]["plane_direction"]≈ro[4]["plane_direction"]
    @test norm(ri[3]["plane_direction"]-ro[3]["plane_direction"])>.05
    # A per-rib choice overrides the global default and survives TOML/Study normalization.
    custom=merge(base,Dict("leading_edge.rib_orientations"=>[Dict("rib"=>3,"mode"=>"front_spar_angle","angle"=>90.,"kink_side"=>"outboard")]))
    restored=first(W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(custom)))))
    @test restored["leading_edge.rib_orientations"][1]["kink_side"]=="outboard"
    mc=W.build_model(restored)
    @test only(filter(r->r["rib"]==3,mc.le_rib_metadata))["plane_direction"]≈ro[3]["plane_direction"]
    @test_throws ArgumentError W.normalize_params(merge(base,Dict("leading_edge.rib_kink_side"=>"middle")))
    @test_throws ArgumentError W.normalize_rib_tables([Dict("rib"=>3,"mode"=>"front_spar_angle","kink_side"=>"middle")],"leading_edge.rib_orientations")
    # Non-flight main ribs attach at a front eta different from the rear anchor.
    angled=merge(base,Dict("leading_edge.enabled"=>false,"ribs.masters"=>[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>85.,"pitch"=>.5)]))
    ma=W.build_model(angled);rib=3;j=ma.grid.ribs[rib]
    plane=W.leading_edge_rib_plane(ma.grid,angled,j)
    eta=(W.leading_edge_front_eta(ma.grid,j,false)+W.leading_edge_front_eta(ma.grid,j,true))/2
    @test plane.reference.attachment_eta≈eta
    @test abs(eta-ma.grid.etas[j+1])>1e-4
    expected=W.leading_edge_reference(ma.wing,angled;eta)
    @test plane.reference.tangent == expected.tangent
    # Old no-kink definitions retain their geometry for either side.
    straight=merge(base,Dict("box.front_spar_points"=>Any[]))
    a=W.build_model(straight);b=W.build_model(merge(straight,Dict("leading_edge.rib_kink_side"=>"outboard")))
    @test a.xyz==b.xyz
    if !isempty(ARGS)
        mkpath(ARGS[1]);write(joinpath(ARGS[1],"schema.json"),JSON.json(W.schema_payload(base,"")));write(joinpath(ARGS[1],"local_spar_orientation.json"),JSON.json(Dict("inboard"=>mi.le_rib_metadata,"outboard"=>mo.le_rib_metadata,"angled_attachment_eta"=>eta,"rear_anchor_eta"=>ma.grid.etas[j+1])))
    end
end
