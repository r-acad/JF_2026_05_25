module FixedBulkContinuationTests

using Test
module Parser
include(joinpath(@__DIR__,"..","..","src","parsing","utilities.jl"))
include(joinpath(@__DIR__,"..","..","src","parsing","card_processor.jl"))
include(joinpath(@__DIR__,"..","..","src","parsing","extract_nonlinear.jl"))
end

fixed(fields)=join(rpad(string(f),8) for f in fields)

@testset "One-value fixed continuations retain their physical field slots" begin
    for maxbis in (0,1,8,9)
        lines=["SOL 106","CEND","NLPARM = 1","SUBCASE 1","SPC = 1","LOAD = 1","BEGIN BULK",
            fixed(("NLPARM",1,6,"","",1,35,"UPW","YES")),
            fixed(("","1.-7","1.-7","1.-7","","","","","")),
            fixed(("",maxbis)),"ENDDATA"]
        cc,bulk=Parser.read_bulk_and_case(lines)
        @test length(bulk)==3
        card=only(Parser.process_cards(bulk)["NLPARM"])
        @test length(card)==26
        @test Parser.parse_reference_number(card[19])==maxbis
        normalized=Parser.extract_nlparm([card])["1"]
        @test normalized["MAXBIS"]==maxbis
        @test "MAXBIS" in normalized["EXPLICIT_FIELDS"]
        @test normalized["EPSU"]==normalized["EPSP"]==normalized["EPSW"]==1e-7
        @test (normalized["NINC"],normalized["MAXITER"],normalized["CONV"])==(6,35,"UPW")
        @test cc["NLPARM"]==1
    end
    # Blank large-field header halves must keep their slots as before.
    for marker in ("*","+")
        _,bulk=Parser.read_bulk_and_case(["SOL 101","CEND","BEGIN BULK","PCOMP,1",marker,"ENDDATA"])
        @test bulk==["PCOMP,1",marker]
        @test length(only(Parser.process_cards(bulk)["PCOMP"])) == (marker=="*" ? 14 : 18)
    end
    # A single-letter fixed continuation is also a real data field.
    _,bulk=Parser.read_bulk_and_case(["SOL 101","CEND","BEGIN BULK","PBAR,1,1",fixed(("","Y")),"ENDDATA"])
    @test only(Parser.process_cards(bulk)["PBAR"])[11]=="Y"
    # Whitespace-only physical lines do not create an extra continuation.
    _,bulk=Parser.read_bulk_and_case(["SOL 101","CEND","BEGIN BULK","NLPARM,1",repeat(" ",16),"ENDDATA"])
    @test bulk==["NLPARM,1"]
end

end
