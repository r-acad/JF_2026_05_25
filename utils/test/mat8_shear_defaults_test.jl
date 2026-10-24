using Test, OpenJFEM, LinearAlgebra

@testset "MAT8 omitted and zero transverse shear have the same physical limit" begin
    mktempdir() do folder
        models = Dict{Symbol,Any}()
        for (kind, fields) in ((:blank, ","), (:zero, "0.,0."),
                               (:finite, "3.1e9,2.7e9"))
            deck = joinpath(folder, "$(kind).bdf")
            write(deck, """
            SOL 101
            CEND
            SPC = 1
            LOAD = 1
            BEGIN BULK
            GRID,1,,0.,0.,0.
            GRID,2,,.4,0.,0.
            GRID,3,,.4,.2,0.
            GRID,4,,0.,.2,0.
            CQUAD4,1,1,1,2,3,4
            PCOMP,1
            +,1,.001,0.,YES,1,.001,90.,YES
            MAT8,1,130.e9,9.e9,.28,4.8e9,$fields,1600.
            SPC1,1,123456,1,4
            FORCE,1,3,,1.,0.,0.,1.
            ENDDATA
            """)
            models[kind] = OpenJFEM.bdf_to_model(deck)
        end
        properties = Dict(k => m["PSHELLs"]["1"] for (k,m) in models)
        @test properties[:blank]["TRANSVERSE_SHEAR_RIGID_LIMIT"]
        @test properties[:zero]["TRANSVERSE_SHEAR_RIGID_LIMIT"]
        @test !properties[:finite]["TRANSVERSE_SHEAR_RIGID_LIMIT"]
        for key in ("Cm", "Bmb", "Cb", "Cs")
            @test properties[:blank][key] == properties[:zero][key]
        end
        # Compare assembled operators, not just input flags: the flag chooses
        # a different residual shear law inside the shell kernel.
        Kb = OpenJFEM.Solver.assemble_stiffness(models[:blank])[1]
        Kz = OpenJFEM.Solver.assemble_stiffness(models[:zero])[1]
        @test Kb == Kz
        @test all(isfinite,Kb)
        # Numeric JSON zeros have the same meaning even without lexical blank flags.
        mat = Dict("MID"=>1,"E1"=>130e9,"E2"=>9e9,"NU12"=>.28,
                   "G12"=>4.8e9,"RHO"=>1600.)
        pc = Dict("PID"=>1,"PLIES"=>[Dict("MID"=>1,"T"=>.001,"THETA"=>0.),
                                    Dict("MID"=>1,"T"=>.001,"THETA"=>90.)])
        for zero_fields in (false,true)
            mj=copy(mat)
            zero_fields && merge!(mj, Dict("G1Z"=>0.,"G2Z"=>0.))
            raw=Dict("case_control"=>Dict(),"bulk_data"=>Dict(
                "MAT8"=>Dict("1"=>mj),"PCOMP"=>Dict("1"=>pc)))
            p=OpenJFEM.build_model_from_json(raw)["PSHELLs"]["1"]
            @test p["TRANSVERSE_SHEAR_RIGID_LIMIT"]
            for key in ("Cm","Bmb","Cb","Cs")
                @test p[key] == properties[:zero][key]
            end
        end
        # A finite direction must not be discarded by the all-directions limit.
        @test !OpenJFEM.mat8_rigid_transverse_shear(Dict("G1Z"=>0.,"G2Z"=>2e9))
        @test !OpenJFEM.mat8_rigid_transverse_shear(Dict("G1Z"=>2e9,"G2Z"=>0.))
    end
end
