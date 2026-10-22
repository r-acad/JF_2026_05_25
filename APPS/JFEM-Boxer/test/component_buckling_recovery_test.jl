# julia --project=. APPS/JFEM-Boxer/test/component_buckling_recovery_test.jl <generated-fixture> <output> [linear-only]
# Actual FE recovery for component assessment; only generated synthetic test models.
using Test, JSON, WingFEGen, OpenJFEM
const W=WingFEGen; const N=OpenJFEM
fixture=abspath(ARGS[1]); out=abspath(ARGS[2]); mkpath(out)
p=JSON.parsefile(joinpath(fixture,"params.json")); model=W.build_model(first(W.normalize_params(p)))
deck=read(joinpath(fixture,"model.bdf"),String)
deck=replace(deck,r"(?m)^FORCE[^\r\n]*\r?\n"=>"")
gid=model.node_ids[last(model.rbe3).ref]
cases=Any[];timings=Any[]
checks=@testset "Actual component loads and full-load recovery" begin
    text=replace(deck,"BEGIN BULK"=>"SUBCASE 2\n  LABEL = Axial tension\n  SPC = 1\n  LOAD = 2\nSUBCASE 3\n  LABEL = Vertical bending\n  SPC = 1\n  LOAD = 3\nSUBCASE 4\n  LABEL = Opposite vertical bending\n  SPC = 1\n  LOAD = 4\nBEGIN BULK")
    text=replace(text,"ENDDATA"=>"FORCE,1,$gid,0,1000.,0.,-1.,0.\nFORCE,2,$gid,0,1000.,0.,1.,0.\nFORCE,3,$gid,0,100.,0.,0.,-1.\nFORCE,4,$gid,0,100.,0.,0.,1.\nENDDATA")
    input=joinpath(out,"component_cases_sol101.bdf");write(input,text)
    elapsed=@elapsed result=N.solve_model(N.bdf_to_model(input))
    @test result["sol_type"]==101
    @test length(result["subcases"])==4
    records=[last(W.element_results_payload(model,sub)) for sub in result["subcases"]]
    @test all(!isempty,records)
    bar_eids=[eid for g in model.groups if g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_SPAR_CAP for eid in g.eids]
    @test !isempty(bar_eids)
    for (a,b) in ((1,2),(3,4))
        firstcase=Float64[records[a][string(eid)]["forces"]["axial"] for eid in bar_eids]
        opposite=Float64[records[b][string(eid)]["forces"]["axial"] for eid in bar_eids]
        @test maximum(abs,firstcase)>1e-6
        @test opposite≈-firstcase rtol=1e-9 atol=1e-8
    end
    for (id,label) in enumerate(("Axial compression","Axial tension","Vertical bending","Opposite vertical bending"))
        push!(cases,Dict("id"=>id,"label"=>label,"solution"=>101,"element_results"=>records[id],"load_scale"=>1.,"converged"=>true,"full_load"=>true))
    end
    write(joinpath(out,"sol101_native_results.json"),JSON.json(result))
    push!(timings,Dict("solution"=>101,"cases"=>4,"seconds_including_compilation"=>elapsed))
    if !in("linear-only",ARGS)
        text106=replace(deck,"SOL 101"=>"SOL 106")
        text106=replace(text106,"ENDDATA"=>"PARAM,LGDISP,1\nPARAM,NLLOADSTEPS,2\nPARAM,NLMAXITER,40\nPARAM,NLTOL,1.e-9\nPARAM,NLRESTOL,1.e-9\nFORCE,1,$gid,0,100.,0.,0.,-1.\nENDDATA")
        input106=joinpath(out,"component_case_sol106.bdf");write(input106,text106)
        elapsed106=@elapsed result106=N.solve_model(N.bdf_to_model(input106))
        @test result106["sol_type"]==106
        sub=only(result106["subcases"]); diagnostic=sub["nonlinear_diagnostics"]
        @test diagnostic["converged"]===true
        @test diagnostic["final_load_scale"]≈1.
        @test diagnostic["nonlinear_method"]!="linear_elastic"
        recovered=last(W.element_results_payload(model,sub));@test !isempty(recovered)
        push!(cases,Dict("id"=>5,"label"=>"Nonlinear vertical bending","solution"=>106,"element_results"=>recovered,"load_scale"=>diagnostic["exported_load_scale"],"converged"=>diagnostic["converged"],"full_load"=>diagnostic["final_load_scale"]==1))
        write(joinpath(out,"sol106_native_results.json"),JSON.json(result106))
        push!(timings,Dict("solution"=>106,"cases"=>1,"seconds_including_compilation"=>elapsed106))
    end
end
counts=Test.get_test_counts(checks)
solutions=join(sort!(unique("SOL$(item["solution"])" for item in cases))," / ")
write(joinpath(out,"browser_recovery_fixture.json"),JSON.json(Dict("provenance"=>"Actual generated synthetic model $solutions recovery; all included cases converged at full load; no simulated solver result values.","cases"=>cases)))
write(joinpath(out,"recovery_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"timings"=>timings,"cases"=>length(cases))))
