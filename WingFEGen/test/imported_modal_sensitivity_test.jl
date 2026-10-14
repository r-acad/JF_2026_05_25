using Test, JSON, LinearAlgebra
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
stable,out=abspath.(ARGS);mkpath(stable);mkpath(out)
const metrics=Any[]

function panel_deck(;solution=101,thickness=.02,rho=2700.,coupled=false,nsm=0.)
    cases=solution==105 ? "SUBCASE 17\n SPC=20\n LOAD=31\nSUBCASE 23\n STATSUB(BUCKLING)=17\n METHOD=41" : "SUBCASE 17\n SPC=20\n LOAD=31"
    """
SOL $solution
CEND
$cases
BEGIN BULK
PARAM,K6ROT,100.
PARAM,WTMASS,1.7
PARAM,COUPMASS,$(coupled ? 1 : -1)
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,$thickness,8,,8,,$nsm
MAT1,8,7.0E10,,.3,$rho
SPC1,20,123456,11,49
FORCE,31,25,0,100.,0.,0.,1.
EIGRL,41,,,2
EIGRL,303,,,3
ENDDATA
"""
end

function imported(text,name)
    path=joinpath(stable,name*".bdf");write(path,text)
    source=W.imported_source(Dict("name"=>name*".bdf","text"=>text))
    parsed=N.bdf_to_model(path)
    m=W.imported_model(parsed,source,W.default_params())
    W.imported_prepare_loads!(N,m)
    m
end

function solve(path)
    N.solve_model(N.bdf_to_model(path))
end

