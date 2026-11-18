using Test,WingFEGen
const W=WingFEGen
function material_fixture()
    property=Dict("type"=>"PSHELL","thickness_m"=>.002,"material_id"=>1,
        "material"=>Dict("id"=>1,"type"=>"MAT1","E_Pa"=>70e9,"nu"=>.3))
    face(stress)=Dict("von_mises"=>stress,"normal_x"=>stress,"normal_y"=>0.,"shear_xy"=>0.)
    elements=Dict(string(id)=>Dict("group"=>Dict("kind"=>"quad","name"=>"skin","pid"=>7,"properties"=>deepcopy(property))) for id in 1:3)
    cases=Dict(string(case)=>Dict("analysis"=>"SOL101","static"=>true,"matches"=>true,"available"=>true,
        "elementResults"=>Dict(string(id)=>Dict("stress"=>Dict("z1"=>face(stress/case),"z2"=>face(stress/case)))
            for (id,stress) in enumerate((10e6,100e6,300e6)))) for case in 1:2)
    Dict{String,Any}("elements"=>elements,"cases"=>cases,"method"=>"maximum","percentile"=>95.,
        "allowables"=>[Dict("material_id"=>1,"mode"=>"stress","stress"=>150e6)],
        "assessmentPolicy"=>Dict("strengthSafetyFactor"=>1.5,"bucklingPolicyFactor"=>1.),
        "materialRegions"=>[Dict("key"=>"plain:first","pid"=>7,"member_element_ids"=>[1],"label"=>"First plate"),
            Dict("key"=>"plain:second","pid"=>7,"member_element_ids"=>[2],"label"=>"Second plate")])
end
function responses(input;derivatives=false)
    W.rf_assessment_values(input;derivatives)["responses"]
end
@testset "Exact material subdomains preserve actual properties" begin
    input=material_fixture();rows=responses(input)
    by=Dict(row["response_id"]=>row for row in rows)
    @test length(rows)==6
    @test by["material:P7:1:default"]["raw_RF"]≈1/3
    @test by["material_region:plain:first:P7:1:default"]["raw_RF"]≈10
    @test by["material_region:plain:second:P7:1:default"]["raw_RF"]≈1
    @test by["material_region:plain:first:P7:2:default"]["raw_RF"]≈20
    @test by["material_region:plain:first:P7:1:default"]["membership_eids"]==[1]
    @test by["material_region:plain:first:P7:1:default"]["membership_pids"]==[7]
    @test by["material_region:plain:first:P7:1:default"]["material_region_key"]=="plain:first"
    @test material_fixture()==input
    scoped=deepcopy(input);scoped["response_ids"]=["material_region:plain:first:P7:1:default"];scoped["restrict_responses"]=true
    @test length(responses(scoped))==1
    @test only(responses(scoped))["raw_RF"]≈10
    packet=W.rf_report_assessment(input)
    @test length(packet["assessment"]["responses"])==6
end
@testset "Every statistic is computed inside the explicit domain" begin
    for method in ("maximum","mean","trimmed_mean")
        input=material_fixture();input["method"]=method;input["percentile"]=50.
        input["materialRegions"][1]["member_element_ids"]=[1,2]
        row=only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",responses(input)))
        expected=method=="maximum" ? 1. : method=="mean" ? 150/1.5/55 : 10.
        @test row["raw_RF"]≈expected
        @test row["stress_statistics"]["total"]==2
        @test !(3 in row["membership_eids"])
    end
