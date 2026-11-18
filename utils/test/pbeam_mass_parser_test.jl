using Test, OpenJFEM

@testset "PBEAM independent NSM station and end defaults" begin
    parser=OpenJFEM.ReferenceParser
    section=Any[.0012,1.8e-6,4.2e-7,0.,3.1e-7]
    recovery=Any[.03,.012,-.03,.012,-.03,-.012,.03,-.012]
    station(x,nsm)=Any["YES",x,section...,nsm,recovery...]
    header(nsm)=Any["SMALL","PBEAM",1,1,section...,nsm,recovery...]
    footer=Any[.8,.8,0.,0.,.01,"",.2,"",.02,-.01,"","",0.,0.,"",""]

    uniform=parser.extract_pbeam([vcat(header(2.),station(1.,""),footer)])["1"]
    @test uniform["NSM"]==2.
    @test [s["NSM"] for s in uniform["STATIONS"]]==[2.,2.]
    @test uniform["NSIA"]==uniform["NSIB"]==.01
    @test uniform["CWA"]==uniform["CWB"]==.2
    @test uniform["M1A"]==uniform["M1B"]==.02
    @test uniform["M2A"]==uniform["M2B"]==-.01

    # Stations need not be supplied in span order. Only a blank intermediate
    # density is interpolated from A/B; an explicit intermediate value remains.
    varying=parser.extract_pbeam([vcat(header(2.),station(.75,""),
        station(.25,4.),station(1.,6.),footer)])["1"]
    @test Dict(s["X"]=>s["NSM"] for s in varying["STATIONS"])==
        Dict(0.0=>2.0,.25=>4.0,.75=>5.0,1.0=>6.0)
    @test varying["NSM"]==4.375 # exact piecewise-linear integral on [0,1]
    @test varying["K1"]==.8
    @test varying["I1"]==section[2]

    zero=parser.extract_pbeam([vcat(header(2.),station(.5,""),
        station(1.,0.),footer)])["1"]
    @test [s["NSM"] for s in zero["STATIONS"]]==[2.,1.,0.]
    @test zero["NSM"]==1.
    @test parser.extract_pbeam([header(2.)])["1"]["NSM"]==2.
    # Signed constituents are legal: retaining NSM must not silently clip them.
    @test parser.extract_pbeam([header(-2.)])["1"]["NSM"]==-2.
    explicit=vcat(header(2.),station(1.,2.),
        Any[.8,.8,0.,0.,.01,0.,.2,0.,.02,-.01,0.,0.,0.,0.,0.,0.])
    p=parser.extract_pbeam([explicit])["1"]
    @test p["NSIB"]==0.
    @test p["CWB"]==0.
    @test p["M1B"]==p["M2B"]==0.
end
