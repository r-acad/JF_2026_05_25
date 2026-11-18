module RFMatrixIOTests
using Test, SHA, JSON, SparseArrays
const REPO=normpath(joinpath(@__DIR__,"..",".."))
sensitivity_json_write(path,data)=write(path,JSON.json(data))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_matrix_io.jl"))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_sensitivity.jl"))
@testset "Streaming matrix, masks, exact bytes and atomic publication" begin
    mktempdir() do directory
        rows=[Dict("response_id"=>"check_$i") for i in 1:4]
        variables=[Dict("id"=>"dimension_$j","unit"=>"m") for j in 1:3]
        J=[1. 2. 3.;4. NaN 6.;7. 8. 9.;-1. 0. 100.]
        sink=rf_matrix_sink(directory,rows,variables;preview_size=2,provenance=Dict("design"=>"fixture"))
        sink.push_block(1,2,J[1:2,:])
        @test !isfile(joinpath(directory,"jacobian.f64"))
        sink.push_block(3,4,J[3:4,:])
        metadata=sink.finish(;derivative_complete=false)
        @test metadata["complete"]
        @test metadata["shape"]==[4,3]
        @test metadata["export_complete"]&&!metadata["derivative_complete"]
        @test metadata["columns"][1]["unit"]=="m"
        @test metadata["provenance"]==Dict("design"=>"fixture")
        data=reinterpret(Float64,read(joinpath(directory,"jacobian.f64")))
        @test isequal(reshape(data,4,3),J)
        @test isequal(sink.preview,J[1:2,1:2])
        @test metadata["sha256"]==bytes2hex(SHA.sha256(read(joinpath(directory,"jacobian.f64"))))
        csv=read(joinpath(directory,"jacobian.csv"),String)
        @test occursin("\"check_2\",4.0,,6.0",csv)
        @test length(split(chomp(csv),'\n'))==5
    end
    mktempdir() do directory
        sink=rf_matrix_sink(directory,[Dict("response_id"=>"a"),Dict("response_id"=>"b")],[Dict("id"=>"x")])
        sink.push_block(1,1,reshape([NaN],1,1));sink.finish(;complete=false)
        @test !isfile(joinpath(directory,"jacobian.f64"))
        @test isfile(joinpath(directory,"jacobian.f64.partial"))
    end
end
@testset "Sparse dimension/tie mapping without NaN pollution" begin
    variables=[Dict("id"=>"x_$i","label"=>"x$i","unit"=>"m","value"=>2.,"lower_bound"=>1.,"upper_bound"=>4.) for i in 1:10000]
    map=rf_design_map(variables)
    @test nnz(map.P)==10000
    @test Base.summarysize(map.P)<500000
    small=rf_design_map(variables[1:3],[Dict("id"=>"pair","members"=>["x_1","x_2"])])
    @test size(small.P)==(3,2)
    @test small.P*[2.,3.]==[2.,2.,3.]
    J=[1. 2. NaN;3. 4. 5.]
    C=rf_chain_jacobian(J,small.P)
    @test C[1,1]==3.
    @test isnan(C[1,2])
    @test C[2,:]==[7.,5.]
    @test rf_json_safe(Dict("nan"=>NaN,"ok"=>true,"zero"=>0.,"_internal"=>1))==Dict("nan"=>nothing,"ok"=>true,"zero"=>0.)
end

end # RFMatrixIOTests
