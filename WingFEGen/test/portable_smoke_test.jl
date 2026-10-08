# Fresh checkout check. No study, external geometry or private fixture required.
# julia --project=WingFEGen WingFEGen/test/portable_smoke_test.jl [--native] [--output DIR]
using Test,JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
const APP=dirname(@__DIR__)
native="--native" in ARGS
output_index=findfirst(==("--output"),ARGS)
out=output_index===nothing ? mktempdir(;prefix="wingfegen_smoke_",cleanup=false) : abspath(ARGS[output_index+1])
mkpath(out)
println("Portable smoke outputs: ",out);flush(stdout)
function wait_job(job;deadline=time()+900)
    while job.state in (:queued,:running)&&time()<deadline;sleep(.25);end
    if job.state in (:queued,:running)
        job isa W.SensitivityJob ? W.cancel_sensitivity_job!(job;message="Smoke test timeout",state=:failed) : W.kill_job!(job;message="Smoke test timeout",state=:failed)
        error("Owned smoke worker exceeded its deadline")
    end
end
tests=@testset "Portable WingFEGen" begin
    p=W.default_params();W.validate_params(p)
    @test W.read_input(joinpath(APP,"examples","wing_default.toml"))==p
    # A small but complete aerodynamic/structural model for a quick clean-clone check.
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.18,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"fuel.enabled"=>false,
        "loads.method"=>"vortex_lattice","aero.span_panels"=>4,"aero.chord_panels"=>2,
        "loads.cases"=>Any[],"loads.structure_inertia"=>false,"output.solution"=>"101",
        "jfem.output_dir"=>out,"jfem.timeout_minutes"=>15))
    W.validate_params(p)
    model=W.build_model(p)
    @test W.all_checks_pass(model)
    @test model.n_struct>0&&!isempty(model.groups)
    deck=joinpath(out,"portable_smoke.bdf");W.write_nastran(model,deck)
    @test isfile(deck)&&occursin("SOL 101",read(deck,String))
    aero=W.aerodynamic_loads(model)
    @test !isempty(aero.panels)&&!isempty(aero.stations)
    payload=W.mesh_payload(model)
    @test !isempty(payload["groups"])
    for file in ("index.html","app.js","workspace.js","vendor/babylon.js")
        @test isfile(joinpath(APP,"web",file))
    end
    if native
        repo,launcher=W.find_jfem(APP);@test repo!==nothing&&isfile(launcher)
        job=W.start_jfem_job(model,p,APP,deck,"portable_smoke");wait_job(job)
        @test job.state===:done
        job.state===:done||error("Native smoke failed: $(job.message). See $(job.logpath)")
        results=W.jfem_results_payload(job)
        @test results["static"]!==nothing&&!isempty(results["element_results"])
        request=Dict("case_id"=>1,"objective"=>Dict("type"=>"displacement","node_id"=>last(model.node_ids),"component"=>"z"),
            "variables"=>["material.E"],"relative_step"=>.01,"check_step"=>false)
        sensitivity=W.start_sensitivity_job(model,request,APP,"portable_smoke_adjoint");wait_job(sensitivity)
        status=W.sensitivity_status(sensitivity);write(joinpath(out,"sensitivity_status.json"),JSON.json(status))
        @test status["state"]=="done"
        status["state"]=="done"||error("Adjoint smoke failed: $(status["message"])")
        answer=status["result"]
        @test answer["solver_counts"]["forward_solves"]==answer["solver_counts"]["adjoint_solves"]==1
        @test answer["solver_counts"]["perturbed_forward_solves"]==0
        @test answer["method"]=="analytic_discrete_adjoint"
        @test answer["solver_counts"]["finite_difference_samples"]==0
        @test answer["solver_counts"]["analytic_property_derivatives"]==1
        @test isempty(only(answer["rows"])["samples"])
        @test only(answer["rows"])["normalized_derivative"]≈-1 rtol=1e-3
        @test answer["baseline_analysis"]["available"]
    end
end
c=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"native"=>native,"assertions"=>c.passes+c.cumulative_passes,"output"=>out)))
