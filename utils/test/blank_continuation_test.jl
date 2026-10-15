using Test, LinearAlgebra, OpenJFEM

@testset "Blank physical continuation lines retain property fields" begin
    parser = OpenJFEM.ReferenceParser
    large(name, fields...) = rpad(name,8) * join(rpad(string(x),16) for x in fields)
    lines = ["SOL 103", "CEND", "SUBCASE 1", " SPC=1", " METHOD=1", "BEGIN BULK",
        large("MAT1*",1,"7.1E10","",0.33), large("*",2780.),
        large("MAT1*",3,"8.E7","",0.3), large("*",80.),
        large("PCOMP*",10,-0.0046,0.0,""), "*",
        large("*",1,0.0006,0.,"YES"),
        large("*",3,0.008,0.,"YES"),
        large("*",1,0.0006,0.,"YES"), "*",
        large("PBARL*",20,1,"REFBML0","T"), "*",
        large("*",0.03,0.025,0.002,0.003), large("*",0.),
        "ENDDATA"]
    cc, bulk = parser.read_bulk_and_case(lines)
    @test count(==("*"),bulk)==3
    cards=parser.process_cards(bulk)
    laminate=parser.extract_pcomp(cards["PCOMP"])["10"]
    @test [p["MID"] for p in laminate["PLIES"]]==[1,3,1]
    @test [p["T"] for p in laminate["PLIES"]]≈[0.0006,0.008,0.0006]
    @test laminate["T"]≈0.0092
    @test laminate["Z0"]≈-laminate["T"]/2
    model=OpenJFEM.build_model(cards,cc)
    prop=model["PSHELLs"]["10"]
    @test length(prop["PLY_DATA"])==3
    @test prop["Bmb"]===nothing || norm(prop["Bmb"])<=1e-10*norm(prop["Cm"])
    @test minimum(eigvals(Symmetric(prop["Cb"])))>0
    @test [p["z_top"]-p["z_bot"] for p in prop["PLY_DATA"]]≈[0.0006,0.008,0.0006]
    bar=parser.extract_pbarl(cards["PBARL"])["20"]
    @test bar["DIMS"]≈[0.03,0.025,0.002,0.003]

    # Small-field '+' consumes eight fields even with no nonblank payload.
    # Comments and ordinary empty separator lines consume none.
    cc2, bulk2=parser.read_bulk_and_case(["BEGIN BULK", "PCOMP,30,-.0046", "+",
        "", "\$ intervening comment", "+,1,.0006,0.,YES,3,.008,0.,YES",
        "+,1,.0006,0.,YES", "ENDDATA"])
    @test "+" in bulk2
    raw=parser.process_cards(bulk2)["PCOMP"][1]
    @test all(isempty,raw[11:18])
    @test parser.extract_pcomp([raw])["30"]["T"]≈0.0092
end
