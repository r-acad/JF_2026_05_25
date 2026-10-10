using Test,SHA
module Overlay
using SHA
struct Model
    params::Dict{String,Any}
    xyz::Vector{Float64}
    groups::Vector{Int}
end
include(joinpath(@__DIR__,"..","src","nastran_import_cases.jl"))
include(joinpath(@__DIR__,"..","src","nastran_import_analysis.jl"))
end
const O=Overlay
function fixture(text)
    source=Dict("flattened"=>text,"signature"=>"unchanged-source")
    O.Model(Dict{String,Any}("imported.source"=>source,"output.solution"=>"101",
      "imported.cases"=>[Dict{String,Any}("id"=>17,"label"=>"Original","load_cards"=>[Dict("type"=>"FORCE","set_id"=>4,"scale"=>1.)])]),[0.,0.,0.],[701])
end
const HEAD="SOL 101\nCEND \$ source comment\nSPC = 8\nMPC = 9\nSUBCASE 17\n LOAD = 4\n METHOD = 81\n STATSUB(PRELOAD) = 20\nBEGIN BULK\n"
@testset "Imported overlay boundaries and stream hashing" begin
    text=HEAD*"FORCE,4,11,0,3.,1.,0.,0.,ROT\nPARAM,JFFOLLOW,1\nEIGRL,81,,,4\nENDDATA \$ trailing comment\n"
    # A buckling-only case has no static preload. Explicitly omit its source
    # STATSUB for follower compatibility checks, and test modifier stripping below.
    follower=fixture(replace(text," STATSUB(PRELOAD) = 20\n"=>""))
    for sol in ("103","105")
        err=try O.imported_analysis_model(follower,Dict("solution"=>sol));nothing catch error;error end
        @test err isa ArgumentError
        @test occursin("Fixed directions",sprint(showerror,err))
        fixed=O.imported_analysis_model(follower,Dict("solution"=>sol,"follower"=>"fixed"))
        @test occursin("PARAM,JFFOLLOW,0",fixed.params["imported.analysis_deck"])
        @test !occursin(",ROT",fixed.params["imported.analysis_deck"])
        @test occursin("SPC = 8",fixed.params["imported.analysis_deck"])
        @test occursin("MPC = 9",fixed.params["imported.analysis_deck"])
        original_eigen=fixture(replace(follower.params["imported.source"]["flattened"],"SOL 101"=>"SOL $sol"));original_eigen.params["output.solution"]=sol
        @test_throws ArgumentError O.imported_analysis_model(original_eigen)
    end
    # Fixed/large/free fields retain numbers/CID; only the follower flag changes.
    small=rpad("FORCE",8)*join(rpad.(string.(Any[4,11,22,3.,1.,0.,0.]),8))
    large="FORCE*  "*join(rpad.(string.(Any[4,11,22,3.]),16))*"\n*       "*join(rpad.(string.(Any[1.,0.,0.,"ROT"]),16))
    for card in (small,large,"FORCE,4,11,22,3.,1.,0.,0.")
        model=fixture("SOL 101\nCEND\nSUBCASE 17\nLOAD=4\nBEGIN BULK\n$card\nENDDATA\n")
        variant=O.imported_analysis_model(model,Dict("solution"=>"106","follower"=>"force"))
        @test occursin("FORCE,4,11,22,3.0,1.0,0.0,0.0,ROT",replace(variant.params["imported.analysis_deck"],"3.,1.,0.,0."=>"3.0,1.0,0.0,0.0"))
        @test count(==("ENDDATA"),split(variant.params["imported.analysis_deck"],'\n'))==1
        @test model.params["imported.source"]["flattened"]=="SOL 101\nCEND\nSUBCASE 17\nLOAD=4\nBEGIN BULK\n$card\nENDDATA\n"
    end
    buckling=fixture(replace(follower.params["imported.source"]["flattened"],"BEGIN BULK"=>"SUBCASE 18\n STATSUB(PRELOAD) = 17\n METHOD = 81\nBEGIN BULK"))
    push!(buckling.params["imported.cases"],Dict{String,Any}("id"=>18,"label"=>"Old eigen case"))
    converted=O.imported_analysis_model(buckling,Dict("solution"=>"105","follower"=>"fixed"))
    @test converted.params["imported.analysis_cases"][17]==19
    @test !occursin("STATSUB(PRELOAD)",converted.params["imported.analysis_deck"])
    @test occursin("METHOD = 82",converted.params["imported.analysis_deck"])
    for body in ("small", "αβγ \$ non-ASCII source comment\n",repeat("GRID,1,,1.,2.,3.\n",20000))
        @test SHA.sha256(body)==SHA.sha256(IOBuffer(body))
    end
end
