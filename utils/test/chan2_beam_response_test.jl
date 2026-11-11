using Test,LinearAlgebra,OpenJFEM

@testset "CHAN2 physical beam response and PBEAML reference-axis coupling" begin
    mktempdir() do directory
        path=joinpath(directory,"channel.bdf")
        write(path,"SOL 101\nCEND\nSUBCASE 1\nBEGIN BULK\n"*
            "GRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\n"*
            "MAT1,1,7.1e10,,.3,2780.\n"*
            "PBARL,10,1,,CHAN2\n+,.002,.002,.025,.0745,.04\n"*
            "PBEAML,20,1,,CHAN2\n+,.002,.002,.025,.0745,.04\nENDDATA\n")
        model=OpenJFEM.bdf_to_model(path)
        bar=model["PBARLs"]["10"];beam=model["PBARLs"]["20"]
        @test bar["A"]≈.000241 rtol=1e-14
        @test bar["NSM"]==beam["NSM"]==.04
        @test bar["DIMS"]==[.002,.002,.025,.0745]
        @test beam["LIBRARY_CARD"]=="PBEAML"
        @test beam["N1A"]==beam["N1B"]>0
        @test !haskey(bar,"N1A")
        E,G,L=7.1e10,7.1e10/2.6,.31
        stiffness=OpenJFEM.Solver._beam_local_stiffness(L,bar,E,G)
        free=stiffness[7:12,7:12]
        for (index,expected) in ((1,L/(E*bar["A"])),
                (2,L^3/(3E*bar["I1"])+L/(G*bar["K1"]*bar["A"])),
                (3,L^3/(3E*bar["I2"])+L/(G*bar["K2"]*bar["A"])),
                (4,L/(G*bar["J"])))
            load=zeros(6);load[index]=1.
            displacement=free\load
            @test displacement[index]≈expected rtol=1e-10
        end
        eccentric=OpenJFEM.Solver._beam_local_stiffness(L,beam,E,G)[7:12,7:12]
        axial=zeros(6);axial[1]=1.
        displacement=eccentric\axial
        offset=beam["N1A"]
        @test displacement[1]≈L/(E*beam["A"])+offset^2*L/(E*beam["I1"]) rtol=1e-10
        @test displacement[2]≈offset*L^2/(2E*beam["I1"]) rtol=1e-10
        @test displacement[6]≈offset*L/(E*beam["I1"]) rtol=1e-10
        @test norm(displacement[[3,4,5]])<1e-14
        @test minimum(eigvals(Symmetric(eccentric)))>0
    end
end
