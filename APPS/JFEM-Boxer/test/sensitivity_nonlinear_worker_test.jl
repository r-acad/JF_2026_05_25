using Test,LinearAlgebra
push!(LOAD_PATH,dirname(@__DIR__))
if !isdefined(@__MODULE__,:W)
    include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
end
if !isdefined(@__MODULE__,:N)
    repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
    include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
end
stable,out=abspath.(ARGS);mkpath(stable);mkpath(out)
const SOLVES=Ref(0)
solve(path)=(SOLVES[]+=1;Base.invokelatest(N.solve_model,Base.invokelatest(N.bdf_to_model,path)))
report=Dict{String,Any}()
checks=@testset "Generated and imported SOL106 sensitivity workflows" begin
    # Curved closed box with property-dependent structural body loads and
    # dependent load-centre GRIDs exercises the full native MPC chain rule.
    p=W.default_params();merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "planform.dihedral"=>3.,"planform.twist_tip"=>-4.,"box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.15,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"aero.enabled"=>false,"fuel.enabled"=>false,
        "loads.structure_inertia"=>true,"loads.lift_total"=>15000.,"loads.torque_y"=>30.,"loads.cases"=>Any[],"output.solution"=>"106",
        "nonlinear.load_steps"=>4,"nonlinear.max_iterations"=>100,"nonlinear.displacement_tolerance"=>1e-10,
        "nonlinear.residual_tolerance"=>1e-10,"loads.follower_forces"=>false))
    m=W.build_model(p);@test !isempty(m.rbe3)
    write(joinpath(stable,"generated.toml"),W.params_to_toml(m.params))
    request=Dict("case_id"=>1,"solution"=>"106","objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z"),
        "variables"=>["material.E","material.rho"],"derivative_method"=>"analytic","relative_step"=>1e-4,"check_step"=>false)
    dir=joinpath(out,"generated");result=Base.invokelatest(W.compute_sensitivity,m,request,dir;native=N,solve)
    W.sensitivity_json_write(joinpath(dir,"result.json"),result)
    @test result["status"]=="complete"
    @test result["solution"]=="106"
    @test result["method"]=="analytic_nonlinear_adjoint"
    @test result["solver_counts"]["forward_solves"]==1
    @test result["solver_counts"]["adjoint_solves"]==1
    @test result["solver_counts"]["perturbed_forward_solves"]==0
    @test result["solver_counts"]["finite_difference_samples"]==0
    @test result["baseline_analysis"]["available"]
    @test SOLVES[]==1
    native=W.JSON.parsefile(joinpath(dir,"baseline_native.json"))
    @test native["analysis_type"]=="SOL106_NONLINEAR_STATIC"
    @test !isempty(native["spc_forces"])
    fddir=joinpath(out,"generated_fd");mkpath(fddir)
    fd=Base.invokelatest(W.compute_sensitivity_fd_validation,m,request,fddir;solve)
    comparisons=Any[]
    for (a,b) in zip(result["rows"],fd["rows"])
        @test a["id"]==b["id"]
        relative=abs(a["derivative"]-b["derivative"])/max(abs(a["derivative"]),abs(b["derivative"]),eps())
        @test relative<2e-4
        push!(comparisons,Dict("id"=>a["id"],"analytic"=>a["derivative"],"fd"=>b["derivative"],"relative_error"=>relative))
    end
    # Explicit linear comparison retains the nonlinear deck's K6ROT value.
    text=read(joinpath(dir,"baseline.bdf"),String);linearpath=joinpath(out,"linear_control.bdf")
    write(linearpath,replace(text,"SOL 106"=>"SOL 101"));linear=solve(linearpath)
    linearvalue=W.sensitivity_response(linear,m,request["objective"]).value
    difference=abs(result["baseline"]["value"]-linearvalue)/max(abs(result["baseline"]["value"]),eps())
    @test difference>1e-4
    report["generated"]=Dict("comparisons"=>comparisons,"nonlinear_vs_linear_relative_difference"=>difference,
        "nodes"=>length(m.node_ids),"rbe3_count"=>length(m.rbe3),"diagnostics"=>result["diagnostics"],"counts"=>result["solver_counts"])
    # Exercise imported dispatch using the previously retained compact plate.
    sourcepath=joinpath(stable,"shell_tangent_operator.bdf");text=read(sourcepath,String)
    parsed=Base.invokelatest(N.bdf_to_model,sourcepath);source=W.imported_source(Dict("name"=>basename(sourcepath),"text"=>text))
    imported=W.imported_model(parsed,source,W.default_params());Base.invokelatest(W.imported_prepare_loads!,N,imported)
    preserved=W.imported_sensitivity_deck(imported,1,"106")
    @test occursin("PARAM,NLLOADSTEPS,4",preserved)
    @test occursin("PARAM,NLMAXITER,100",preserved)
    @test occursin("PARAM,NLRESTOL,1.e-10",preserved)
    plain=join(filter(line->!startswith(line,"PARAM,NL"),split(replace(text,"SOL 106"=>"SOL 101"),'\n')),'\n')
    plainpath=joinpath(out,"imported_linear_source.bdf");write(plainpath,plain)
    plainmodel=W.imported_model(Base.invokelatest(N.bdf_to_model,plainpath),W.imported_source(Dict("name"=>"linear.bdf","text"=>plain)),W.default_params())
    converted=W.imported_sensitivity_deck(plainmodel,1,"106")
    convertedpath=joinpath(out,"imported_converted_controls.bdf");write(convertedpath,converted)
    controls=Base.invokelatest(N.bdf_to_model,convertedpath)
    @test controls["SOL"]==106
    @test controls["PARAM_NLLOADSTEPS"]==20
    @test controls["PARAM_NLMAXITER"]==40
    @test controls["PARAM_NLRESTOL"]<=1e-8
    req=Dict("case_id"=>1,"solution"=>"106","objective"=>Dict("type"=>"displacement","node_id"=>38,"component"=>"z"),"variables"=>["reference.PSHELL#123#T"])
    before=SOLVES[];idir=joinpath(out,"imported")
    ir=Base.invokelatest(W.compute_sensitivity,imported,req,idir;native=N,solve)
    W.sensitivity_json_write(joinpath(idir,"result.json"),ir)
    @test ir["status"]=="complete"
    @test ir["solution"]=="106"
    @test SOLVES[]-before==1
    @test ir["solver_counts"]["adjoint_solves"]==1
    @test ir["solver_counts"]["perturbed_forward_solves"]==0
    @test ir["solver_counts"]["finite_difference_samples"]==0
    @test W.JSON.parsefile(joinpath(idir,"baseline_native.json"))["analysis_type"]=="SOL106_NONLINEAR_STATIC"
    report["imported"]=Dict("baseline"=>ir["baseline"],"rows"=>ir["rows"],"diagnostics"=>ir["diagnostics"],"counts"=>ir["solver_counts"])
end
c=Test.get_test_counts(checks);report["passed"]=true;report["assertions"]=c.passes+c.cumulative_passes
W.sensitivity_json_write(joinpath(out,"summary.json"),report)
