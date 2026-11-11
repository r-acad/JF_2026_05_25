module ModalBinaryOutputTests
using Test, OpenJFEM, JSON
const APP=normpath(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer"))
include(joinpath(APP,"src","modal_binary_results.jl"))

@testset "SOL103 binary plus JSON stores vectors once and preserves standalone JSON" begin
    mktempdir() do dir
        deck=joinpath(dir,"modal_storage.bdf")
        write(deck,"SOL 103\nCEND\nSPC = 1\nMETHOD = 3\nSUBCASE 1\nBEGIN BULK\n"*
            "GRID,1,,0.,0.,0.\nCELAS2,1,200.,1,1,0,0\nCONM2,2,1,0,2.\n"*
            "SPC1,1,23456,1\nEIGRL,3,,,1\nENDDATA\n")
        combined=OpenJFEM.main(deck;output_dir=joinpath(dir,"jrs"),
            export_json=true,export_jfem_binary=true,export_report=true)
        jsonpath=joinpath(dir,"jrs","modal_storage.BUCKLING.JSON")
        metadata=JSON.parsefile(jsonpath)
        @test isempty(combined["mode_shapes"])
        @test isempty(combined["subcases"][1]["mode_shapes"])
        @test metadata["mode_shape_status"]=="available_binary"
        @test !haskey(only(metadata["modes"]),"mode_shape")
        @test !haskey(only(metadata["subcases"]),"mode_shapes")
        @test !haskey(only(metadata["subcases"]),"_raw_mode_shapes")
        @test only(metadata["frequencies"])≈sqrt(100.)/(2pi)
        vectors=modal_binary_vectors(jsonpath,metadata,Dict(1=>1),1)
        @test vectors[1].shape≈Float32.(combined["_raw_mode_shapes"][1:3,1])
        @test vectors[1].rotation≈Float32.(combined["_raw_mode_shapes"][4:6,1])
        @test isapprox(vectors[1].max_disp,abs(combined["_raw_mode_shapes"][1,1]);rtol=eps(Float32))
        @test isfile(joinpath(dir,"jrs","modal_storage.REPORT.md"))

        standalone=OpenJFEM.main(deck;output_dir=joinpath(dir,"json_only"),
            export_json=true,export_jfem_binary=false,export_report=false)
        full=JSON.parsefile(joinpath(dir,"json_only","modal_storage.BUCKLING.JSON"))
        @test length(standalone["mode_shapes"])==1
        @test !haskey(full,"mode_shape_status")
        @test only(only(full["modes"])["mode_shape"])["t1"]≈vectors[1].shape[1]
        @test modal_binary_vectors(jsonpath,full,Dict(1=>1),1)===nothing
        @test !isfile(joinpath(dir,"json_only","modal_storage.jfem"))

        @test_throws ArgumentError modal_binary_vectors(jsonpath,metadata,Dict(99=>1),1)
        wrong=deepcopy(metadata);wrong["frequencies"][1]*=2
        @test_throws ArgumentError modal_binary_vectors(jsonpath,wrong,Dict(1=>1),1)
        traversal=deepcopy(metadata);traversal["mode_shape_storage"]["path"]="../modal_storage.jfem"
        @test_throws ArgumentError modal_binary_result_path(jsonpath,traversal)
        binarypath=modal_binary_result_path(jsonpath,metadata)
        mv(binarypath,binarypath*".saved")
        @test_throws ArgumentError modal_binary_result_path(jsonpath,metadata)
    end
end
end