suite=@testset "Imported SOL103 analytic modal sensitivity" begin
    for (tag,source_sol,coupled,nsm) in (("original101_lumped",101,false,0.),("original105_coupled_nsm",105,true,3.))
        original=panel_deck(;solution=source_sol,coupled,nsm)
        m=imported(original,tag);sid=source_sol==105 ? 23 : 17
        objective=Dict("type"=>"frequency_eigenvalue","mode"=>1)
        request=Dict("solution"=>"103","case_id"=>sid,"objective"=>objective,
            "variables"=>["reference.PSHELL#123#T","reference.MAT1#8#rho","reference.MAT1#8#E"],"derivative_method"=>"analytic")
        calls=Ref(0)
        solver=path->begin calls[]+=1;solve(path) end
        dir=joinpath(out,tag)
        result=W.compute_sensitivity(m,request,dir;native=N,solve=solver)
        W.sensitivity_json_write(joinpath(dir,"result.json"),result)
        @test result["status"]=="complete"
        @test calls[]==1
        @test result["solution"]=="103"&&result["baseline_analysis"]["solution"]=="103"
        @test result["baseline"]["mode"]==1
        @test result["solver_counts"]["forward_solves"]==1
        @test result["solver_counts"]["eigen_solves"]==1
        @test result["solver_counts"]["adjoint_solves"]==0
        @test result["solver_counts"]["perturbed_forward_solves"]==0
        @test result["solver_counts"]["finite_difference_samples"]==0
        @test result["solver_counts"]["analytic_property_derivatives"]==3
        @test result["diagnostics"]["eigen_residual"]<1e-5
        @test m.params["imported.source"]["flattened"]==original
        @test W.imported_native(m)["SOL"]==source_sol
        parsed=N.bdf_to_model(joinpath(dir,"baseline.bdf"));sub=only(values(parsed["CASE_CONTROL"]["SUBCASES"]))
        @test parsed["SOL"]==103&&sub["SPC"]==20&&sub["METHOD"]==304
        @test get(sub,"STATSUB",nothing)===nothing
        @test parsed["GRIDs"]==W.imported_native(m)["GRIDs"]
        @test parsed["PSHELLs"]==W.imported_native(m)["PSHELLs"]
        rows=Dict(row["id"]=>row for row in result["rows"])
        @test rows["reference.MAT1#8#E"]["normalized_derivative"]≈1 rtol=2e-8
        nsm==0&&(@test rows["reference.MAT1#8#rho"]["normalized_derivative"]≈-1 rtol=2e-8)
        # Independent complete perturbed eigenproblem solves are tests only.
        baseline=solve(joinpath(dir,"baseline.bdf"))
        op=W.sensitivity_assemble(N,baseline["model"];solution=103)
        weight=W.sensitivity_eigen_mass(N,op)
        reference=W.sensitivity_mode_analysis(baseline,1,op.node_R)
        for (field,value) in (("T",.02),("rho",2700.))
            h=value*1e-4;responses=Float64[]
            for sign in (-1,1)
                text=panel_deck(;solution=source_sol,coupled,nsm,
                    thickness=field=="T" ? value+sign*h : .02,rho=field=="rho" ? value+sign*h : 2700.)
                trial=imported(text,tag*"_"*field*"_"*string(sign))
                path=joinpath(dir,"validation_$(field)_$(sign).bdf")
                write(path,W.imported_sensitivity_deck(trial,sid,"103";modes=6))
                solved=solve(path)
                # This single element has distinct bending/rotary modes with
                # identical translations. Full mass-weighted MAC resolves
                # their physical branches without weakening the FD check.
                vectors=[W.sensitivity_mode_analysis(solved,j,op.node_R) for j in eachindex(solved["eigenvalues"])]
                scores=[dot(reference,weight*v)^2/(dot(reference,weight*reference)*dot(v,weight*v)) for v in vectors]
                @test argmax(scores)==1&&scores[1]>.9999
                @test maximum(scores[2:end])<.01
                response=W.sensitivity_response(solved,trial,objective)
                push!(responses,response.value)
            end
            fd=(responses[2]-responses[1])/(2h)
            id=field=="T" ? "reference.PSHELL#123#T" : "reference.MAT1#8#rho"
            derivative=rows[id]["derivative"]
            @test derivative≈fd rtol=2e-5
            push!(metrics,Dict("fixture"=>tag,"variable"=>id,"analytic"=>derivative,"solved_fd"=>fd,"relative_error"=>abs(derivative-fd)/abs(fd)))
        end
        @test W.sensitivity_baseline_load(dir,m;result)["available"]
    end
    # A non-square PBARL exercises its dimensions and native coupled mass.
    beamtext="""
SOL 101
CEND
SUBCASE 19
 SPC=3
 LOAD=5
BEGIN BULK
PARAM,COUPMASS,1
GRID,11,,0.,0.,0.
GRID,85,,2.,0.,0.
CBAR,811,92,11,85,0.,1.,0.
PBARL,92,8,,BAR
,0.04,0.08
MAT1,8,7.0E10,,.3,2700.
SPC1,3,123456,11
FORCE,5,85,0,100.,0.,0.,1.
ENDDATA
"""
    beam=imported(beamtext,"modal_bar")
    objective=Dict("type"=>"frequency_eigenvalue","mode"=>1)
    request=Dict("solution"=>"103","case_id"=>19,"objective"=>objective,
        "variables"=>["reference.PBARL#92#DIM1","reference.MAT1#8#rho"],"derivative_method"=>"analytic")
    dir=joinpath(out,"bar");result=W.compute_sensitivity(beam,request,dir;native=N,solve)
    W.sensitivity_json_write(joinpath(dir,"result.json"),result)
    @test result["status"]=="complete"
    @test result["rows"][2]["normalized_derivative"]≈-1 rtol=2e-8
    h=.04e-4;responses=Float64[]
    for sign in (-1,1)
        trial=imported(replace(beamtext,"0.04,0.08"=>string(.04+sign*h)*",0.08"),"modal_bar_$(sign)")
        path=joinpath(dir,"validation_DIM1_$(sign).bdf");write(path,W.imported_sensitivity_deck(trial,19,"103";modes=6))
        push!(responses,W.sensitivity_response(solve(path),trial,objective).value)
    end
    fd=(responses[2]-responses[1])/(2h);derivative=result["rows"][1]["derivative"]
    @test derivative≈fd rtol=2e-5
    push!(metrics,Dict("fixture"=>"bar","analytic"=>derivative,"solved_fd"=>fd,"relative_error"=>abs(derivative-fd)/abs(fd)))
    @test_throws ArgumentError W.compute_sensitivity(beam,merge(request,Dict("solution"=>"108")),joinpath(out,"unsupported108");native=N,solve)
end
counts=Test.get_test_counts(suite)
W.sensitivity_json_write(joinpath(out,"summary.json"),Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"comparisons"=>metrics))
