using Test
include(joinpath(@__DIR__,"..","src","modal_binary_results.jl"))

@testset "Modal binary blocks and GRID reordering" begin
    mktempdir() do dir
        for version in (3,4,6)
            path=joinpath(dir,"modes$version.jfem")
            disp=[Float32.(1:18),Float32.(101:118)]
            open(path,"w") do io
                write(io,codeunits("JFEM"));write(io,UInt32(version))
                #3grids,1quad,1tria,1bar,1rod,2modes;1spring,1RBE2,1RBE3.
                write(io,UInt32[3,1,1,1,1,2,1,1,1])
                version>=4 && write(io,UInt32[1,0,0])
                for nid in (20,30,10)
                    write(io,Int32(nid));write(io,zeros(Float32,3))
                end
                write(io,zeros(UInt8,28+24+20+20+28))
                for _ in 1:2
                    write(io,UInt32[100,20,123,2]);write(io,Int32[10,30])
                end
                if version>=6
                    write(io,UInt32[200,1,10]);write(io,zeros(Int32,10))
                elseif version>=4
                    write(io,zeros(UInt8,24))
                end
                for mode in 1:2
                    write(io,UInt32(mode));write(io,disp[mode])
                    write(io,zeros(UInt8,3*28+8+(version>=4 ? 4 : 0)))
                    #Exercise variable constraints, loads and moments.
                    write(io,UInt32(1));write(io,zeros(UInt8,8))
                    write(io,UInt32(1));write(io,zeros(UInt8,16))
                    write(io,UInt32(1));write(io,zeros(UInt8,16))
                end
                write(io,codeunits("EVAL"));write(io,UInt32(2));write(io,[1.,2.])
            end
            metadata=Dict("mode_shape_status"=>"available_binary",
                "mode_shape_storage"=>Dict("format"=>"jfem","path"=>basename(path)),
                "frequencies"=>[1.,2.],"modes"=>[
                    Dict("mode_number"=>m,"binary_mode_index"=>m) for m in 1:2])
            ids=Dict(10=>1,20=>2,30=>3)
            actual=modal_binary_vectors(joinpath(dir,"metadata.JSON"),metadata,ids,3)
            for mode in 1:2
                @test actual[mode].shape==disp[mode][[13,14,15,1,2,3,7,8,9]]
                @test actual[mode].rotation==disp[mode][[16,17,18,4,5,6,10,11,12]]
            end
            selected=copy(metadata);selected["modes"]=metadata["modes"][2:2]
            subset=modal_binary_vectors(joinpath(dir,"metadata.JSON"),selected,ids,3)
            @test collect(keys(subset))==[2]
            @test subset[2].shape==actual[2].shape
            bytes=read(path);write(path,bytes[1:end-1])
            @test_throws EOFError modal_binary_vectors(joinpath(dir,"metadata.JSON"),metadata,ids,3)
        end
    end
end
