# Native laminated-web responses for committed layer-minimum sizing.
using Test, JSON, WingFEGen
const W=WingFEGen
length(ARGS)==1 || error("Provide a private output directory")
out=abspath(only(ARGS));mkpath(out)
@testset "Committed layer minima preserve native web membership and increase stiffness" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"loads.cases"=>Any[],
        "loads.method"=>"analytic","loads.lift_total"=>100.,"output.solution"=>"101",
        "stringers.model"=>"beam",
        "materials.library"=>[Dict("id"=>3,"name"=>"Test core","E"=>1e8,"nu"=>.3,"rho"=>80.)],
        "materials.shells"=>[Dict("component"=>"spar_web","kind"=>"sandwich","face_thickness"=>.0005,"core_thickness"=>.003,"face_material"=>1,"core_material"=>3)],
        "properties.spar_bays"=>[Dict("bay"=>1,"front_thickness"=>.0048,"rear_thickness"=>.009)],
        "properties.components"=>[Dict("key"=>"front_web:1","face_thickness"=>.0008,"core_thickness"=>.0032,"face_material"=>1,"core_material"=>3),
            Dict("key"=>"rear_web:1","face_thickness"=>.0015,"core_thickness"=>.006,"face_material"=>1,"core_material"=>3)]))
    m=W.build_model(first(W.normalize_params(p)));original=deepcopy(m.params);xyz=copy(m.xyz);changed=deepcopy(original);stages=Any[]
    for(field,value) in (("face_thickness",.0012),("core_thickness",.004))
        assignment=only(changed["materials.shells"]);assignment[field]=value
        for row in changed["properties.components"]
            haskey(row,field)&&(row[field]=max(row[field],value))
        end
        floor=2assignment["face_thickness"]+assignment["core_thickness"]
        for row in changed["properties.spar_bays"],key in ("front_thickness","rear_thickness");row[key]=max(row[key],floor);end
        response=W.rf_section_update(m,first(W.normalize_params(changed)))
        @test response["fixed_geometry"]
        @test m.xyz==xyz
        @test m.params==original
        web=only(filter(row->row["key"]=="front_web:1",response["component_buckling"]["web_panels"]))
        @test all(e->isapprox(e["thickness_m"],2changed["properties.components"][1]["face_thickness"]+changed["properties.components"][1]["core_thickness"]),web["elements"])
        push!(stages,Dict("component"=>"spar_web","field"=>field,"value"=>value,"parameters"=>deepcopy(changed),"response"=>response))
    end
    write(joinpath(out,"schema.json"),JSON.json(W.schema_payload(original,"layer-minimum-fixture.toml")))
    write(joinpath(out,"params.json"),JSON.json(original))
    write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
    write(joinpath(out,"stages.json"),JSON.json(stages))
end
