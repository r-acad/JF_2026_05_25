using Test, Logging
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen

@testset "Last-created deck snapshot persistence" begin
    mktempdir() do tmp
        app = normpath(joinpath(@__DIR__, ".."))
        store = joinpath(tmp, "saved_deck")
        p = merge(W.default_params(), Dict("box.rib_pitch"=>50.0, "box.stringer_pitch"=>50.0,
            "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
            "output.reference_file"=>joinpath(tmp,"original.bdf")))
        input = joinpath(tmp,"first.toml"); write(input,W.params_to_toml(p))
        st = W.AppState(app,input;deck_store_dir=store)
        request(route,values=p) = W.HTTP.Request("POST",route,[],W.JSON.json(values))
        latest(state=st) = W.JSON.parse(String(W.handle_last_deck(state,W.HTTP.Request("GET","/api/last_deck")).body))
        @test !latest()["available"]
        @test W.handle_last_deck(st,W.HTTP.Request("GET","/api/last_deck/download");download=true).status==404
        response = W.handle_reference(st,request("/api/reference"))
        @test response.status==200
        written=W.JSON.parse(String(response.body)); first=latest()["deck"]
        @test first["deck_text"]==written["deck_text"]==read(p["output.reference_file"],String)
        @test first["sha256"]==written["deck_metadata"]["sha256"]
        @test first["source"]=="Write deck"
        @test first["input_path"]==input

        # Preserve bytes even when the output file is changed or removed.
        write(p["output.reference_file"],"EXTERNALLY REPLACED")
        @test latest()["deck"]["deck_text"]==first["deck_text"]
        rm(p["output.reference_file"])
        other=merge(p,Dict("output.reference_file"=>joinpath(tmp,"different.bdf"),"box.stringer_angle"=>1.0))
        otherinput=joinpath(tmp,"second.toml");write(otherinput,W.params_to_toml(other))
        restarted=W.AppState(app,otherinput;deck_store_dir=store)
        @test latest(restarted)["deck"]==first
        @test !isfile(other["output.reference_file"])
        download=W.handle_last_deck(restarted,W.HTTP.Request("GET","/api/last_deck/download");download=true)
        @test String(download.body)==first["deck_text"]
        @test occursin("original.bdf",W.HTTP.header(download,"Content-Disposition"))

        # Bad new parameters and a filesystem write error cannot replace it.
        with_logger(NullLogger()) do
            @test W.handle_reference(restarted,request("/api/reference",merge(other,Dict("material.E"=>-1.0)))).status==400
            @test W.handle_reference(restarted,request("/api/reference",merge(other,Dict("output.reference_file"=>tmp)))).status==400
        end
        @test latest(restarted)["deck"]==first
        @test W.handle_reference(restarted,request("/api/reference",other)).status==200
        second=latest(restarted)["deck"]
        @test second["path"]==other["output.reference_file"]
        @test second["input_path"]==otherinput
        @test second["sha256"]!=first["sha256"]
        # Run also creates a deck before solver launch; invalid repo prevents
        # starting any process but its successfully written deck is retained.
        runparams=merge(other,Dict("jfem.repo"=>joinpath(tmp,"missing_solver"),"output.reference_file"=>joinpath(tmp,"run.bdf")))
        with_logger(NullLogger()) do
            @test W.handle_run_jfem(restarted,request("/api/run_jfem",runparams)).status==400
        end
        @test isempty(restarted.jobs)
        @test latest(restarted)["deck"]["source"]=="Run in JFEM"
        @test latest(restarted)["deck"]["path"]==runparams["output.reference_file"]
        @test latest(restarted)["deck"]["deck_text"]==read(runparams["output.reference_file"],String)
        # Another process/state observes the replacement rather than its old cache.
        @test latest(st)["deck"]==latest(restarted)["deck"]
        router=W.make_router(restarted)
        @test router(W.HTTP.Request("GET","/api/last_deck")).status==200
        @test router(W.HTTP.Request("GET","/api/last_deck/download")).status==200
    end
end
