using Test, JSON, OpenJFEM
const S=OpenJFEM.Solver
out=abspath(only(ARGS));mkpath(out)
function beam_test_deck(card;nonlinear=false)
    control=nonlinear ? "SUBCASE 1\n  SPC = 1\n  LOAD = 7\n" :
        join(["SUBCASE $i\n  SPC = 1\n  LOAD = $i\n" for i in 1:8])
    "SOL $(nonlinear ? 106 : 101)\nCEND\nDISPLACEMENT(PLOT)=ALL\nSTRESS(PLOT)=ALL\nFORCE(PLOT)=ALL\n"*
    control*"BEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\n"*
    "MAT1,1,7.0e10,,.3,2700.\nPBARL,10,1,,T\n+,.04,.05,.002,.002\n"*
    "$card,1,10,1,2,0.,1.,0.\nSPC1,1,123456,1\n"*
    "FORCE,1,2,0,100.,1.,0.,0.\nMOMENT,2,2,0,1.,0.,0.,1.\nMOMENT,3,2,0,1.,0.,1.,0.\n"*
    "FORCE,4,2,0,1.,0.,1.,0.\nFORCE,5,2,0,1.,0.,0.,1.\nMOMENT,6,2,0,.01,1.,0.,0.\n"*
    "LOAD,7,1.,1.,1,.1,2,.1,3,.1,4,.1,5,.1,6\n"*
    # Inactive GRAV must not invalidate the seven point-loaded subcases.
    # The cancelling PLOAD1 inventory has zero fixed-end vector, but still
    # requires explicit distributed-load recovery rather than an end check.
    "GRAV,99,0,9.81,0.,0.,-1.\nPLOAD1,8,1,FY,FR,0.,1.,1.,1.\nPLOAD1,8,1,FY,FR,0.,-1.,1.,-1.\n"*
    (nonlinear ? "PARAM,LGDISP,1\nPARAM,NLLOADSTEPS,2\nPARAM,NLTOL,1.e-9\nPARAM,NLRESTOL,1.e-9\n" : "")*"ENDDATA\n"
end
summaries=Any[]
checks=@testset "Native CBAR/CBEAM equivalent recovery through SOL101 and SOL106" begin
    for card in ("CBAR","CBEAM"),nonlinear in (false,true)
        name=card*(nonlinear ? "_sol106" : "_sol101")
        path=joinpath(out,name*".bdf");write(path,beam_test_deck(card;nonlinear))
        model=OpenJFEM.bdf_to_model(path);result=OpenJFEM.solve_model(model)
        @test result["sol_type"]==(nonlinear ? 106 : 101)
        @test length(result["subcases"])==(nonlinear ? 1 : 8)
        for sub in (nonlinear ? result["subcases"] : result["subcases"][1:7])
            force=only(sub["forces"]["cbar"]);stress=only(sub["stresses"]["cbar"])
            @test stress["von_mises_recovery"]["status"]=="complete"
            @test stress["von_mises"]>0
            expected=S.beam_t_stress_envelope(model["PBARLs"]["10"],force)
            @test stress["von_mises"]≈expected["von_mises"] rtol=1e-13
            @test stress["axial"]≈force["axial"]/model["PBARLs"]["10"]["A"] rtol=1e-12 atol=1e-9
            if nonlinear
                @test sub["nonlinear_diagnostics"]["converged"]
                @test sub["nonlinear_diagnostics"]["final_load_scale"]==1
            end
        end
        if !nonlinear
            p=model["PBARLs"]["10"]
            hw=.05-.002;yc=(hw*.002*hw/2+.04*.002*(hw+.001))/p["A"]
            @test result["subcases"][1]["stresses"]["cbar"][1]["von_mises"]≈100/p["A"] rtol=1e-10
            # Independent global tip moments confirm native section axes:
            # Mz bends the y-height about I1; My bends the z-width about I2.
            @test result["subcases"][2]["stresses"]["cbar"][1]["von_mises"]≈max(yc,.05-yc)/p["I1"] rtol=1e-10
            @test result["subcases"][3]["stresses"]["cbar"][1]["von_mises"]≈.02/p["I2"] rtol=1e-10
            @test result["subcases"][6]["stresses"]["cbar"][1]["von_mises"]≈sqrt(3)*.01*.002/p["J"] rtol=1e-10
            @test all(sub["stresses"]["cbar"][1]["von_mises"]>abs(sub["stresses"]["cbar"][1]["axial"]) for sub in result["subcases"][2:7])
            distributed=only(result["subcases"][8]["stresses"]["cbar"])
            @test !haskey(distributed,"von_mises")
            @test occursin("Distributed",distributed["von_mises_recovery"]["reason"])
        end
        write(joinpath(out,name*".json"),JSON.json(result))
        push!(summaries,Dict("name"=>name,"cases"=>length(result["subcases"]),"passed"=>true))
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"recovery_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"runs"=>summaries)))
