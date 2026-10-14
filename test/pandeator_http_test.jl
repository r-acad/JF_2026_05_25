module PandeatorHTTPTests

using Test
include(joinpath(@__DIR__, "..", "APPS", "PANDEATOR_APP", "panel_server.jl"))

@testset "PANDEATOR shared HTTP environment binds, serves, and releases its port" begin
    server = _bind_http_server("127.0.0.1", 0)
    port = HTTP.port(server)
    try
        @test port > 0
        @test isopen(server)
        for route in ("/", "/health", "/vendor/msgpack.min.js", "/vendor/babylon.js", "/jfem_binary.js")
            response = HTTP.get("http://127.0.0.1:$port$route";
                proxy=HTTP.ProxyConfig(), request_timeout=30)
            @test response.status == 200
            @test !isempty(response.body)
        end
        response = HTTP.request("OPTIONS", "http://127.0.0.1:$port/analyze";
            proxy=HTTP.ProxyConfig(), request_timeout=30)
        @test response.status == 204
        # Exercise the real POST dispatch while rejecting its payload before
        # any solver work or result-directory creation can occur.
        response = HTTP.post("http://127.0.0.1:$port/analyze",
            ["Content-Type"=>"application/msgpack"], MsgPack.pack([1, 2]);
            proxy=HTTP.ProxyConfig(), request_timeout=30, status_exception=false)
        @test response.status == 500
        @test occursin("request body must be a msgpack map", MsgPack.unpack(response.body)["error"])
        # HTTP 2's default cap would reject this before dispatch with 413.
        # An unknown route avoids running a model while checking the previous
        # large-deck request policy over an actual localhost connection.
        response = HTTP.post("http://127.0.0.1:$port/unknown",
            ["Content-Type"=>"application/octet-stream"], zeros(UInt8, 64*1024*1024+1);
            proxy=HTTP.ProxyConfig(), request_timeout=30, status_exception=false)
        @test response.status == 404
        @test_throws HTTP.AddressInUseError _bind_http_server("127.0.0.1", port)
    finally
        HTTP.forceclose(server)
        wait(server)
    end
    @test !isopen(server)
    replacement = _bind_http_server("127.0.0.1", port)
    try
        @test HTTP.port(replacement) == port
    finally
        HTTP.forceclose(replacement)
        wait(replacement)
    end
end

end
