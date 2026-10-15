# Actual HTTP routes and native generated solves. Outputs must be explicitly
# directed outside the checkout: julia --project=. APPS/JFEM-Boxer/test/solver_http_reuse_test.jl OUTPUT
using Test, WingFEGen, HTTP, JSON, MsgPack, SHA
const W=WingFEGen
length(ARGS)==1 || error("Expected OUTPUT directory")
const OUTPUT=abspath(ARGS[1]);mkpath(OUTPUT)
const APP=dirname(dirname(pathof(W)))
const PARAMETERS=merge(W.default_params(),Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,
    "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
    "box.end_eta"=>1.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.18,
    "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"fuel.enabled"=>false,
    "loads.method"=>"analytic","loads.lift_total"=>10.,"loads.load_factor"=>1.,
    "loads.cases"=>Any[],"loads.structure_inertia"=>false,"output.solution"=>"101",
    "output.reference_file"=>joinpath(OUTPUT,"model.bdf"),"jfem.output_dir"=>joinpath(OUTPUT,"runs"),
    "jfem.output_formats"=>"jrs","jfem.timeout_minutes"=>10.))
const INPUT=joinpath(OUTPUT,"input.toml");write(INPUT,W.params_to_toml(PARAMETERS))
const STATE=W.AppState(APP,INPUT;deck_store_dir=joinpath(OUTPUT,"deck_store"))
W.start_solver_worker_service!()
const SERVER=W._start_app_server(W.make_router(STATE),0)
const BASE="http://127.0.0.1:$(HTTP.port(SERVER))"
const RECORDS=Any[]

function request(method,path,data=nothing)
    response=HTTP.request(method,BASE*path,["Content-Type"=>"application/json"],
        data===nothing ? "" : JSON.json(data);status_exception=false,request_timeout=900)
    return response,occursin("msgpack",HTTP.header(response,"Content-Type","")) ?
        MsgPack.unpack(Vector{UInt8}(response.body)) : JSON.parse(String(response.body))
end
function run_case(name,parameters;expected="done",read_results=true)
    response,submitted=request("POST","/api/run_jfem",parameters)
    @test response.status==200 && submitted["ok"]
    submitted["ok"] || error(get(submitted,"error","Request was rejected"))
    @test startswith(submitted["out_dir"],joinpath(OUTPUT,"runs"))
    id=submitted["job"];deadline=time()+900;status=nothing;cursor=0;lines=String[]
    while time()<deadline
        _,status=request("GET","/api/jfem_status?job=$id&from=$cursor")
        append!(lines,status["lines"]);cursor=status["next_line"]
        terminal=status["state"] in ("done","failed","partial","cancelled")
        terminal && status["log_done"] && !status["has_more"] && break
        sleep(.05)
    end
    @test status["state"]==expected && status["log_done"]
    @test !status["has_more"]
    log=HTTP.get(BASE*"/api/jfem_log?job=$id";request_timeout=60)
    @test log.status==200
    text=String(log.body)
    @test !isempty(text)
    write(joinpath(OUTPUT,name*"_status.json"),JSON.json(status))
    write(joinpath(OUTPUT,name*"_download.log"),text)
    write(joinpath(OUTPUT,name*"_polled.log"),join(lines,"\n"))
    result=nothing
    if read_results
        result_response,result=request("GET","/api/jfem_results?job=$id")
        @test result_response.status==200
        @test result["source_model_params"]==result["model_params"]
        @test result["source_model_params"]==W.normalize_params(parameters)[1]
        function provenance(item)
            @test item["source_model_params"]==result["source_model_params"]
            for key in ("load_cases","variants"), child in get(item,key,Any[]);provenance(child);end
        end
        provenance(result)
        write(joinpath(OUTPUT,name*"_results.json"),JSON.json(result))
        write(joinpath(OUTPUT,name*"_results.msgpack"),Vector{UInt8}(result_response.body))
        if name in ("multicase","fuel_multicase","nonlinear_pairs")
            mesh_response=HTTP.post(BASE*"/api/generate",["Content-Type"=>"application/json"],
                JSON.json(parameters);status_exception=false,request_timeout=120)
            @test mesh_response.status==200
            write(joinpath(OUTPUT,name*"_model.msgpack"),Vector{UInt8}(mesh_response.body))
        end
    end
    push!(RECORDS,Dict("name"=>name,"submitted"=>submitted,"status"=>status))
    write(joinpath(OUTPUT,"jobs.json"),JSON.json(RECORDS))
    println(name,": ",status["state"],"; ",status["message"]);flush(stdout)
    return status,result,text,lines
