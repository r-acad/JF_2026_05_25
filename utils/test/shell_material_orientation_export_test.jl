using Test

module ShellMaterialOrientationExportFixture
using Test, HDF5, OpenJFEM

function checks()
    mktempdir() do dir
        model=Dict{String,Any}("CSHELLs"=>Dict(
            "1"=>Dict("ID"=>1,"PID"=>1,"NODES"=>[1,2,3],"THETA"=>0.,"MCID"=>0,"MCID_SPECIFIED"=>true),
            "2"=>Dict("ID"=>2,"PID"=>1,"NODES"=>[1,2,3],"THETA"=>0.,"MCID"=>0,"MCID_SPECIFIED"=>false),
            "3"=>Dict("ID"=>3,"PID"=>1,"NODES"=>[1,2,3],"THETA"=>23.,"MCID"=>0),
            "4"=>Dict("ID"=>4,"PID"=>1,"NODES"=>[1,2,3],"THETA"=>0.,"MCID"=>33)))
        original=deepcopy(model)
        rows=OpenJFEM._jfem_shell_material_orientation_records(model)
        @test [r.EID for r in rows] == [1,2,3,4]
        @test [r.MCID_SPECIFIED for r in rows] == [1,0,0,1]
        @test [r.THETA for r in rows] == [0.,0.,23.,0.]
        path=joinpath(dir,"orientation.jfem")
        h5open(path,"w") do file
            OpenJFEM._reference_write_input_tables(file,model)
        end
        @test model == original
        h5open(path,"r") do file
            @test read(attributes(file["/REFERENCE/INPUT"])["SCOPE"]) == "COMPACT_SUBSET_NOT_DECK_ROUNDTRIP"
            restored=read(file["/JFEM/INPUT/SHELL_MATERIAL_ORIENTATION"])
            @test [r.MCID_SPECIFIED for r in restored] == [1,0,0,1]
            @test [r.MCID for r in restored] == [0,0,0,33]
            @test [r.THETA for r in restored] == [0.,0.,23.,0.]
            for (saved,source) in zip(restored,rows)
                el=Dict("MCID"=>saved.MCID,"MCID_SPECIFIED"=>Bool(saved.MCID_SPECIFIED),"THETA"=>saved.THETA)
                @test OpenJFEM.Solver.shell_material_coordinate_id(el) ==
                    OpenJFEM.Solver.shell_material_coordinate_id(model["CSHELLs"][string(source.EID)])
            end
            # The compatibility table keeps its original compound layout.
            compatibility=read(file["/REFERENCE/INPUT/ELEMENT/CTRIA3"])
            @test !hasproperty(first(compatibility),:MCID_SPECIFIED)
            @test [r.MCID for r in compatibility] == [0,0,0,33]
        end
    end
end
end

@testset "Shell material orientation export metadata" begin
    ShellMaterialOrientationExportFixture.checks()
end
