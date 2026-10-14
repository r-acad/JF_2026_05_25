module SharedAppEnvironmentTests

using Test, OpenJFEM, WingFEGen, HTTP, JSON, ForwardDiff
const W = WingFEGen

@testset "Boxer listener accepts large study bodies and skips occupied ports" begin
    router = HTTP.Router()
    HTTP.register!(router, "POST", "/body_size",
        request -> HTTP.Response(200, string(length(request.body))))
    server = W._start_app_server(router, 0)
    replacement = nothing
    try
        port = HTTP.port(server)
        @test port > 0
        # Use the production listener and a real Router body handler. The old
        # implicit HTTP 2 cap rejects this payload before the handler runs.
        payload = zeros(UInt8, 64*1024*1024+1)
        response = HTTP.post("http://127.0.0.1:$port/body_size", [], payload;
            proxy=HTTP.ProxyConfig(), request_timeout=30)
        @test response.status == 200
        @test parse(Int, String(response.body)) == length(payload)
        replacement = W._start_app_server(router, port)
        @test port < HTTP.port(replacement) <= port+20
        response = HTTP.post("http://127.0.0.1:$(HTTP.port(replacement))/body_size", [], "abc";
            proxy=HTTP.ProxyConfig(), request_timeout=30)
        @test String(response.body) == "3"
    finally
        if replacement !== nothing
            HTTP.forceclose(replacement)
            wait(replacement)
        end
        HTTP.forceclose(server)
        wait(server)
    end
    @test !isopen(server)
end

@testset "JFEM and Boxer use one package graph for native and aerodynamic work" begin
    @test W.HTTP === HTTP
    @test W.JSON === JSON
    @test OpenJFEM.JSON === JSON
    @test OpenJFEM.ForwardDiff === ForwardDiff
    @test W.VortexLattice.CCBlade.ImplicitAD.ForwardDiff === ForwardDiff
    @test W.read_input(joinpath(dirname(dirname(pathof(W))), "examples", "wing_default.toml")) == W.default_params()

    p = merge(W.default_params(), Dict{String,Any}(
        "planform.area"=>2., "planform.aspect_ratio"=>2., "planform.taper_ratio"=>.8,
        "box.rib_pitch"=>.6, "box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1, "mesh.elements_spar_height"=>1,
        "mesh.aero_chord_points"=>9, "airfoil.n_points"=>31,
        "loads.method"=>"vortex_lattice", "loads.cases"=>Any[],
        "aero.span_panels"=>4, "aero.chord_panels"=>2,
        "aero.speed"=>100., "aero.alpha"=>2., "aero.altitude"=>3000.,
        "fuel.enabled"=>false))
    model = W.build_model(p)
    @test W.all_checks_pass(model)
    loads = only(W.case_loads(model)).loads
    @test all(isfinite, loads.summary["force_N"])
    @test any(!iszero, loads.summary["force_N"])
    @test loads.summary["q_Pa"] ≈ W.flight_condition(p)["q_Pa"]
    @test loads.summary["Mach"] ≈ W.flight_condition(p)["Mach"]
    @test loads.summary["flight_condition"]["altitude_geometric_m"] == 3000.
end

end
