# Property-chain validation only; no FE equilibrium solves are needed.
using Test, JSON, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);p=JSON.parsefile(joinpath(out,"beam","params.json"))
m=W.build_model(first(W.normalize_params(p)))
checks=@testset "Sensitivity at a minimum gauge" begin
    catalog=W.sensitivity_catalog(m)
    descriptors=catalog["variables"]
    properties=W.model_property_definitions(m)
    shell=first(d for d in descriptors if startswith(d["id"],"properties.panels#")&&endswith(d["id"],"#skin#thickness"))
    bar=first(d for d in descriptors if startswith(d["id"],"properties.panels#")&&endswith(d["id"],"#stringer#web_thickness"))
    component=only(d for d in descriptors if d["id"]=="properties.components#front_web:1#thickness")
    for descriptor in (shell,bar,component)
        h=descriptor["value"]*.001
        plus=W.sensitivity_set!(deepcopy(m.params),descriptor,descriptor["value"]+h)
        minus=W.sensitivity_set!(deepcopy(m.params),descriptor,descriptor["value"]-h)
        @test W.validate_params(plus)===nothing
        @test_throws ArgumentError W.validate_params(minus)
        stencil=W.sensitivity_stencil(m,descriptor,.001)
        @test stencil.direction==1
        @test occursin("Forward",stencil.warning)
        affected=filter(property->property["pid"] in descriptor["pids"],properties)
        @test !isempty(affected)
        for property in affected
            enriched=W.sensitivity_analytic_property_direction(m,descriptor,property)
            plain=copy(property);delete!(plain,"minimum_gauge")
            @test enriched==W.sensitivity_analytic_property_direction(m,descriptor,plain)
            @test enriched["active"]
            property["kind"]=="shell" ? (@test enriched["thickness"]==1.) : (@test enriched["dimensions"][4]==1.)
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"sensitivity_summary.json"),JSON.json(Dict("passed"=>counts.passes+counts.cumulative_passes,"failed"=>counts.fails+counts.cumulative_fails,"errors"=>counts.errors+counts.cumulative_errors)))
