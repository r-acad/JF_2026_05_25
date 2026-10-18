using Test, JSON, LinearAlgebra
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
stable,out=abspath.(ARGS[1:2]);mkpath(stable);mkpath(out)
const metrics=Any[]

function buckling_fixture(;bar=false,thickness=.02,width=.04,E=7.0e10)
    physical=bar ? """
GRID,11,,0.,0.,0.
GRID,85,,2.,0.,0.
CBAR,811,92,11,85,0.,1.,0.
PBARL,92,8,,BAR
,$width,0.08
SPC1,20,123456,11
FORCE,31,85,0,100.,-1.,.03,.07
MOMENT,31,85,0,1.,.7,.1,.2
""" : """
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,$thickness,8,,8
SPC1,20,123456,11,49
FORCE,31,25,0,100.,-1.,0.,.01
FORCE,31,38,0,100.,-1.,0.,.03
"""
    """
SOL 101
CEND
SUBCASE 17
 SPC=20
 LOAD=31
BEGIN BULK
PARAM,K6ROT,100.
$physical
MAT1,8,$E,,.3,2700.
ENDDATA
"""
end

function imported(text,name)
    path=joinpath(stable,name*".bdf");write(path,text)
    source=W.imported_source(Dict("name"=>name*".bdf","text"=>text))
    m=W.imported_model(N.bdf_to_model(path),source,W.default_params());W.imported_prepare_loads!(N,m);m
end
solve(path)=N.solve_model(N.bdf_to_model(path))

