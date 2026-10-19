using Test
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen

read_i32(blob) = Int.(ltoh.(reinterpret(Int32, blob.bytes)))
read_f32(blob) = Float64.(ltoh.(reinterpret(Float32, blob.bytes)))

# Only identifier/family mapping is under test. No invented continuum solution
# or change to the original volume connectivity is needed for this fixture.
native = Dict{String,Any}(
    "SOL" => 101, "CASE_CONTROL" => Dict("SUBCASES" => Dict(1 => Dict("LABEL" => "Solid mapping"))),
    "GRIDs" => Dict(string(i) => Dict("X" => [Float64(i), 0., 0.]) for i in 1:24),
    "SPC1s" => Any[],
    "CSOLIDs" => Dict(
        "7" => Dict("ID"=>7, "PID"=>11, "TYPE"=>"CTETRA", "NODES"=>collect(1:4)),
        "42" => Dict("ID"=>42, "PID"=>11, "TYPE"=>"CTETRA", "NODES"=>collect(1:10)),
        "55" => Dict("ID"=>55, "PID"=>11, "TYPE"=>"CTETRA", "NODES"=>collect(1:4)),
        "701" => Dict("ID"=>701, "PID"=>11, "TYPE"=>"CHEXA", "NODES"=>collect(11:18)),
        "9001" => Dict("ID"=>9001, "PID"=>11, "TYPE"=>"CPENTA", "NODES"=>collect(19:24))),
    "PSOLIDs" => Dict("11" => Dict("MID"=>3)),
    "MATs" => Dict("3" => Dict("E"=>70e9, "NU"=>.3, "RHO"=>2700.)))
m = W.imported_model(native, Dict("name"=>"solid_mapping.inp"), W.default_params())
data = Dict{String,Any}("analysis_type"=>"SOL101_STATIC", "stresses"=>Dict(
    "ctetra" => Any[Dict("eid"=>42, "von_mises"=>100., "sxx"=>-30.),
                    Dict("eid"=>7, "von_mises"=>0.),
                    Dict("eid"=>701, "von_mises"=>900.), # wrong family
                    Dict("eid"=>99999, "von_mises"=>900.)], # not this model
    "chexa" => Any[Dict("eid"=>701, "von_mises"=>200., "szz"=>-200.)],
    "cpenta" => Any[Dict("eid"=>9001, "von_mises"=>300.)],
    "quad4" => Any[Dict("eid"=>42, "z1"=>Dict("von_mises"=>1000.))]))

@testset "Live solver solid contours retain original EIDs and centroid values" begin
    contours, records = W.element_results_payload(m, data)
    contour = only(contours)
    @test contour["name"] == "Solid von Mises stress"
    @test contour["domain"] == "solid"
    @test contour["location"] == "element"
    @test contour["unit"] == "Pa"
    @test read_i32(contour["ids"]) == [7, 42, 701, 9001]
    @test read_f32(contour["values"]) == [0., 100., 200., 300.]
    @test contour["min"] == 0.
    @test contour["max"] == 300.
    @test occursin("Centroidal", contour["note"])
    @test Set(keys(records)) == Set(["7", "42", "701", "9001"])
    @test records["42"]["type"] == "CTETRA"
    @test records["701"]["type"] == "CHEXA"
    @test records["9001"]["type"] == "CPENTA"
    @test records["42"]["stress_location"] == "element centroid"
    @test records["42"]["stress"]["sxx"] == -30.
    @test !haskey(records, "55") # absent recovery remains absent, not zero
    @test length(native["CSOLIDs"]["42"]["NODES"]) == 10
    records["42"]["stress"]["sxx"] = 1.
    @test data["stresses"]["ctetra"][1]["sxx"] == -30.

    for invalid in (nothing, NaN, Inf, -1., 1e100, true)
        unavailable = Dict("stresses"=>Dict("ctetra"=>Any[Dict("eid"=>42, "von_mises"=>invalid)]))
        c, r = W.element_results_payload(m, unavailable)
        @test isempty(c)
        @test isempty(r)
    end
    duplicate = Dict("stresses"=>Dict("ctetra"=>Any[
        Dict("eid"=>42, "von_mises"=>1.), Dict("eid"=>42, "von_mises"=>2.)]))
    @test_throws ArgumentError W.element_results_payload(m, duplicate)
    @test all(isempty, W.element_results_payload(m, Dict("stresses"=>Dict())))

    mktempdir() do directory
        job = W.JfemJob("solid-test", "", "solid_mapping.inp", directory,
            joinpath(directory,"log"), "", m, nothing, String[], ReentrantLock(), 0., 0., :done, 0, "")
        payload = W.jfem_case_results_payload(job, "synthetic.JU.JSON", data)
        @test only(payload["contours"])["domain"] == "solid"
        @test payload["element_results"]["701"]["stress"]["von_mises"] == 200.
        @test any(row -> first(row)=="Max von Mises", payload["summary"])
    end
end
