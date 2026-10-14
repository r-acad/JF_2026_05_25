using Test, JSON
length(ARGS) <= 1 || error("Usage: julia --project=. test/eigrl_explanation_test.jl [evidence-directory]")
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
function solver_parser_path()
    explicit = strip(get(ENV,"JFEM_SOLVER_SOURCE_ROOT",""))
    container = abspath(joinpath(@__DIR__,"..",".."))
    candidates = isempty(explicit) ? [container,joinpath(container,"01_PUBLIC_PROJECT_REPOSITORY","JFEM")] : [abspath(explicit)]
    for root in candidates
        parser = joinpath(root,"src","parsing","ReferenceParser.jl")
        isfile(parser) && return parser
    end
    error("Cannot find src/parsing/ReferenceParser.jl. Set JFEM_SOLVER_SOURCE_ROOT to the JFEM repository root.")
end
include(solver_parser_path())
const N=ReferenceParser

function request(text)
    _,bulk=N.read_bulk_and_case(String.(split(text,'\n')))
    cards=N.process_cards(bulk)
    return N.extract_eigrl(cards["EIGRL"])["1"]
end

reports=Dict{String,Any}()
suite=@testset "Analysis EIGRL explanation matches exported and parsed fields" begin
    example="EIGRL          11.0000-650.00000      10"
    @test [strip(example[8i+1:min(8i+8,length(example))]) for i in 0:4] ==
        ["EIGRL","1","1.0000-6","50.00000","10"]
    parsed=request("SOL 105\nCEND\nBEGIN BULK\n$example\nENDDATA\n")
    @test parsed["SID"] == 1 && parsed["V1"] == 1e-6 && parsed["V2"] == 50. && parsed["ND"] == 10
    reports["user_example"]=Dict("card"=>example,"parsed"=>parsed)
    for solution in ("103","105"), (count,limit) in ((10,50.),(7,125.5))
        p=merge(W.default_params(),Dict{String,Any}("box.rib_pitch"=>10.,"box.stringer_pitch"=>1.,
            "mesh.elements_between_ribs"=>1,"output.solution"=>solution,
            "output.n_modes"=>count,"output.buckling_max_factor"=>limit))
        model=W.build_model(p);text=sprint(W.write_deck,model);parsed=request(text)
        @test parsed["SID"] == 1 && parsed["ND"] == count
        if solution == "103"
            @test !parsed["V1_SPECIFIED"] && !parsed["V2_SPECIFIED"]
            @test parsed["NORM"] == "MASS"
        else
            @test parsed["V1_SPECIFIED"] && parsed["V2_SPECIFIED"]
            @test parsed["V1"] == 1e-6 && parsed["V2"] == limit
        end
        reports["SOL$(solution)_$count"]=Dict("card"=>only(filter(line->startswith(line,"EIGRL"),split(text,'\n'))),"parsed"=>parsed)
    end
    @test occursin("1e-6",W.SCHEMA_BY_KEY["output.buckling_max_factor"].help)
end
if length(ARGS)==1
    mkpath(ARGS[1]);counts=Test.get_test_counts(suite)
    write(joinpath(ARGS[1],"eigrl_summary.json"),JSON.json(Dict("passed"=>true,
        "assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports),2))
    write(joinpath(ARGS[1],"schema.json"),JSON.json(W.schema_payload(W.default_params(),""),2))
end
