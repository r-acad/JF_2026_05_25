module PandeatorWorkflowTests

using Test, Dates, JSON, MsgPack
include(joinpath(@__DIR__,"..","..","APPS","PANDEATOR_APP","panel_model.jl"))
const APP_DIR=normpath(joinpath(@__DIR__,"..","..","APPS","PANDEATOR_APP"))
const RUN_ROOT=mktempdir()
const SOLVE_LOCK=ReentrantLock()
include(joinpath(APP_DIR,"panel_workflow.jl"))

@testset "Canonical PANDEATOR preview and request validation" begin
    params=Dict{String,Any}("R"=>0.,"length"=>40.,"width"=>40.,"bladeH"=>10.,"footW"=>8.,
        "nx"=>4,"ny"=>4,"nz"=>2,"nf"=>2,"tSkin"=>.2,"tWeb"=>.2,"tFoot"=>.2,"Nx"=>1.)
    response=_panel_model_response(Dict("params"=>params))
    @test response["ok"]
    @test response["mass_tonnes"]>0
    @test !isempty(response["geometry"]["nodes"])
    @test !isempty(response["geometry"]["quads"])
    @test occursin("SOL 105",response["bdf"])
    @test length(response["catalog"]["variables"])==3
    packed=MsgPack.unpack(MsgPack.pack(response))
    @test packed["geometry"]["nodes"][1]["id"]==response["geometry"]["nodes"][1]["id"]
    @test packed["bdf"]==response["bdf"]
    @test !PANEL_ANALYSIS_READY[]
    @test _panel_decode_request((body=UInt8[],))==Dict()
    @test _panel_decode_request((body=MsgPack.pack(Dict("params"=>params)),))["params"]["nx"]==4
    @test_throws ArgumentError _panel_decode_request((body=MsgPack.pack([1,2]),))
    @test_throws ArgumentError _panel_model_response(Dict())
    @test_throws ArgumentError _panel_start_job(Dict("operation"=>"unknown"))
    @test_throws ArgumentError _panel_start_job(Dict("params"=>params,"options"=>[1]))
    @test_throws ArgumentError _panel_start_job(Dict("params"=>params,"operation"=>"validate","variables"=>String[]))
    @test isempty(PANEL_JOBS)
    @test isempty(readdir(RUN_ROOT))
end

@testset "Panel progress retention and cooperative cancellation" begin
    job=Dict{String,Any}("id"=>"unit","operation"=>"validate","status"=>"running","output_dir"=>RUN_ROOT,
        "progress"=>Dict{String,Any}(),"log_events"=>Any[],"log_sequence"=>0,
        "cancel_requested"=>Threads.Atomic{Bool}(false))
    PANEL_JOBS["unit"]=job
    try
        _panel_job_event!(job,Dict("phase"=>"baseline","detail"=>"Solving preload"))
        _panel_job_event!(job,Dict("phase"=>"baseline","detail"=>"Solving preload"))
        @test length(job["log_events"])==1
        for index in 1:510
            _panel_job_event!(job,Dict("phase"=>"finite_difference","detail"=>"Trial $index","completed"=>index,"total"=>510))
        end
        snapshot=_panel_job_status("unit")
        @test snapshot["ok"]
        @test snapshot["progress"]["completed"]==510
        @test length(snapshot["log_events"])==500
        @test first(snapshot["log_events"])["sequence"]==12
        @test last(snapshot["log_events"])["sequence"]==511
        @test !haskey(snapshot,"task")
        cancellation=_panel_cancel_job("unit")
        @test cancellation["cancel_requested"]
        @test cancellation["status"]=="running"
        @test job["cancel_requested"][]
        job["status"]="complete";job["cancel_requested"][]=false
        @test !_panel_cancel_job("unit")["cancel_requested"]
        @test_throws KeyError _panel_job_status("absent")
        @test_throws KeyError _panel_cancel_job("absent")
    finally
        delete!(PANEL_JOBS,"unit")
    end
end

@testset "Public panel result and report preserve numerical meaning" begin
    raw=Dict("value"=>2.,"bad"=>Inf,"_forward"=>Ref(1),"matrix"=>[1. 2.;3. 4.],
        "metadata"=>Dict("_internal"=>()->nothing,"status"=>"ok"))
    public=_panel_public_data(raw)
    @test !haskey(public,"_forward")
    @test public["bad"]===nothing
    @test public["matrix"]==[[1.,2.],[3.,4.]]
    @test public["metadata"]==Dict("status"=>"ok")
    report=_panel_assessment_report(Dict("responses"=>[
        Dict("label"=>"Skin left","value"=>2.,"unit"=>"RF","status"=>"ok","method"=>"Ritz","assumptions"=>["Simply supported"]),
        Dict("label"=>"Column","value"=>3.,"unit"=>"RF","status"=>"ok","method"=>"Euler","assumptions"=>["Pinned ends"])],
        "sensitivities"=>[Dict("response_id"=>"skin_left","variable_id"=>"tSkin","value"=>2.,"unit"=>"RF/mm","status"=>"ok")]))
    @test occursin("| Skin left | 2.0 | RF | ok | Ritz |\n| Column |",report)
    @test occursin("Simply supported",report)
    @test occursin("Pinned ends",report)
    @test occursin("Adjoint derivatives",report)
    compact=_panel_without_binary(Dict("jfem_bytes"=>UInt8[1,2],"jfem_files"=>[Dict("file"=>"panel.jfem","bytes"=>UInt8[3,4])],"value"=>2.))
    @test !haskey(compact,"jfem_bytes")
    @test !haskey(only(compact["jfem_files"]),"bytes")
    @test compact["value"]==2.
end

@testset "Lazy numerical bindings are resolved in the latest Julia world" begin
    function load_and_call()
        Core.eval(@__MODULE__,:(module PandeatorAnalysis
                panel_analyze(model;derivatives=false)=(model=model,derivatives=derivatives)
            end))
        Base.invokelatest(_panel_analyze_current,:synthetic_binding;derivatives=true)
    end
    answer=load_and_call()
    @test answer.model==:synthetic_binding
    @test answer.derivatives
end

end
