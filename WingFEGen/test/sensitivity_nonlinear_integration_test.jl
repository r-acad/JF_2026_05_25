using Test,LinearAlgebra,SHA
push!(LOAD_PATH,dirname(@__DIR__))
if !isdefined(@__MODULE__,:W)
    include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
end
if !isdefined(@__MODULE__,:N)
    repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
    include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
end
stable,out=abspath.(ARGS);mkpath(stable);mkpath(out)
const REPORT=Any[]
function deck(kind;E=7e10,dimension=kind=="shell" ? .02 : .08,residual="tangent_operator")
    bulk=kind=="shell" ? """
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,$dimension,8,,8
SPC1,20,123456,11,49
FORCE,31,25,0,100.,0.,0.,1.
FORCE,31,38,0,100.,0.,0.,1.
FORCE,31,25,0,1000.,-1.,0.,0.
FORCE,31,38,0,1000.,-1.,0.,0.
""" : """
GRID,11,,0.,0.,0.
GRID,25,,.5,0.,0.
GRID,38,,1.,0.,0.
CBAR,701,123,11,25,0.,1.,0.
CBAR,702,123,25,38,0.,1.,0.
PBARL,123,8,,BAR
+,.04,$dimension
SPC1,20,123456,11
FORCE,31,38,0,200.,0.,1.,0.
FORCE,31,38,0,5000.,-1.,0.,0.
"""
    """
SOL 106
CEND
SUBCASE 1
 SPC = 20
 LOAD = 31
BEGIN BULK
PARAM,K6ROT,100.
PARAM,SNORM,0.
PARAM,NLLOADSTEPS,4
PARAM,NLMAXITER,100
PARAM,NLTOL,1.e-10
PARAM,NLRESTOL,1.e-10
PARAM,NLCUTMAX,8
PARAM,NLRESMODEL,$residual
$bulk
MAT1,8,$E,,.3,2700.
ENDDATA
"""
end
function solve_text(text,path)
    write(path,text);Base.invokelatest(N.solve_model,Base.invokelatest(N.bdf_to_model,path))
end
function model(text,path)
    write(path,text);parsed=Base.invokelatest(N.bdf_to_model,path)
    source=W.imported_source(Dict("name"=>basename(path),"text"=>text))
    m=W.imported_model(parsed,source,W.default_params());Base.invokelatest(W.imported_prepare_loads!,N,m)
    m
end
checks=@testset "Actual SOL106 analytic residual adjoint" begin
    for kind in ("shell","bar"),residual in ("tangent_operator","secant_geometric")
        tag=kind*"_"*residual;dir=joinpath(out,tag);mkpath(dir)
        text=deck(kind;residual);path=joinpath(stable,tag*".bdf");m=model(text,path)
        forward=Base.invokelatest(N.solve_model,deepcopy(W.imported_native(m)))
        objective=Dict("type"=>"displacement","node_id"=>38,"component"=>kind=="shell" ? "z" : "y")
        context=Base.invokelatest(W.sensitivity_nonlinear_context,N,forward,m,objective)
        @test context.diagnostics["forward_replay_residual"]<1e-8
        @test context.diagnostics["adjoint_relative_residual"]<1e-9
        @test context.diagnostics["geometric_replay_relative_error"]<1e-10
        @test context.diagnostics["jacobian_nonsymmetry"]>1e-7
        catalog=W.sensitivity_catalog(m)["variables"]
        wanted=kind=="shell" ? ["reference.MAT1#8#E","reference.PSHELL#123#T"] : ["reference.MAT1#8#E","reference.PBARL#123#DIM2"]
        # Check descriptor names independently of catalogue ordering.
        selected=filter(d->d["id"] in wanted,catalog)
        if length(selected)!=2
            println("CATALOG_IDS ",getindex.(catalog,"id"));error("Expected material and section descriptor")
        end
        linear=solve_text(replace(text,"SOL 106"=>"SOL 101"),joinpath(dir,"linear_control.bdf"))
        linear_value=W.sensitivity_response(linear,m,objective).value
        nonlinear_delta=abs(context.baseline-linear_value)/max(abs(context.baseline),eps())
        @test nonlinear_delta>1e-3
        for d in selected
            exact=Base.invokelatest(W.sensitivity_nonlinear_derivative,N,context,m,d)
            isE=endswith(d["id"],"#E");x=isE ? 70. : kind=="shell" ? .02 : .08
            h=x*1e-4;values=Float64[]
            for sign in (-1,1)
                modified=deck(kind;E=isE ? (x+sign*h)*1e9 : 7e10,dimension=isE ? (kind=="shell" ? .02 : .08) : x+sign*h,residual)
                trial=solve_text(modified,joinpath(dir,replace(d["id"],"#"=>"_")*"_"*string(sign)*".bdf"))
                push!(values,W.sensitivity_response(trial,m,objective).value)
            end
            fd=(values[2]-values[1])/(2h);relative=abs(exact["value"]-fd)/max(abs(fd),abs(exact["value"]),eps())
            @test relative<2e-4
            @test exact["forward_solves"]==0
            push!(REPORT,Dict("case"=>tag,"variable"=>d["id"],"analytic"=>exact["value"],"fd"=>fd,"relative_error"=>relative,
                "nonlinear_vs_linear_relative_difference"=>nonlinear_delta,"diagnostics"=>context.diagnostics))
        end
        partial=deepcopy(forward);only(partial["subcases"])["nonlinear_diagnostics"]["final_load_scale"]=.5
        @test_throws ArgumentError W.sensitivity_nonlinear_context(N,partial,m,objective)
        @test_throws ErrorException W.sensitivity_nonlinear_context(N,linear,m,objective)
        formal=deepcopy(forward);formal["model"]["PARAM_NLMETHOD"]="formal_shell_von_karman"
        @test_throws ArgumentError W.sensitivity_nonlinear_context(N,formal,m,objective)
        @test_throws ArgumentError W.sensitivity_nonlinear_context(N,forward,m,merge(objective,Dict("type"=>"shell_stress")))
        W.sensitivity_json_write(joinpath(out,"progress.json"),REPORT)
    end
end
c=Test.get_test_counts(checks)
W.sensitivity_json_write(joinpath(out,"summary.json"),Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes,"checks"=>REPORT))
