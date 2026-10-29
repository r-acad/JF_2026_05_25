using WingFEGen, Test, JSON, MsgPack
const W=WingFEGen
@testset "Independent authored geometry" begin
    p=W.default_params();p["box.rib_pitch"]=0.;p["material.E"]="unfinished";original=deepcopy(p)
    data=W.geometry_preview_payload(p)
    @test p==original
    @test data["geometry_only"]
    @test !haskey(data,"nodes")&&!haskey(data,"groups")
    @test data["aero"]["count"]>0
    @test all(isfinite,reinterpret(Float32,data["aero"]["xyz"].bytes))
    shifted=copy(p);shifted["planform.root_ref_z"]=2.
    next=W.geometry_preview_payload(shifted)
    @test next["aero"]["conn"].bytes==data["aero"]["conn"].bytes
    a=reinterpret(Float32,data["aero"]["xyz"].bytes);b=reinterpret(Float32,next["aero"]["xyz"].bytes)
    @test maximum(abs.(b[3:3:end].-a[3:3:end].-2))<1e-5
    @test maximum(abs.(b[1:3:end].-a[1:3:end]))==0
    @test next["bbox"]["min"][3]≈data["bbox"]["min"][3]+2
    @test_throws Exception W.geometry_preview_payload(merge(p,Dict("planform.area"=>-1.)))
    mktempdir() do dir
        input=joinpath(dir,"input.toml");write(input,W.params_to_toml(W.default_params()))
        st=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(dir,"store"));before=deepcopy(st.params)
        response=W.handle_geometry_preview(st,W.HTTP.Request("POST","/api/geometry_preview",[],JSON.json(p)))
        @test response.status==200
        @test st.model===nothing
        @test st.params==before
        @test MsgPack.unpack(response.body)["geometry_only"]
    end
end
