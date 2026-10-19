using Test
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen
@testset "Shared archived-result decoder is served by Boxer" begin
    mktempdir() do directory
        input=joinpath(directory,"input.toml")
        write(input,W.params_to_toml(W.default_params()))
        app=dirname(@__DIR__)
        state=W.AppState(app,input;deck_store_dir=joinpath(directory,"decks"))
        response=W.make_router(state)(W.HTTP.Request("GET","/shared/jfem_binary.js"))
        @test response.status==200
        @test W.HTTP.header(response,"Content-Type")=="application/javascript; charset=utf-8"
        @test response.body==read(joinpath(dirname(app),"jfem_binary.js"))
        @test state.model===nothing
        @test isempty(state.jobs)
    end
end
