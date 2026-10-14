# Run with the repository root environment; optionally require its current image.
using Test,WingFEGen,OpenJFEM
const W=WingFEGen
isempty(ARGS)&&error("usage: runtime_worker_image_test.jl EVIDENCE_DIR [--require-images]")
const output=abspath(ARGS[1]);mkpath(output)
const app=dirname(@__DIR__)
const repo=W.WingFEGenBootstrap.locate_solver(app)
const require_images="--require-images" in ARGS
tests=@testset "Packaged Boxer model crosses actual import and sensitivity workers" begin
    runtime=W.sensitivity_worker_runtime(repo;select_image=true)
    @test length(runtime.command.exec)==1 # GUI -J flags cannot be inherited.
    @test haskey(runtime.metadata,"sysimage_status")
    @test realpath(Base.active_project())==realpath(joinpath(repo,"Project.toml"))
    @test runtime.metadata["manifest_sha256"]==bytes2hex(W.SHA.sha256(read(joinpath(repo,"Manifest.toml"))))
    if require_images
        @test runtime.metadata["sysimage_status"]=="current"
        @test only(runtime.sysimage_args)=="--sysimage="*runtime.metadata["sysimage"]
    end
    importdir=joinpath(output,"import");mkpath(importdir)
    deck=joinpath(repo,"__Start here!__","examples","precompile","sol101_adjoint_shell.bdf")
    source=W.imported_source(Dict("name"=>basename(deck),"text"=>read(deck,String)))
    parameters=W.default_params();parameters["jfem.output_dir"]=output
    W.Serialization.serialize(joinpath(importdir,"input.jls"),(source,parameters))
    script=joinpath(app,"src","reference_import_worker.jl")
    command=`$(runtime.command) $(runtime.sysimage_args) --startup-file=no --threads=1 --project=$repo $script $importdir $repo $app`
    process=open(joinpath(importdir,"process.log"),"w") do log
        run(pipeline(ignorestatus(command);stdout=log,stderr=log))
    end
    @test success(process)
    imported_runtime=W.JSON.parsefile(joinpath(importdir,"runtime.json"))
    @test realpath(imported_runtime["project"])==realpath(Base.active_project())
    @test imported_runtime["manifest_sha256"]==runtime.metadata["manifest_sha256"]
    expected_packages=Dict("WingFEGen"=>string(Base.pkgversion(W)),
        "OpenJFEM"=>string(Base.pkgversion(OpenJFEM)),
        "HTTP"=>string(Base.pkgversion(W.HTTP)),"JSON"=>string(Base.pkgversion(W.JSON)),
        "ForwardDiff"=>string(Base.pkgversion(OpenJFEM.ForwardDiff)))
    @test imported_runtime["packages"]==expected_packages
    require_images&&(@test realpath(imported_runtime["image"])==realpath(runtime.metadata["sysimage"]))
    model=W.Serialization.deserialize(joinpath(importdir,"model.jls"))
    @test model isa W.Model
    @test model.node_ids==[1,2,3,4]
    @test model.params["imported.source"]["flattened"]==source["flattened"]
    model.params["jfem.output_dir"]=output
    request=Dict("solution"=>"101","case_id"=>1,"variables"=>["reference.MAT1#1#E"],
        "objective"=>Dict("type"=>"displacement","node_id"=>3,"component"=>"z"),"derivative_method"=>"analytic")
    job=W.start_sensitivity_job(model,request,app,"image_roundtrip")
    deadline=time()+900
    while job.state in (:queued,:running)&&time()<deadline;sleep(.2);end
    if job.state in (:queued,:running)
        W.cancel_sensitivity_job!(job;message="Owned runtime test timed out",state=:failed)
        error("Owned sensitivity worker exceeded 900 seconds")
    end
    status=W.sensitivity_status(job)
    write(joinpath(output,"sensitivity_status.json"),W.JSON.json(status))
    @test status["state"]=="done"
    status["state"]=="done"||error(status["message"])
    result=status["result"]
    @test result["solver_counts"]["forward_solves"]==1
    @test result["solver_counts"]["adjoint_solves"]==1
    @test only(result["rows"])["normalized_derivative"]≈-1 rtol=1e-6
    saved=W.JSON.parsefile(joinpath(job.outdir,"runtime.json"))
    @test saved["sysimage_status"]==runtime.metadata["sysimage_status"]
    actual=W.JSON.parsefile(joinpath(job.outdir,"worker_runtime.json"))
    @test realpath(actual["project"])==realpath(Base.active_project())
    @test bytes2hex(W.SHA.sha256(read(joinpath(dirname(actual["project"]),"Manifest.toml"))))==saved["manifest_sha256"]
    @test actual["manifest_sha256"]==saved["manifest_sha256"]
    @test actual["packages"]==expected_packages
    require_images&&(@test realpath(actual["image"])==realpath(runtime.metadata["sysimage"]))
end
counts=Test.get_test_counts(tests)
write(joinpath(output,"summary.json"),W.JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"required_images"=>require_images)))
