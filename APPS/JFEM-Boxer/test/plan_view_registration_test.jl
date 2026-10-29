using Test, JSON

module PlanViewRegistrationFixture
using JSON
include(joinpath(@__DIR__, "..", "src", "plan_view_state.jl"))
end

@testset "2D registration and display metadata round trips" begin
    F = PlanViewRegistrationFixture
    image = Dict("name" => "pixel.png", "dataUrl" => "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=", "width" => 1, "height" => 1)
    pin = Dict("image" => Dict("x" => 0.25, "y" => 0.75), "drawing" => Dict("x" => 23.0, "y" => -15.0))
    value = Dict("version" => 1, "image" => image, "pin" => pin, "filledFigures" => false, "imageAspectRatio" => 2.5,
        "transform" => Dict("x" => 22.5, "y" => -16.5, "scale" => 2.0),
        "viewport" => Dict("x" => 90.0, "y" => -32.0, "scale" => 1.75))
    normalized = JSON.parse(F.normalize_plan_view(JSON.json(value)))
    @test normalized["imageAspectRatio"] == 2.5
    @test normalized["pin"] == pin
    @test normalized["filledFigures"] === false
    @test normalized["viewport"] == value["viewport"]
    @test normalized["imageScope"] == "local"
    @test JSON.parse(F.normalize_plan_view(JSON.json(normalized))) == normalized
    legacy = JSON.parse(F.normalize_plan_view("{}"))
    @test legacy["imageAspectRatio"] === nothing
    @test legacy["pin"] === nothing
    @test legacy["filledFigures"] === true
    @test legacy["imageScope"] == "shared"
    for name in ("planform", "airfoil-root", "spars", "stringer-layout", "material-stringer_flange")
        roundtrip = JSON.parse(F.normalize_drawings(JSON.json(Dict(name => value))))
        @test roundtrip[name]["imageAspectRatio"] == 2.5
        @test roundtrip[name]["pin"] == pin
        @test roundtrip[name]["filledFigures"] === false
        @test JSON.parse(F.normalize_drawings(JSON.json(roundtrip))) == roundtrip
    end
    shared = merge(value, Dict("imageScope"=>"shared"))
    independent = merge(value, Dict("imageScope"=>"local"))
    views = JSON.parse(F.normalize_drawings(JSON.json(Dict("shared-plan-reference"=>shared,"planform"=>Dict("imageScope"=>"shared"),"spars"=>independent))))
    @test views["shared-plan-reference"]["image"] == image
    @test views["shared-plan-reference"]["imageScope"] == "shared"
    @test views["planform"]["image"] === nothing
    @test views["planform"]["imageScope"] == "shared"
    @test views["spars"]["image"] == image
    @test views["spars"]["imageScope"] == "local"
    @test JSON.parse(F.normalize_drawings(JSON.json(views))) == views
    @test_throws ArgumentError F.normalize_plan_view(JSON.json(merge(value,Dict("imageScope"=>"invalid"))))
    for bad in (merge(value, Dict("imageAspectRatio" => 0)), merge(value, Dict("imageAspectRatio" => 1001)), merge(value, Dict("imageAspectRatio" => true)), merge(value, Dict("filledFigures" => 1)), merge(value, Dict("image" => nothing)),
        merge(value, Dict("pin" => Dict("image" => pin["image"]))),
        merge(value, Dict("pin" => Dict("image" => Dict("x" => -1, "y" => 0), "drawing" => pin["drawing"]))),
        merge(value, Dict("pin" => Dict("image" => pin["image"], "drawing" => Dict("x" => 1e8, "y" => 0)))))
        @test_throws ArgumentError F.normalize_plan_view(JSON.json(bad))
        @test_throws ArgumentError F.normalize_drawings(JSON.json(Dict("planform" => bad)))
    end
end

@testset "Image visibility persists independently of opacity and alignment" begin
    F=PlanViewRegistrationFixture
    input=Dict("imageVisible"=>false,"opacity"=>.7,"transform"=>Dict("x"=>12.,"y"=>5.,"scale"=>2.))
    saved=JSON.parse(F.normalize_plan_view(JSON.json(input)))
    @test saved["imageVisible"]===false
    @test saved["opacity"]==.7
    @test saved["transform"]==input["transform"]
    @test JSON.parse(F.normalize_plan_view("{}"))["imageVisible"]===true
    drawing=JSON.parse(F.normalize_drawings(JSON.json(Dict("spars"=>input))))
    @test drawing["spars"]["imageVisible"]===false
    @test_throws ArgumentError F.normalize_plan_view(JSON.json(Dict("imageVisible"=>0)))
end
