module Sol106NlparmTests

using Test, LinearAlgebra, JSON, OpenJFEM
const P = OpenJFEM.ReferenceParser
const S = OpenJFEM.Solver

function fixture(;sol=106, case_control="NLPARM = 11\nSUBCASE 1\n SPC = 1\n LOAD = 1", controls="")
    """
SOL $sol
CEND
$case_control
BEGIN BULK
PARAM,AUTOSPC,YES
PARAM,K6ROT,100.
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
MAT1,1,7.e10,,.3,2700.
PBAR,1,1,.002,2.e-6,1.e-6,1.e-6
CBAR,1,1,1,2,0.,1.,0.
SPC1,1,123456,1
FORCE,1,2,0,1.,1.,0.,0.
EIGRL,1,,,3
NLPARM,11,6,,,1,35,UPW,YES
+,1.e-7,1.e-7,1.e-7,,,,,
+,8
NLPARM,12,2,,,1,12,P,NO
+,1.e-4,2.e-8,3.e-5,,,,,
+,2
$controls
ENDDATA
"""
end

@testset "Standard NLPARM field positions and selector semantics" begin
    mktempdir() do folder
        path=joinpath(folder,"controls.bdf")
        write(path,fixture(case_control="NLPARM = 11\nSUBCASE 1\n SPC = 1\n LOAD = 1\nSUBCASE 2\n SPC = 1\n LOAD = 1\n NLPARM = 12"))
        model=OpenJFEM.bdf_to_model(path)
        @test Set(keys(model["NLPARMs"])) == Set(("11","12"))
        card=model["NLPARMs"]["11"]
        @test (card["NINC"],card["KSTEP"],card["MAXITER"],card["CONV"],card["MAXBIS"]) == (6,1,35,"UPW",8)
        @test card["EPSU"] == card["EPSP"] == card["EPSW"] == 1e-7
        @test card["MAXQN"] == 35
        cc=model["CASE_CONTROL"]
        c1=OpenJFEM._sol106_controls(model,cc,cc["SUBCASES"][1],1)
        c2=OpenJFEM._sol106_controls(model,cc,cc["SUBCASES"][2],2)
        @test (c1.load_steps,c1.max_iter,c1.tol,c1.residual_tol,c1.work_tol,c1.max_cutbacks) == (6,35,1e-7,1e-7,1e-7,8)
        @test c1.convergence_criteria == "UPW"
        @test c1.step_growth == 1.0
        @test c1.metadata["selection_scope"] == "global"
        @test (c2.load_steps,c2.max_iter,c2.residual_tol,c2.max_cutbacks) == (2,12,2e-8,2)
        @test c2.convergence_criteria == "P"
        @test c2.metadata["selection_scope"] == "subcase"
        # Defining NLPARM without selecting it preserves the existing controls.
        legacy=OpenJFEM._sol106_controls(model,Dict(),Dict(),3)
        @test (legacy.load_steps,legacy.max_iter,legacy.tol,legacy.max_cutbacks) == (4,8,1e-6,6)
        @test legacy.convergence_criteria == "LEGACY"
        model["PARAM_NLLOADSTEPS"]=9
        @test OpenJFEM._sol106_controls(model,Dict(),Dict(),3).load_steps == 9
        @test OpenJFEM._sol106_controls(model,cc,cc["SUBCASES"][1],1).load_steps == 6
        @test_throws ArgumentError OpenJFEM._sol106_controls(model,cc,Dict("NLPARM"=>99),1)
        @test_throws ArgumentError OpenJFEM._sol106_controls(model,cc,Dict("NLPARM"=>1.5),1)
        @test_throws ArgumentError P.extract_nlparm(P.process_cards(["NLPARM,1,2.5"])["NLPARM"])
        @test_throws ArgumentError P.extract_nlparm(P.process_cards(["NLPARM,1", "NLPARM,1"])["NLPARM"])
        for (field,value) in (("KMETHOD","SEMI"),("KSTEP",2),("DT",1.),("MAXQN",5),("MAXDIV",3),("CONV","XYZ"),("EPSW",0.))
            changed=deepcopy(model)
            changed["NLPARMs"]["11"][field]=value
            push!(changed["NLPARMs"]["11"]["EXPLICIT_FIELDS"],field)
            @test_throws ArgumentError OpenJFEM._sol106_controls(changed,cc,cc["SUBCASES"][1],1)
        end
        # Preserve the controls through raw-JSON and model-JSON routes.
        normalized=P.normalize_nlparm(JSON.parse(JSON.json(card)))
        @test normalized == card
        raw=Dict("case_control"=>Dict("SOL"=>106,"SUBCASES"=>Dict("1"=>Dict("NLPARM"=>11))),
                 "bulk_data"=>Dict("NLPARM"=>Dict("11"=>card)))
        @test OpenJFEM.build_model_from_json(raw)["NLPARMs"]["11"] == card
    end
