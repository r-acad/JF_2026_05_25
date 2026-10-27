using Test
module ModalRequestContractFixture
using Test, LinearAlgebra, OpenJFEM
const O = OpenJFEM

function parsed_model(card; method=11)
    mktempdir() do dir
        path = joinpath(dir,"modal_request.bdf")
        write(path,"SOL 103\nCEND\nSUBCASE 1\n METHOD = $method\nBEGIN BULK\n" *
            "GRID,1,,0.,0.,0.\n" * card * "\nENDDATA\n")
        O.bdf_to_model(path)
    end
end
resolve(model, sub=Dict("METHOD"=>11)) =
    O._resolve_sol103_eigen_request(model,Dict{String,Any}(),sub,1)

@testset "Modal EIGRL presence is not the parser numeric placeholder" begin
    for card in ("EIGRL,11,,,,", "EIGRL,11,0.,,,", "EIGRL,11,2.,,,")
        model = parsed_model(card)
        @test model["EIGRLs"]["11"]["ND"] == 3 # legacy stored placeholder
        @test !model["EIGRLs"]["11"]["ND_SPECIFIED"]
        request = resolve(model)
        @test request.nd == 1
        @test !request.nd_specified
        @test !request.v2_specified
    end
    for card in ("EIGRL,11,,20.,", "EIGRL,11,0.,20.,",
                 "EIGRL,11,,0.,", "EIGRL,11,0.,0.,")
        model = parsed_model(card)
        @test model["EIGRLs"]["11"]["V2_SPECIFIED"]
        @test_throws ArgumentError resolve(model)
        # A private MODES override cannot quietly turn an all-interval request
        # into a finite count while retaining the original EIGRL semantics.
        @test_throws ArgumentError resolve(model,Dict("METHOD"=>11,"MODES"=>7))
    end
    model = parsed_model("EIGRL,11,2.,20.,7,,,,MASS")
    request = resolve(model)
    @test request.nd == 7
    @test request.v1 == 2. && request.v2 == 20.
    @test request.v1_specified && request.v2_specified && request.nd_specified
    @test request.norm == "MASS"
    @test resolve(model,Dict("METHOD"=>11,"MODES"=>5)).nd == 5
    # Existing JSON models without presence flags retain their explicit stored ND.
    legacy = Dict("EIGRLs"=>Dict("11"=>Dict("ND"=>3,"V1"=>0.,"V2"=>20.)))
    @test resolve(legacy).nd == 3
    @test resolve(legacy).nd_specified
    # Integer-keyed model dictionaries and inherited global METHOD are accepted.
    keyed = Dict("EIGRLs"=>Dict(11=>model["EIGRLs"]["11"]))
    @test resolve(keyed).nd == 7
    @test O._resolve_sol103_eigen_request(model,Dict("METHOD"=>11),Dict(),1).nd == 7
    @test O._resolve_sol103_eigen_request(Dict(),Dict(),Dict(),1).nd == 10
    @test O._resolve_sol103_eigen_request(Dict(),Dict(),Dict("MODES"=>4),1).nd == 4
end

@testset "Explicit unresolved modal METHOD fails before mass assembly" begin
    for model in (parsed_model("EIGRL,11,,,4";method=99),
                  parsed_model("EIGB,99,INV,0.,10.,1";method=99),
                  parsed_model("EIGRL,11,,20.,"))
        cc = model["CASE_CONTROL"]
        sub = cc["SUBCASES"][1]
        @test_throws ArgumentError O._resolve_sol103_eigen_request(model,cc,sub,1)
        touched = Ref(false)
        mass_builder = args -> (touched[]=true; error("must not assemble mass"))
        @test_throws ArgumentError O._solve_sol103(model,cc,Matrix{Float64}(I,6,6),
            Dict(1=>1),zeros(1,3),6,[Matrix{Float64}(I,3,3)],0.,
            Dict{Int,Vector{Tuple{Int,Float64}}}(),Float64[],[1],nothing;
            modal_mass_builder=mass_builder)
        @test !touched[]
    end
    model = parsed_model("EIGRL,11,,,4")
    for bad in (0,-1,1.5,Inf,NaN)
        @test_throws ArgumentError resolve(model,Dict("METHOD"=>bad))
    end
    # Shared lookup/presence utilities retain the established SOL105 contract.
    for card in ("EIGRL,11,0.,,7", "EIGRL,11,0.,20.,", "EIGRL,11,,,,")
        model = parsed_model(card)
        entry = model["EIGRLs"]["11"]
        request = O._resolve_sol105_eigen_request(model,Dict(),Dict("METHOD"=>11),1)
        @test request.nd == (entry["ND_SPECIFIED"] ? entry["ND"] : 1)
        @test request.v1_specified == entry["V1_SPECIFIED"]
        @test request.v2_specified == entry["V2_SPECIFIED"]
        @test request.nd_specified == entry["ND_SPECIFIED"]
    end
end
end
