using Test, WingFEGen
const SR=WingFEGen

@testset "Saved Study restores editable parameters without physical construction" begin
    p=SR.default_params()
    before=deepcopy(p)
    @test SR.canonical_study_parameters(p)
    restored,unknown=SR.restore_study_params(p)
    full,_=SR.normalize_params(p)
    @test isempty(unknown)
    @test restored==full
    @test p==before
    # A broken physical layout must remain editable. Generation still refuses it.
    bad=deepcopy(p);bad["box.rib_pitch"]=-1.
    @test first(SR.restore_study_params(bad))["box.rib_pitch"]==-1.
    @test_throws ArgumentError SR.normalize_params(bad)
    bad["airfoil.root"]="NACA_invalid"
    @test first(SR.restore_study_params(bad))["airfoil.root"]=="NACA_invalid"
    for value in (Inf,NaN,"NaN",Dict("bad"=>1),nothing)
        @test_throws ArgumentError SR.restore_study_params(merge(p,Dict("planform.area"=>value)))
    end
    @test_throws ArgumentError SR.restore_study_params(merge(p,Dict("loads.cases"=>[Dict("id"=>2,"speed"=>Inf)])))
    @test_throws ArgumentError SR.restore_study_params(merge(p,Dict("ribs.masters"=>"invalid")))
    @test !SR.canonical_study_parameters(Dict("planform.area"=>"12"))
    @test first(SR.restore_study_params(Dict("planform.area"=>"12")))["planform.area"]==12.
    encoded=merge(p,Dict("planform.area"=>"14"));@test !SR.canonical_study_parameters(encoded)
    @test first(SR.restore_study_params(encoded))["planform.area"]==14.
    modified=first(SR.restore_study_params(p));modified["loads.cases"]=Any[Dict("id"=>2)]
    @test p==before
    @test !SR.canonical_study_parameters(merge(p,Dict(first(SR.LEGACY_SECTION_KEYS)=>1)))
    @test !SR.canonical_study_parameters(merge(p,Dict("jfem.path"=>"legacy")))
    mktempdir() do temp
        input=joinpath(temp,"input.toml");write(input,SR.params_to_toml(p))
        st=SR.AppState(temp,input;deck_store_dir=joinpath(temp,"output"))
        params_before=deepcopy(st.params);disk_before=readdir(temp)
        req(value)=SR.HTTP.Request("POST","/api/restore_workspace",[],SR.JSON.json(value))
        response=SR.handle_restore_workspace(st,req(bad))
        @test response.status==200
        @test SR.JSON.parse(String(response.body))["parameters"]["box.rib_pitch"]==-1.
        @test_throws ArgumentError SR.validate_params(bad)
        @test SR.handle_restore_workspace(st,req(merge(p,Dict("unknown.key"=>1)))).status>=400
        @test SR.handle_restore_workspace(st,req([1,2,3])).status>=400
        @test SR.handle_restore_workspace(st,req(merge(p,Dict("ribs.masters"=>"invalid")))).status>=400
        @test st.params==params_before
        @test st.model===nothing
        @test st.latest_deck===nothing
        @test readdir(temp)==disk_before
    end
end

@testset "Geometry preview shares its Wing with identical movable surfaces" begin
    p=SR.default_params()
    p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>.2,"eta_end"=>.7,"front_spar_start"=>.72,"front_spar_end"=>.72,
        "hinge_start"=>.75,"hinge_end"=>.75,"hinge_z_start"=>-.7,"hinge_z_end"=>-.5,
        "deflection"=>12.,"color"=>"#ffcc00")]
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>1.,"twist"=>-3.)]
    geometry=Dict(k=>v for (k,v) in p if any(prefix->startswith(k,prefix),("planform.","airfoil.","loft.","movable_surfaces.")))
    old,_=SR.normalize_params(geometry)
    baseline=SR.movable_surfaces_preview(old)
    payload=SR.geometry_preview_payload(p)
    @test payload["geometry_only"]
    @test payload["movables"]==baseline
    @test payload["movables"]["surfaces"][1]["hinge"]==baseline["surfaces"][1]["hinge"]
    @test payload["movables"]["surfaces"][1]["xyz"]==baseline["surfaces"][1]["xyz"]
    @test payload["aero"]["count"]>0
    @test SR.movable_surfaces_preview(old;wing=SR.make_wing(old))==baseline
    # Preview depends on loft geometry, not incomplete structural edits/cases.
    p["box.rib_pitch"]=-1.;p["loads.cases"]="not an FE definition"
    @test SR.MsgPack.unpack(SR.MsgPack.pack(SR.geometry_preview_payload(p)))==SR.MsgPack.unpack(SR.MsgPack.pack(payload))
end