end

suite=@testset "Generated FE HTTP repeats, cases, provenance and errors" begin
    try
        _,schema=request("GET","/api/input")
        @test schema isa AbstractDict
        write(joinpath(OUTPUT,"input_schema.json"),JSON.json(schema))
        first_status,first_result,_,_=run_case("first",PARAMETERS)
        pid=first_status["progress"]["worker_pid"]
        first_path=first_result["results_json"]
        first_hash=sha256(read(first_path))
        for name in ("repeat","repeat_again")
            status,result,_,_=run_case(name,PARAMETERS)
            @test status["progress"]["worker_pid"]==pid
            @test status["progress"]["worker_reused"]
            @test result["static"]["disp"]==first_result["static"]["disp"]
            @test result["out_dir"]!=first_result["out_dir"]
            @test sha256(read(first_path))==first_hash
        end
        cases=[Dict("id"=>2,"label"=>"Double lift","lift_total"=>20.)]
        multiple=merge(PARAMETERS,Dict("loads.cases"=>cases))
        status,result,_,_=run_case("multicase",multiple)
        @test status["progress"]["worker_pid"]==pid
        @test isempty(status["runs"]) # One native deck with two static subcases.
        @test [row["id"] for row in result["load_cases"]]==[1,2]
        a,b=result["load_cases"]
        @test isempty(a["model_params"]["loads.cases"]) && isempty(b["model_params"]["loads.cases"])
        @test a["model_params"]["loads.lift_total"]==10. && b["model_params"]["loads.lift_total"]==20.
        @test reinterpret(Float32,Vector{UInt8}(b["static"]["disp"])) ≈ 2 .* reinterpret(Float32,Vector{UInt8}(a["static"]["disp"])) rtol=2e-6

        fuel=merge(PARAMETERS,Dict("fuel.enabled"=>true,"loads.fuel_percent"=>10.,
            "loads.cases"=>[Dict("id"=>2,"label"=>"Full fuel","fuel_percent"=>100.)]))
        status,result,_,_=run_case("fuel_multicase",fuel)
        @test length(status["runs"])==2
        @test all(row->row["state"]=="done" && row["progress"]["worker_pid"]==pid,status["runs"])
        @test [row["id"] for row in result["load_cases"]]==[1,2]
        @test [row["model_params"]["loads.fuel_percent"] for row in result["load_cases"]]==[10.,100.]

        paired=merge(multiple,Dict("output.solution"=>"106"))
        status,result,_,_=run_case("nonlinear_pairs",paired)
        @test length(status["runs"])==4
        @test all(row->row["state"]=="done" && row["progress"]["worker_pid"]==pid,status["runs"])
        @test all(row->[variant["id"] for variant in row["variants"]]==["sol101","sol106"],result["load_cases"])

        invalid=merge(PARAMETERS,Dict("loads.cases"=>[Dict("id"=>2,"label"=>"")]))
        response,error=request("POST","/api/run_jfem",invalid)
        @test response.status==400 && !error["ok"]
        @test occursin("load case 2 needs a label",error["error"])
        withenv("JFEM_BACKEND"=>"http_regression_invalid_backend") do
            status,_,text,lines=run_case("native_failure",fuel;expected="failed",read_results=false)
            @test all(row->row["state"]=="failed",status["runs"])
            @test occursin("Unsupported JFEM backend",status["message"])
            @test all(row->occursin("Unsupported JFEM backend",row["message"]),status["runs"])
            @test occursin("Unsupported JFEM backend",text)
            @test any(line->occursin("[Failure]",line)&&occursin("Unsupported JFEM backend",line),lines)
            @test status["progress"]["worker_pid"]==pid
            @test status["progress"]["phase"]=="failed"
        end
        status,result,_,_=run_case("after_failure",PARAMETERS)
        @test status["progress"]["worker_pid"]==pid
        @test result["static"]["disp"]==first_result["static"]["disp"]
        @test sha256(read(first_path))==first_hash
    finally
        W.shutdown_solver_worker!(closing=true)
        close(SERVER)
    end
    @test W.SOLVER_WORKER[]===nothing
    @test isempty(W.SOLVER_PENDING_JOBS)
end
counts=Test.get_test_counts(suite)
write(joinpath(OUTPUT,"summary.json"),JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"jobs"=>length(RECORDS))))
