using Test
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen
@testset "Request progress is bounded, isolated and optional" begin
    mktempdir() do dir
        params = merge(W.default_params(), Dict("box.rib_pitch"=>50.0,
            "box.stringer_pitch"=>50.0, "mesh.elements_between_ribs"=>1,
            "mesh.elements_spar_height"=>1, "mesh.aero_chord_points"=>9))
        input = joinpath(dir,"input.toml"); write(input, W.params_to_toml(params))
        state = W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(dir,"deck"))
        req = W.HTTP.Request("POST","/api/generate",["X-Wing-Activity"=>"client-a"],W.JSON.json(params))
        before = read(input)
        response = W.handle_generate(state,req)
        @test response.status == 200
        @test W.MsgPack.unpack(response.body)["checks_pass"]
        @test read(input) == before
        stage(id) = W.JSON.parse(String(W.handle_activity(state,W.HTTP.Request("GET","/api/activity?id=$id")).body))["stage"]
        @test stage("client-a") == W.ACTIVITY_STAGES["done"]
        events=W.JSON.parse(String(W.handle_activity(state,W.HTTP.Request("GET","/api/activity?id=client-a")).body))["events"]
        @test length(events)>=8
        @test [e["sequence"] for e in events]==collect(1:length(events))
        @test issorted([e["elapsed_seconds"] for e in events])
        @test events[end]["stage"]==W.ACTIVITY_STAGES["done"]
        @test events[1]["stage"]=="Preparing requested operation…"
        @test any(e->e["stage"]==W.ACTIVITY_STAGES["geometry"],events)
        @test stage("other") == ""
        for i in 1:100
            W.request_progress(state,W.HTTP.Request("POST","/api/generate",["X-Wing-Activity"=>"client-$i"]))("fuel")
        end
        @test length(state.activities) == 64
        @test length(state.activity_events)==64
        @test Set(keys(state.activity_events))==Set(keys(state.activities))
        @test stage("client-100") == W.ACTIVITY_STAGES["fuel"]
        n = length(state.activities)
        W.request_progress(state,W.HTTP.Request("POST","/api/generate"))("mesh")
        W.request_progress(state,W.HTTP.Request("POST","/api/generate",["X-Wing-Activity"=>repeat("a",97)]))("mesh")
        @test length(state.activities) == n
        bounded=W.request_progress(state,W.HTTP.Request("POST","/api/generate",["X-Wing-Activity"=>"bounded"]));bounded("fuel");bounded("fuel")
        @test length(state.activity_events["bounded"])==2
        for i in 1:300;bounded("step $i");end
        @test length(state.activity_events["bounded"])==256
        @test state.activity_events["bounded"][end]["sequence"]==302
    end
end
