using Test
include(joinpath(@__DIR__, "..", "..", "src", "parsing", "ReferenceParser.jl"))
const RP = ReferenceParser

@testset "BAROR/BEAMOR orientation defaults are accepted and retained" begin
    source = """
    SOL 103
    CEND
    BEGIN BULK
    GRID,1,,0.,0.,0.
    GRID,2,,1.,0.,0.
    GRID,3,,0.,0.,1.
    BAROR,,7,,,0.,1.,0.,GGG
    BEAMOR,,,,,0.,0.,1.,BGG
    CBAR,11,,1,2,,,,
    CBEAM,12,8,1,2,,,,
    CBEAM,13,8,1,2,0.,1.,0.,GOO
    CBAR,14,9,1,2,,,,
    CBAR,15,9,1,2,0.5,,2.,
    ENDDATA
    """
    _, bulk = RP.read_bulk_and_case(String.(split(source, '\n')))
    cards = RP.process_cards(bulk)
    bars = RP.extract_cbar(cards["CBAR"]; defaults=cards["BAROR"])
    beams = RP.extract_cbeam(cards["CBEAM"]; defaults=cards["BEAMOR"])
    @test bars["11"]["PID"] == 7
    @test bars["11"]["V"] == [0.0, 1.0, 0.0]
    @test bars["11"]["OFFT"] == "GGG"
    @test beams["12"]["V"] == [0.0, 0.0, 1.0]
    @test beams["12"]["OFFT"] == "BGG"
    @test beams["13"]["V"] == [0.0, 1.0, 0.0]
    @test beams["13"]["OFFT"] == "GOO"
    @test bars["14"]["PID"] == 9
    @test bars["14"]["V"] == [0.0, 1.0, 0.0]
    @test bars["15"]["V"] == [0.5, 1.0, 2.0]
    g0cards = RP.process_cards(["BAROR,,7,,,3,,,BGG", "CBAR,16,,1,2,,,,"])
    @test RP.extract_cbar(g0cards["CBAR"]; defaults=g0cards["BAROR"])["16"]["G0"] == 3
    plain = RP.process_cards(["CBAR,17,,1,2,0.,0.,1.,"])
    @test RP.extract_cbar(plain["CBAR"])["17"]["PID"] == 17
    @test_throws ArgumentError RP.extract_cbar(cards["CBAR"]; defaults=[cards["BAROR"]; cards["BAROR"]])
end
