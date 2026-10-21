using Test, HTTP
const viewer_packages_before=Set(keys(Base.loaded_modules))
include(joinpath(@__DIR__,"..","julia_tools","serve_results_viewer.jl"))
const ViewerServer=JFEMResultsViewerServer

@testset "Lightweight local results viewer server" begin
    @test ViewerServer.options(String[])==(;port=0,browser=true)
    @test ViewerServer.options(["--no-browser","--port","43988"])==(;port=43988,browser=false)
    @test ViewerServer.options(["--port=0"]).port==0
    @test ViewerServer.options(["--help"])===nothing
    @test_throws ErrorException ViewerServer.options(["--port"])
    @test_throws ErrorException ViewerServer.options(["--port=-1"])
    @test_throws ErrorException ViewerServer.options(["--port=65536"])
    @test_throws ErrorException ViewerServer.options(["--port=abc"])
    @test_throws ErrorException ViewerServer.options(["--unknown"])
    @test ViewerServer.handle(HTTP.Request("GET","/")).status==302
    @test ViewerServer.handle(HTTP.Request("GET","/health")).status==200
    for relative in ViewerServer.ASSET_PATHS
        response=ViewerServer.handle(HTTP.Request("GET","/"*relative))
        @test response.status==200
        @test !isempty(response.body)
        if endswith(relative,".wasm")
            @test HTTP.header(response,"Content-Type")=="application/wasm"
        end
    end
    for target in ("/Project.toml","/src/OpenJFEM.jl","/output/results.jfem",
        "/APPS/PANDEATOR_APP/panel_server.jl","/APPS/PANDEATOR_APP/vendor/../../../Project.toml",
        "/APPS/PANDEATOR_APP/vendor/%2e%2e/%2e%2e/%2e%2e/Project.toml")
        @test ViewerServer.handle(HTTP.Request("GET",target)).status==404
    end
    @test ViewerServer.handle(HTTP.Request("POST",ViewerServer.VIEWER_PATH)).status==405
    @test isempty(ViewerServer.handle(HTTP.Request("HEAD",ViewerServer.VIEWER_PATH)).body)
    mktempdir() do empty_root
        @test_throws ErrorException ViewerServer.start_server(;root=empty_root)
    end
    server=ViewerServer.start_server()
    try
        @test HTTP.port(server)>0
        base="http://127.0.0.1:$(HTTP.port(server))"
        @test String(HTTP.get(base*"/health").body)=="results-viewer ready"
        @test occursin("JFEMGraphics.bootInline",String(HTTP.get(base*ViewerServer.VIEWER_PATH).body))
        @test occursin("WebGPUEngine",String(HTTP.get(base*"/APPS/jfem_graphics.js").body))
        response=HTTP.get(base*"/APPS/PANDEATOR_APP/vendor/twgsl/twgsl.wasm")
        @test HTTP.header(response,"Content-Type")=="application/wasm"
        @test response.body[1:4]==[0x00,0x61,0x73,0x6d]
    finally
        close(server)
    end
    @test !any(id->id.name in ("OpenJFEM","WingFEGen"),setdiff(Set(keys(Base.loaded_modules)),viewer_packages_before))
end
