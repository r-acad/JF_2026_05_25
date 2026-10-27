module PressureParserScopeTests

using Test, OpenJFEM, LinearAlgebra
const N = OpenJFEM.ReferenceParser
const S = OpenJFEM.Solver

parse_pressure(lines) = only(N.extract_pload4(N.process_cards(lines)["PLOAD4"]))

@testset "PLOAD4 explicit direction and surface-load scope" begin
    # Exercise the real free-field tokenizer, including padded continuations.
    for (tail, expected) in (("+,0,1.", [1.,0.,0.]),
                             ("+,0,,2.", [0.,2.,0.]),
                             ("+,0,,,3.", [0.,0.,3.]),
                             ("+,8,1.,,-2.,surf", [1.,0.,-2.]))
        card = parse_pressure(["PLOAD4,10,7,2.5", tail])
        @test card["N"] == expected
        @test card["SORL"] == "SURF"
    end
    normal = parse_pressure(["PLOAD4,10,7,2.5"])
    @test !haskey(normal,"N")
    @test normal["CID"] == 0
    @test normal["SORL"] == "SURF"
    cid_only = parse_pressure(["PLOAD4,10,7,2.5", "+,8"])
    @test cid_only["CID"] == 8
    @test !haskey(cid_only,"N")
    zero = parse_pressure(["PLOAD4,10,7,2.5", "+,0,0.,0.,0."])
    @test zero["N"] == zeros(3)
    line = parse_pressure(["PLOAD4,10,7,2.5", "+,0,,,,line,tang"])
    @test line["SORL"] == "LINE"
    @test line["LDIR"] == "TANG"
    @test !haskey(line,"N")
    expanded = N.extract_pload4(N.process_cards([
        "PLOAD4,10,7,2.5,,,,THRU,9", "+,0,,1.,,SURF"])["PLOAD4"])
    @test [c["EID"] for c in expanded] == [7,8,9]
    @test all(c -> c["N"] == [0.,1.,0.], expanded)
    expanded[1]["N"][2] = 4.
    @test expanded[2]["N"][2] == 1. # Each expanded card owns its vector.
    for tail in ("+,0,nope", "+,0,NaN", "+,0,,Inf", "+,0,,,,WRONG", "+,0,,,,LINE,WRONG")
        @test_throws ArgumentError parse_pressure(["PLOAD4,10,7,2.5", tail])
    end

    mktempdir() do folder
        deck = joinpath(folder,"pressure_scope.bdf")
        write(deck,"""
        SOL 106
        CEND
        BEGIN BULK
        PARAM,LGDISP,1
        GRID,1,,0.,0.,0.
        GRID,2,,1.,0.,0.
        GRID,3,,1.,1.,0.
        GRID,4,,0.,1.,0.
        MAT1,1,1.0e7,,.25
        PSHELL,1,1,.1,1,,1
        CQUAD4,7,1,1,2,3,4
        CORD2R,8,,0.,0.,0.,0.,0.,1.
        +,0.,1.,0.
        PLOAD4,10,7,2.5
        +,0,1.
        PLOAD4,11,7,2.5
        +,8,,1.
        PLOAD4,12,7,2.5
        PLOAD2,13,2.5,7
        PLOAD,14,2.5,1,2,3,4
        FORCE,90,2,0,3.,0.,1.,0.
        LOAD,30,1.,2.,10,-.5,12,1.,90
        LOAD,40,1.,1.,12,-1.,12
        ENDDATA
        """)
        model = OpenJFEM.bdf_to_model(deck)
        ids = Dict(i=>i for i in 1:4)
        X = [0. 0. 0.;1. 0. 0.;1. 1. 0.;0. 1. 0.]
        frames = fill(Matrix{Float64}(I,3,3),4)
        no_mpc = Dict{Int,Vector{Tuple{Int,Float64}}}()
        force(sid; scale=1.) = S._assemble_applied_force(24,model,ids,X,sid,frames,no_mpc;load_scale=scale)
        context(sid) = S._follower_context(24,model,ids,X,sid,frames,no_mpc)
        fx = zeros(24); fx[1:6:24] .= .625
        fz = zeros(24); fz[3:6:24] .= .625
        @test isapprox(force(10),fx;atol=2e-15)
        @test context(10) === nothing
        @test isapprox(force(11),-fx;atol=2e-15) # Local y of CORD2R8 points along basic -x.
        @test context(11) === nothing
        for sid in (12,13,14)
            @test isapprox(force(sid),fz;atol=2e-15)
            @test length(context(sid).pressures) == 1
        end
        @test context(40) === nothing
        @test force(40) == zeros(24)
        # A real parsed LOAD mixes fixed traction, normal pressure and dead FORCE.
        u = .04sin.(1.:24); scale = .7
        current, jac = S._follower_load_update(context(30),u,scale)
        applied = force(30;scale=scale)+current
        Y = copy(X)
        for i in 1:4; Y[i,:] += u[6i-5:6i-3]; end
        expected = scale*2fx
        expected[8] += scale*3.
        pressure = S._current_area_pressure_force(Y,-.5*2.5*scale)
        for i in 1:4; expected[6i-5:6i-3] += pressure[i,:]; end
        @test isapprox(applied,expected;atol=3e-15)
        @test norm(jac-jac') > 1e-5

        # Invalid active edge loading fails before the FORCE contribution can
        # mutate an accumulator, in both linear loading and follower setup.
        model["PLOAD4s"] = [merge(deepcopy(line), Dict("SID"=>90))]
        model["CSHELLs"]["7"]["TYPE"] = "CQUADR"
        accumulated = zeros(24)
        @test_throws ArgumentError S.resolve_loads(model,90,1.,ids,Dict(),X,accumulated)
        @test accumulated == zeros(24)
        @test_throws ArgumentError context(90)
        model["CSHELLs"]["7"]["TYPE"] = "CTRIAR"
        @test_throws ArgumentError context(90)
        push!(model["LOAD_COMBOS"],Dict("SID"=>92,"S"=>-2.,"COMPS"=>[Dict("LID"=>90,"S"=>.5)]))
        @test_throws ArgumentError context(92)
        @test_throws ArgumentError force(92)
        # Unselected or exactly zero weighted pressure is not an active edge load.
        @test context(12) === nothing
        @test force(12) == zeros(24)
        model["PLOAD4s"][1]["P"] = 0.
        @test context(90) === nothing
        @test force(90)[8] == 3.
        model["PLOAD4s"][1]["P"] = 2.5
        @test force(90;scale=0.) == zeros(24)
        model["LOAD_COMBOS"] = [Dict("SID"=>91,"S"=>1.,"COMPS"=>[
            Dict("LID"=>90,"S"=>1.),Dict("LID"=>90,"S"=>-1.)])]
        @test context(91) === nothing
        @test force(91) == zeros(24)
        # The QRG explicitly ignores SORL on ordinary CQUAD4/CTRIA3 elements.
        model["CSHELLs"]["7"]["TYPE"] = "CQUAD4"
        @test length(context(90).pressures) == 1
        expected = copy(fz); expected[8] = 3.
        @test isapprox(force(90),expected;atol=2e-15)
        @test isapprox(force(90)[3:6:24],fill(.625,4);atol=2e-15)
        model["PLOAD4s"][1] = merge(deepcopy(cid_only),Dict("SID"=>90))
        @test length(context(90).pressures) == 1
        model["PLOAD4s"][1] = merge(deepcopy(zero),Dict("SID"=>90))
        @test length(context(90).pressures) == 1
        # Programmatically assembled model dictionaries get the same guards.
        for bad in ([NaN,0.,0.],[1.,2.])
            model["PLOAD4s"][1]["N"] = bad
            @test_throws ArgumentError context(90)
        end
    end
end

end
