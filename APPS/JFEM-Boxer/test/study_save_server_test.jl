# Run from repository: julia --project=. APPS/JFEM-Boxer/test/study_save_server_test.jl
using Test, HTTP, JSON, SHA
include(joinpath(@__DIR__,"../src/sensitivity_io.jl"))
json_response(data;status=200)=HTTP.Response(status,JSON.json(data))
error_response(error;status=400)=json_response(Dict("ok"=>false,"error"=>error);status)
describe_error(error)=sprint(showerror,error)
include(joinpath(@__DIR__,"../src/study_save_server.jl"))
mutable struct SaveTestState
    input_path::String
end
request(data;origin="http://127.0.0.1:8099",content="application/json")=HTTP.Request("POST","/api/study/write",["Content-Type"=>content,"Host"=>"127.0.0.1:8099","Origin"=>origin],JSON.json(data))
body(response)=JSON.parse(String(response.body))
@testset "Native chosen-file capability and atomic save" begin
 mktempdir() do dir
  st=SaveTestState(joinpath(dir,"input.toml"));path=joinpath(dir,"chosen Study.wingfem.json")
  chosen=handle_study_pick(st,request(Dict("name"=>basename(path)));pick=(name,initial)->Dict("ok"=>true,"path"=>path))
  @test chosen.status==200
  handle=body(chosen)["handle"];token=handle["token"]
  @test length(token)==64
  @test handle["path"]==path
  @test !isfile(path) # selection does not create/truncate the existing file
  for iteration in 1:20
   text=JSON.json(Dict("iteration"=>iteration,"text"=>repeat("complete Study Δ ",1000)))
   response=handle_study_file(st,request(Dict("token"=>token,"text"=>text,"path"=>joinpath(dir,"ignored.json"))))
   @test response.status==200
   @test read(path,String)==text
  end
  @test !isfile(joinpath(dir,"ignored.json"))
  @test readdir(dir)==[basename(path)] # no stale staging files
  loaded=handle_study_file(st,request(Dict("token"=>token));read_only=true)
  @test loaded.status==200
  @test body(loaded)["text"]==read(path,String)
  @test body(loaded)["lastModified"]>0
  original=read(path,String)
  @test handle_study_file(st,request(Dict("token"=>"unknown","text"=>"bad"))).status==400
  @test handle_study_file(SaveTestState(st.input_path),request(Dict("token"=>token,"text"=>"bad"))).status==400
  @test handle_study_file(st,request(Dict("token"=>token,"text"=>"bad");origin="http://other.invalid")).status==400
  @test handle_study_file(st,request(Dict("token"=>token,"text"=>"bad");content="text/plain")).status==400
  @test handle_study_file(st,request(Dict("token"=>token,"text"=>42))).status==400
  @test read(path,String)==original
  @test body(handle_study_pick(st,request(Dict("name"=>"safe.wingfem.json"));pick=(args...)->Dict("ok"=>true,"cancelled"=>true)))["cancelled"]
  @test handle_study_pick(st,request(Dict("name"=>"../unsafe.json"));pick=(args...)->error("must not open")).status==400
  @test body(handle_study_pick(st,request(Dict("name"=>"safe.wingfem.json"));pick=(args...)->Dict("ok"=>true,"available"=>false)))["available"]==false
  @test read(path,String)==original
 end
end