end

@testset "U, P and W are independent requested convergence criteria" begin
    @test !S._nonlinear_convergence_checks(1e-8,1e-8,1e-2,1e-7,1e-7,1e-7,"UPW").converged
    @test S._nonlinear_convergence_checks(1e-8,1e-8,1e-2,1e-7,1e-7,1e-7,"LEGACY").converged
    @test S._nonlinear_convergence_checks(1e-2,1e-8,1e-2,1e-7,1e-7,1e-7,"P").converged
    @test !S._nonlinear_convergence_checks(1e-8,1e-2,1e-8,1e-7,1e-7,1e-7,"UPW").converged
    @test S._nonlinear_convergence_checks(1e-8,1e-8,1e-8,1e-7,1e-7,1e-7,"UPW").converged
end

@testset "Actual SOL106 solves use each subcase's selected controls" begin
    mktempdir() do folder
        path=joinpath(folder,"two_cases.bdf")
        write(path,fixture(case_control="NLPARM = 11\nSUBCASE 1\n SPC = 1\n LOAD = 1\nSUBCASE 2\n SPC = 1\n LOAD = 1\n NLPARM = 12"))
        result=OpenJFEM.solve_model(OpenJFEM.bdf_to_model(path))
        @test result["sol_type"] == 106
        @test length(result["subcases"]) == 2
        for (case,ninc,niter,epsp,maxbis,conv) in zip(result["subcases"],(6,2),(35,12),(1e-7,2e-8),(8,2),("UPW","P"))
            diag=case["nonlinear_diagnostics"]
            @test diag["converged"]
            @test diag["final_load_scale"] ≈ 1.0
            @test (diag["requested_load_step_count"],diag["max_iterations_per_step"],diag["residual_tolerance"],diag["max_cutbacks"],diag["convergence_criteria"]) == (ninc,niter,epsp,maxbis,conv)
            @test diag["resolved_controls"]["nlparm_id"] == (case["sid"] == 1 ? 11 : 12)
            @test diag["load_step_count"] == ninc
            for step in diag["load_steps"]
                checks=last(step["attempts"])["convergence_checks"]
                @test checks["converged"]
                @test all(c->checks[string(c)],conv)
            end
        end
        @test length(result["subcases"][1]["nonlinear_intermediate_results"]) == 6
        @test isempty(result["subcases"][2]["nonlinear_intermediate_results"])
        # These unrelated solutions must not resolve an unselected bad NLPARM.
        for sol in (101,103,105)
            cc = sol==105 ? "SUBCASE 1\n SPC = 1\n LOAD = 1\nSUBCASE 2\n SPC = 1\n METHOD = 1\n STATSUB = 1" :
                "SUBCASE 1\n SPC = 1\n LOAD = 1\n METHOD = 1"
            write(path,replace(fixture(sol=sol,case_control=cc),"NLPARM,11,6,,,1,35,UPW,YES"=>"NLPARM,11,6,,SEMI,1,35,UPW,YES"))
            model=OpenJFEM.bdf_to_model(path)
            @test model["SOL"] == sol
            # Static and modal solve; buckling dispatch is exercised by its
            # independent compression fixture in the public suite.
            sol==105 && continue
            solved=OpenJFEM.solve_model(model)
            @test solved["sol_type"] == sol
        end
    end
end

end