suite=@testset "Imported SOL105 exact preload adjoints" begin
    if "--static-only" in ARGS
        m=imported(buckling_fixture(),"static101_regression")
        request=Dict("solution"=>"101","case_id"=>17,
            "objective"=>Dict("type"=>"displacement","node_id"=>25,"component"=>"z"),
            "variables"=>["reference.MAT1#8#E"],"derivative_method"=>"analytic")
        calls=Ref(0);solver=path->begin calls[]+=1;solve(path) end
        dir=joinpath(out,"static101");result=W.compute_sensitivity(m,request,dir;native=N,solve=solver)
        W.sensitivity_json_write(joinpath(dir,"result.json"),result)
        @test result["status"]=="complete"&&result["solution"]=="101"
        @test calls[]==result["solver_counts"]["forward_solves"]==1
        @test result["solver_counts"]["adjoint_solves"]==1
        @test result["solver_counts"]["eigen_solves"]==0
        @test result["solver_counts"]["finite_difference_samples"]==0
        @test result["rows"][1]["derivative"]≈-result["baseline"]["value"]/70 rtol=1e-9
        @test result["rows"][1]["normalized_derivative"]≈-1 rtol=1e-9
        push!(metrics,Dict("fixture"=>"static101","analytic"=>result["rows"][1]["derivative"],
            "reference"=>-result["baseline"]["value"]/70,"normalized"=>result["rows"][1]["normalized_derivative"]))
    else
    companion=replace(buckling_fixture(),"SOL 101"=>"SOL 105","BEGIN BULK"=>"SUBCASE 23\n STATSUB=17\n SPC=21\n METHOD=41\nBEGIN BULK","ENDDATA"=>"SPC1,21,123456,11,49\nEIGRL,41,,,4\nENDDATA")
    different=imported(companion,"different_eigen_constraints")
    converted=joinpath(out,"different_eigen_constraints.bdf");write(converted,W.imported_sensitivity_deck(different,23,"105";modes=6))
    parsed=N.bdf_to_model(converted)
    @test parsed["CASE_CONTROL"]["SUBCASES"][1]["SPC"]==20
    @test parsed["CASE_CONTROL"]["SUBCASES"][2]["SPC"]==21
    @test_throws ArgumentError W.imported_buckling_context(N,Dict("model"=>parsed),different,Dict("type"=>"buckling_factor","mode"=>1))
    omitted=imported(replace(companion," SPC=21\n"=>""),"omitted_eigen_constraints")
    omitted_path=joinpath(out,"omitted_eigen_constraints.bdf")
    write(omitted_path,W.imported_sensitivity_deck(omitted,23,"105";modes=6))
    omitted_model=N.bdf_to_model(omitted_path)
    @test omitted_model["CASE_CONTROL"]["SUBCASES"][1]["SPC"]==20
    @test omitted_model["CASE_CONTROL"]["SUBCASES"][2]["SPC"]===nothing
    eigen_row=only(filter(row->row["id"]==23,omitted.params["imported.cases"]))
    @test eigen_row["load_source_case_id"]==17
    @test eigen_row["spc"]["selected_spc_id"]===nothing
    @test eigen_row["spc"]["constrained_dofs"]==0
    created=joinpath(out,"new_eigen_constraints.bdf")
    write(created,W.imported_sensitivity_deck(omitted,17,"105";modes=6))
    @test N.bdf_to_model(created)["CASE_CONTROL"]["SUBCASES"][2]["SPC"]==20
    end
    for bar in (any(flag in ARGS for flag in ("--preflight-only","--static-only")) ? () : (false,true))
        tag=bar ? "bar" : "shell";m=imported(buckling_fixture(;bar),tag)
        variable=bar ? "reference.PBARL#92#DIM1" : "reference.PSHELL#123#T"
        objective=Dict("type"=>"buckling_factor","mode"=>1)
        request=Dict("solution"=>"105","case_id"=>17,"objective"=>objective,
            "variables"=>[variable,"reference.MAT1#8#E"],"derivative_method"=>"analytic")
        calls=Ref(0);solver=path->begin calls[]+=1;solve(path) end
        dir=joinpath(out,tag);result=W.compute_sensitivity(m,request,dir;native=N,solve=solver)
        W.sensitivity_json_write(joinpath(dir,"result.json"),result)
        @test result["status"]=="complete"
        @test calls[]==1
        @test result["solution"]=="105"
        @test result["solver_counts"]["forward_solves"]==1
        @test result["solver_counts"]["eigen_solves"]==1
        @test result["solver_counts"]["adjoint_solves"]==1
        @test result["solver_counts"]["perturbed_forward_solves"]==0
        @test result["solver_counts"]["finite_difference_samples"]==0
        @test result["diagnostics"]["eigen_residual"]<1e-5
        @test result["diagnostics"]["adjoint_residual"]<1e-7
        @test result["rows"][2]["normalized_derivative"]≈1 rtol=1e-6
        @test abs(result["rows"][2]["diagnostics"]["preload_adjoint_contraction"])>0
        @test W.imported_native(m)["SOL"]==101
        baseline=solve(joinpath(dir,"baseline.bdf"))
        reference=W.sensitivity_response(baseline,m,objective).vector
        for (field,value,id) in ((bar ? "width" : "thickness",bar ? .04 : .02,variable),("E",7.0e10,"reference.MAT1#8#E"))
            h=value*1e-4;responses=Float64[]
            for sign in (-1,1)
                text=buckling_fixture(;bar,width=field=="width" ? value+sign*h : .04,
                    thickness=field=="thickness" ? value+sign*h : .02,E=field=="E" ? value+sign*h : 7.0e10)
                trial=imported(text,tag*"_"*field*"_"*string(sign))
                path=joinpath(dir,"validation_$(field)_$(sign).bdf");write(path,W.imported_sensitivity_deck(trial,17,"105";modes=6))
                response=W.sensitivity_response(solve(path),trial,objective;reference)
                @test response.mac>.9999
                push!(responses,response.value)
            end
            # E is a displayed GPa design variable; the full deck uses Pa.
            fd=(responses[2]-responses[1])/(2h)*(field=="E" ? 1e9 : 1.)
            row=only(filter(r->r["id"]==id,result["rows"]));derivative=row["derivative"]
            @test derivative≈fd rtol=3e-5
            push!(metrics,Dict("fixture"=>tag,"id"=>id,"analytic"=>derivative,"solved_fd"=>fd,
                "relative_error"=>abs(derivative-fd)/abs(fd),"preload_adjoint"=>row["diagnostics"]["preload_adjoint_contraction"]))
        end
        @test W.sensitivity_baseline_load(dir,m;result)["available"]
    end
end
counts=Test.get_test_counts(suite)
W.sensitivity_json_write(joinpath(out,"summary.json"),Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"comparisons"=>metrics,"scope"=>"--preflight-only" in ARGS ? "distinct preload/eigen constraint preservation and rejection" : "--static-only" in ARGS ? "unchanged SOL101 static adjoint dispatch" : "native buckling adjoint versus solved finite differences"))
