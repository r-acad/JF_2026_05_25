using Test
module IncludeParserFixture
include(joinpath(@__DIR__,"..","..","src","parsing","utilities.jl"))
include(joinpath(@__DIR__,"..","..","src","parsing","card_processor.jl"))
end
const IP=IncludeParserFixture

@testset "Native quoted INCLUDE continuation and nested relative paths" begin
    mktempdir() do dir
        mkpath(joinpath(dir,"parts","nested"));mkpath(joinpath(dir,"spaced folder"))
        write(joinpath(dir,"material data.inc"),"MAT1,1,7.e10,,.3\n")
        write(joinpath(dir,"parts","nested","long_name.inc"),"GRID,1,,0.,0.,0.\n")
        write(joinpath(dir,"spaced folder","mesh.inc"),"GRID,2,,1.,0.,0.\n")
        write(joinpath(dir,"parts","part.inc"),"INCLUDE '../material data.inc'\nINCLUDE 'nested/long_\n name.inc'\n")
        lines=String["SOL 103","CEND","BEGIN BULK","INCLUDE 'parts/", "    part.inc'", "INCLUDE, \"spaced folder/", " mesh.inc\" \$ trailing comment", "ENDDATA"]
        result=IP.resolve_includes(lines,dir)
        @test result==["SOL 103","CEND","BEGIN BULK","MAT1,1,7.e10,,.3","GRID,1,,0.,0.,0.","GRID,2,,1.,0.,0.","ENDDATA"]
        @test lines[4]=="INCLUDE 'parts/" # caller input was not modified
        cards=IP.process_cards(result[4:6])
        @test length(cards["GRID"])==2
        @test length(cards["MAT1"])==1
        absolute=IP.resolve_includes(["INCLUDE '"*joinpath(dir,"material data.inc")*"'"],dir)
        @test absolute==["MAT1,1,7.e10,,.3"]
        windows=IP.resolve_includes(["INCLUDE 'parts\\nested\\long_","name.inc'"],dir)
        @test windows==["GRID,1,,0.,0.,0."]
        commented=IP.resolve_includes(["INCLUDE 'parts/nested/", "\$ a comment between continuation lines", "", "long_name.inc'"],dir)
        @test commented==["GRID,1,,0.,0.,0."]
        unquoted=IP.resolve_includes(["INCLUDE parts/nested/long_name.inc"],dir)
        @test unquoted==["GRID,1,,0.,0.,0."]
        @test_throws ArgumentError IP.resolve_includes(["INCLUDE 'parts/nested/"],dir)
        @test_throws ArgumentError IP.resolve_includes(["INCLUDE 'closed.inc' unexpected"],dir)
        @test_throws ArgumentError IP.resolve_includes(["INCLUDE 'missing/", "file.inc'"],dir)
        @test_throws ArgumentError IP.resolve_includes(["INCLUDE"],dir)
        write(joinpath(dir,"cycle_a.inc"),"INCLUDE 'cycle_\nb.inc'\n")
        write(joinpath(dir,"cycle_b.inc"),"INCLUDE 'cycle_a.inc'\n")
        @test_throws ArgumentError IP.resolve_includes(["INCLUDE 'cycle_a.inc'"],dir)
        # Repeating a dependency is a source choice; only active cycles fail.
        repeated=IP.resolve_includes(["INCLUDE 'material data.inc'","INCLUDE 'material data.inc'"],dir)
        @test count(==("MAT1,1,7.e10,,.3"),repeated)==2
    end
end
