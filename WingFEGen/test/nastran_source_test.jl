using Test
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

@testset "Portable and local Nastran source expansion" begin
    mktempdir() do folder
        mkpath(joinpath(folder,"bulk","nested"))
        write(joinpath(folder,"main.bdf"),"SOL 101\nCEND\nBEGIN BULK\nINCLUDE 'bulk/part.bdf'\nENDDATA\n")
        write(joinpath(folder,"bulk","part.bdf"),"INCLUDE '../material.bdf'\nINCLUDE 'nested/long_\nname.bdf'\n")
        write(joinpath(folder,"material.bdf"),"MAT1,1,7E10,,0.3\n")
        write(joinpath(folder,"bulk","nested","long_name.bdf"),"GRID,1,,0.,0.,0.\n")
        source=W.imported_source(Dict("path"=>joinpath(folder,"main.bdf")))
        @test source["source_file_count"]==4
        @test occursin("MAT1,1",source["flattened"])
        @test occursin("GRID,1",source["flattened"])
        @test !occursin("INCLUDE",source["flattened"])
        @test isempty(source["includes"])
        @test W.imported_source(source)["signature"]==source["signature"]
        @test !occursin(folder,source["text"])
        write(joinpath(folder,"bulk","part.bdf"),"INCLUDE '..\\material.bdf'\nINCLUDE 'nested\\long_name.bdf'\n")
        @test W.imported_source(Dict("path"=>joinpath(folder,"main.bdf")))["flattened"]==source["flattened"]
        write(joinpath(folder,"material.bdf"),"INCLUDE 'main.bdf'\n")
        @test_throws ArgumentError W.imported_source(Dict("path"=>joinpath(folder,"main.bdf")))
        @test_throws ArgumentError W.imported_source(Dict("path"=>joinpath(folder,"missing.bdf")))
    end
    @test_throws ArgumentError W.imported_source(Dict("name"=>"../private.bdf","text"=>"GRID,1"))
    @test_throws ArgumentError W.imported_source(Dict("name"=>"main.bdf","text"=>"INCLUDE 'missing.bdf'"))
    @test_throws ArgumentError W.imported_source(Dict("name"=>"main.bdf","text"=>"bad\0data"))
    original=Dict("main.bdf"=>"BEGIN BULK\nINCLUDE 'part.bdf'\nENDDATA","part.bdf"=>"GRID,1,,0.,0.,0.")
    legacy=bytes2hex(W.SHA.sha256(W.JSON.json([(key,original[key]) for key in sort!(collect(keys(original)))])))
    @test W.imported_source_signature(original)==legacy
    @test W.imported_source(Dict("name"=>"main.bdf","text"=>original["main.bdf"],"includes"=>[Dict("name"=>"part.bdf","text"=>original["part.bdf"])]))["signature"]==legacy
    @test occursin("GRID,1",W.imported_source(Dict("name"=>"main.bdf","text"=>"INCLUDE 'PART.bdf'","includes"=>[Dict("name"=>"part.bdf","text"=>original["part.bdf"])]))["flattened"])
    windows_paths=W.imported_source(Dict("name"=>"main.bdf","text"=>"INCLUDE 'bulk\\mesh.bdf'","includes"=>[
        Dict("name"=>"bulk/mesh.bdf","text"=>"INCLUDE '..\\material.inc'\nGRID,1,,0.,0.,0."),
        Dict("name"=>"material.inc","text"=>"MAT1,8,7E10,,0.3")]))
    @test windows_paths["flattened"]=="MAT1,8,7E10,,0.3\nGRID,1,,0.,0.,0."
    # Source size and INCLUDE count are not arbitrary import limits. A large
    # comment block exercises source capture without an expensive solve.
    large="SOL 101\nCEND\nBEGIN BULK\n"*repeat("\$ "*repeat("large source ",6)*"\n",500_000)*"GRID,1,,0.,0.,0.\nENDDATA\n"
    source=W.imported_source(Dict("name"=>"large.bdf","text"=>large))
    @test source["source_bytes"]>32*1024*1024
    @test occursin("GRID,1",source["flattened"])
    includes=[Dict("name"=>"part_$i.bdf","text"=>"\$ file $i\n") for i in 1:257]
    main=join(["INCLUDE 'part_$i.bdf'" for i in 1:257],"\n")
    @test W.imported_source(Dict("name"=>"main.bdf","text"=>main,"includes"=>includes))["source_file_count"]==258
end
