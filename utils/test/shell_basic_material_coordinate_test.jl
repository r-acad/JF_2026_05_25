using Test

module ShellBasicMaterialCoordinateFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S = OpenJFEM.Solver

function checks()
    mktempdir() do dir
        deck = joinpath(dir, "material_coordinates.bdf")
        open(deck, "w") do io
            println(io, "SOL 101\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,100.")
            println(io, "CORD2R,33,0,0.,0.,0.,0.,0.,1.\n+,1.,0.,0.")
            println(io, "MAT8,1,1.4E11,7.E10,.3,4.E10,5.4E10,2.7E10,2700.")
            println(io, "PSHELL,1,1,.0025,1,1.,1,.833333333333333")
            println(io, "PCOMP,2\n+,1,.0025,0.,YES")
            # Oblique geometry makes material angle zero distinct from BASIC.
            for (i, p) in enumerate(((0.,0.,0.),(.4,.3,0.),(.2,1.1,0.),(-.4,.8,0.)))
                println(io, "GRID,$i,,", join(p, ','))
            end
            for (g, card) in enumerate(("CTRIA3", "CQUAD4")), pid in (1,2)
                base = 100g + 10pid
                nodes = card == "CTRIA3" ? "1,2,3" : "1,2,3,4"
                for (i, field) in enumerate(("0", "33", "", "0.0", "23."))
                    println(io, "$card,$(base+i),$pid,$nodes,$field")
                end
            end
            println(io, "ENDDATA")
        end
        model = OpenJFEM.bdf_to_model(deck)
        captured = Dict{Int,Matrix{Float64}}()
        S.assemble_stiffness(model; element_capture=(eid,pid,dofs,K)->(captured[eid]=copy(K)))
        for g in 1:2, pid in 1:2
            base=100g+10pid
            els=[model["CSHELLs"][string(base+i)] for i in 1:5]
            @test [el["MCID_SPECIFIED"] for el in els] == [true,true,false,false,false]
            @test S.shell_material_coordinate_id.(els) == [0,33,-1,-1,-1]
            @test els[5]["THETA"] == 23.
            @test captured[base+1] ≈ captured[base+2] rtol=3e-12
            @test captured[base+3] == captured[base+4]
            @test norm(captured[base+1]-captured[base+3]) / norm(captured[base+1]) > .01
        end
        # BASIC must use the same fallback axis as an explicit identity frame
        # when its X axis is normal to the shell.
        x=SVector(0.,1.,0.);y=SVector(0.,0.,1.);z=SVector(1.,0.,0.)
        @test S.shell_material_basic_rotation(x,y,z) ==
              S.shell_material_rotation_from_coord(x,y,z,model["CORDs"]["33"])
        @test S.shell_material_coordinate_id(Dict("MCID"=>0,"THETA"=>23.)) == -1
        @test S.shell_material_coordinate_id(Dict("MCID"=>33)) == 33
    end
end
end

@testset "Explicit BASIC shell material coordinates preserve angle-field semantics" begin
    ShellBasicMaterialCoordinateFixture.checks()
end