end
@testset "Bad membership cannot be silently reduced to a passing subset" begin
    for ids in (Int[],[1,1],[1,99])
        input=material_fixture();input["materialRegions"][1]["member_element_ids"]=ids
        row=only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",responses(input)))
        @test row["status"]=="unavailable"
        @test row["raw_RF"]===nothing
    end
    input=material_fixture();input["elements"]["2"]["group"]["pid"]=8
    row=only(filter(r->r["response_id"]=="material_region:plain:second:P7:1:default",responses(input)))
    @test row["status"]=="unavailable"
    input=material_fixture();push!(input["materialRegions"],deepcopy(input["materialRegions"][1]))
    target=filter(r->r["physical_criterion_id"]=="material_region:plain:first:P7",responses(input))
    @test length(target)==2
    @test all(r->r["status"]=="unavailable",target)
    input=material_fixture();delete!(input["cases"]["1"]["elementResults"],"1")
    @test only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",responses(input)))["status"]=="unavailable"
end
@testset "Local derivatives refer only to actual members and real PID capacities" begin
    input=material_fixture();rows=responses(input;derivatives=true)
    row=only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",rows))
    @test row["status"]=="ok"
    @test all(k->k["eid"]==1,row["feature_keys"])
    forcekeys=("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2")
    forces=Dict(key=>(key=="axial" ? 1000. : 0.) for key in forcekeys);dims=[.01,.02]
    property=Dict("type"=>"PBARL","material_id"=>1,"material"=>Dict("id"=>1,"type"=>"MAT1"),"section"=>Dict("shape"=>"BAR","dimensions_m"=>dims))
    input["elements"]=Dict("1"=>Dict("group"=>Dict("kind"=>"bar","name"=>"cap","pid"=>7,"properties"=>property)))
    for item in values(input["cases"]);item["elementResults"]=Dict("1"=>Dict("forces"=>deepcopy(forces),"stress"=>Dict("von_mises"=>W.rf_beam_equivalent("BAR",[forces[k] for k in forcekeys],dims,0.))));end
    resize!(input["materialRegions"],1)
    row=only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",responses(input;derivatives=true)))
    @test row["raw_RF"]≈20
    dimensional=filter(k->get(k,"kind","")=="beam_dimension",row["capacity_keys"])
    @test length(dimensional)==2
    @test all(k->k["pid"]==7,dimensional)
end
@testset "A complete zero-demand local material criterion is explicitly marked" begin
    input=material_fixture()
    for item in values(input["cases"]),record in values(item["elementResults"]),face in values(record["stress"]),key in keys(face);face[key]=0.;end
    rows=responses(input)
    @test all(r->r["status"]=="ok"&&r["no_demand"]===true,rows)
end
@testset "Homogeneous laminate principal strain remains local to actual members" begin
    input=material_fixture()
    property=Dict("type"=>"PCOMP","plies"=>[Dict("material_id"=>2,"material"=>Dict("id"=>2,"type"=>"MAT8"))])
    for element in values(input["elements"]);element["group"]["properties"]=deepcopy(property);end
    input["allowables"]=[Dict("material_id"=>2,"mode"=>"strain","strain_tension"=>.006,"strain_compression"=>.004)]
    for item in values(input["cases"])
        records=Dict{String,Any}()
        for id in keys(item["elementResults"])
            e1=parse(Int,id)==1 ? .001 : .01
            face=Dict("e1"=>e1,"e2"=>0.,"g12"=>0.)
            records[id]=Dict("strain"=>Dict("ply_faces_complete"=>true,"ply_faces_coordinate_system"=>"ply material 1/2 axes",
                "ply_faces"=>[Dict("ply"=>1,"material_id"=>2,"bottom"=>deepcopy(face),"top"=>deepcopy(face))]))
        end
        item["elementResults"]=records
    end
    rows=responses(input;derivatives=true)
    localrow=only(filter(r->r["response_id"]=="material_region:plain:first:P7:1:default",rows))
    globalrow=only(filter(r->r["response_id"]=="material:P7:1:default",rows))
    @test localrow["status"]=="ok"
    @test localrow["failure_mode"]=="principal_strain"
    @test localrow["raw_RF"]≈4
    @test globalrow["raw_RF"]≈.4
    @test all(k->k["eid"]==1,localrow["feature_keys"])
end
