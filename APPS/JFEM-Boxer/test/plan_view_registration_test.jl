using Test, JSON

module PlanViewRegistrationFixture
using JSON
include(joinpath(@__DIR__, "..", "src", "plan_view_state.jl"))
end

@testset "2D registration and display metadata round trips" begin
    F = PlanViewRegistrationFixture
    image = Dict("name" => "pixel.png", "dataUrl" => "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=", "width" => 1, "height" => 1)
    pin = Dict("image" => Dict("x" => 0.25, "y" => 0.75), "drawing" => Dict("x" => 23.0, "y" => -15.0))
    value = Dict("version" => 1, "image" => image, "pin" => pin, "filledFigures" => false,
        "transform" => Dict("x" => 22.5, "y" => -16.5, "scale" => 2.0),
        "viewport" => Dict("x" => 90.0, "y" => -32.0, "scale" => 1.75))
    normalized = JSON.parse(F.normalize_plan_view(JSON.json(value)))
    @test normalized["pin"] == pin
    @test normalized["filledFigures"] === false
    @test normalized["viewport"] == value["viewport"]
    @test JSON.parse(F.normalize_plan_view(JSON.json(normalized))) == normalized
    legacy = JSON.parse(F.normalize_plan_view("{}"))
    @test legacy["pin"] === nothing
    @test legacy["filledFigures"] === true
    for name in ("planform", "airfoil-root", "spars", "material-stringer_flange")
        roundtrip = JSON.parse(F.normalize_drawings(JSON.json(Dict(name => value))))
        @test roundtrip[name]["pin"] == pin
        @test roundtrip[name]["filledFigures"] === false
        @test JSON.parse(F.normalize_drawings(JSON.json(roundtrip))) == roundtrip
    end
    for bad in (merge(value, Dict("filledFigures" => 1)), merge(value, Dict("image" => nothing)),
        merge(value, Dict("pin" => Dict("image" => pin["image"]))),
        merge(value, Dict("pin" => Dict("image" => Dict("x" => -1, "y" => 0), "drawing" => pin["drawing"]))),
        merge(value, Dict("pin" => Dict("image" => pin["image"], "drawing" => Dict("x" => 1e8, "y" => 0)))))
        @test_throws ArgumentError F.normalize_plan_view(JSON.json(bad))
        @test_throws ArgumentError F.normalize_drawings(JSON.json(Dict("planform" => bad)))
    end
end
