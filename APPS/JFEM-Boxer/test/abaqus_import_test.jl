using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo=normpath(joinpath(@__DIR__,"..","..",".."))
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
const MESH="""
*HEADING
Portable two-tetra mesh
*NODE
11,0,0,0
12,1,0,0
13,0,1,0
14,0,0,1
15,0,0,-1
*ELEMENT,TYPE=C3D4,ELSET=VOLUME
51,11,12,13,14
52,11,13,12,15
*NSET,NSET=FIXED
11,12,13
*NSET,NSET=TIP
14,15
"""
const SETUP=Dict("enabled"=>true,"E"=>7e10,"nu"=>.3,"rho"=>2700.,"element_set"=>"ALL","constraint_set"=>"FIXED","constraint_dofs"=>"123","force_set"=>"TIP","force_direction"=>[0.,0.,-2.],"total_force"=>120.,"solution"=>"101","modes"=>10)
@testset "Abaqus portable source, mesh-only view and explicit completion" begin
    @test W.imported_source_format("part.inp.gz","")=="abaqus"
    @test W.imported_source_format("part.txt",MESH)=="abaqus"
    mktempdir() do dir
        mkpath(joinpath(dir,"parts"));main="*HEADING\n*INCLUDE, INPUT=\"parts/mesh.inc\"\n"
        write(joinpath(dir,"model.inp"),main);write(joinpath(dir,"parts","mesh.inc"),MESH)
        source=W.imported_source(Dict("path"=>joinpath(dir,"model.inp")))
        @test source["format"]=="abaqus"&&source["source_file_count"]==2
        @test occursin("51,11",source["flattened"])&&!occursin("*INCLUDE",source["flattened"])
        @test W.imported_source(source)["signature"]==source["signature"]
        gz=joinpath(dir,"model.inp.gz")
        open(gz,"w") do io
            stream=W.CodecZlib.GzipCompressorStream(io);write(stream,MESH);close(stream)
        end
        compressed=W.imported_source(Dict("path"=>gz))
        @test compressed["text"]==MESH&&compressed["format"]=="abaqus"
        @test W.imported_source(compressed)["flattened"]==MESH
        pointer=joinpath(dir,"pointer.inp.gz");write(pointer,"version https://git-lfs.github.com/spec/v1\noid sha256:"*repeat("0",64)*"\nsize 1234\n")
        problem=try W.imported_source(Dict("path"=>pointer));nothing catch err;err end
        @test problem isa ArgumentError
        @test occursin("Git LFS pointer",sprint(showerror,problem))
        @test_throws ArgumentError W.imported_source(Dict("path"=>joinpath(dir,"model.inp"),"format"=>"reference","completion"=>SETUP))
    end
    source=W.imported_source(Dict("name"=>"mesh.inp","text"=>MESH))
    doc=Base.invokelatest(N.abaqus_parse_input,MESH)
    native=Base.invokelatest(N.abaqus_to_model,doc;require_analysis=false)
    model=W.imported_model(native,source,W.default_params())
    Base.invokelatest(W.imported_prepare_loads!,N,model)
    payload=W.imported_mesh_payload(model)
    @test !payload["imported_deck"]["analysis_ready"]
    @test payload["imported_deck"]["solution"]==""
    @test isempty(native["MATs"])&&isempty(native["PSOLIDs"])
    @test payload["imported_deck"]["abaqus"]["nsets"]["FIXED"]==[11,12,13]
    boundary=payload["solid_boundary"]
    @test boundary["topology_counts"]["elements"]==2
    @test boundary["topology_counts"]["boundary_faces"]==6
    @test boundary["topology_counts"]["interior_faces"]==1
    @test boundary["triangles"]["count"]==6
    @test Set(reinterpret(Int32,boundary["triangles"]["eids"].bytes))==Set([51,52])
    @test all(el->el["pid"]==0&&el["properties"]["type"]=="Unassigned solid",boundary["elements"])
    completed=Base.invokelatest(N.abaqus_complete_input,doc,SETUP)
    completed_native=Base.invokelatest(N.abaqus_to_model,Base.invokelatest(N.abaqus_parse_input,completed))
    completed_source=W.imported_source(Dict("name"=>"mesh.inp","text"=>MESH,"completion"=>SETUP))
    @test completed_source["text"]==MESH&&completed_source["completion"]==SETUP
    @test completed_source["signature"]!=source["signature"]
    @test W.imported_source(completed_source)["signature"]==completed_source["signature"]
    model=W.imported_model(completed_native,completed_source,W.default_params());Base.invokelatest(W.imported_prepare_loads!,N,model)
    payload=W.imported_mesh_payload(model)
    @test payload["imported_deck"]["analysis_ready"]
    @test payload["imported_deck"]["solution"]=="101"
    @test payload["spc"]["count"]==3
    @test sum(row["force"][3] for row in payload["loads"]["force_stations"])≈-120.
    @test all(el->el["pid"]>0&&el["properties"]["material"]["E_Pa"]==7e10,payload["solid_boundary"]["elements"])
    @test_throws ArgumentError W.imported_analysis_model(model,Dict("solution"=>"103"))
    @test W.imported_analysis_model(model)===model
    @test_throws ArgumentError W.imported_sensitivity_deck(model,1)
    for change in (Dict("E"=>0.),Dict("nu"=>.5),Dict("force_direction"=>zeros(3)),Dict("constraint_set"=>""),Dict("modes"=>201))
        @test_throws ArgumentError W.imported_source_completion(merge(SETUP,change))
    end
end

@testset "Quadratic tetra boundary retains all midside nodes" begin
    nodes=collect(1:10);native=Dict("CSOLIDs"=>Dict("9"=>Dict("ID"=>9,"PID"=>0,"TYPE"=>"CTETRA","ABAQUS_TYPE"=>"C3D10","NODES"=>nodes)),"PSOLIDs"=>Dict())
    boundary=W.imported_solid_boundary(native,Dict(i=>i for i in nodes))
    @test boundary["triangles"]["count"]==16
    @test Set(reinterpret(Int32,boundary["triangles"]["conn"].bytes))==Set(0:9)
    @test only(boundary["elements"])["nodes"]==collect(0:9)
    @test boundary["edges"]["count"]==12
    # Matching quadratic interface shares every face node, independent of
    # order. Equal corners with different midside IDs are not conforming.
    second=Dict("ID"=>10,"PID"=>0,"TYPE"=>"CTETRA","NODES"=>[1,3,2,11,7,6,5,12,13,14])
    native["CSOLIDs"]["10"]=second
    joined=W.imported_solid_boundary(native,Dict(i=>i for i in 1:17))
    @test joined["topology_counts"]["boundary_faces"]==6
    @test joined["topology_counts"]["interior_faces"]==1
    @test joined["triangles"]["count"]==24
    second["NODES"]=[1,3,2,11,15,16,17,12,13,14]
    nonconforming=W.imported_solid_boundary(native,Dict(i=>i for i in 1:17))
    @test nonconforming["topology_counts"]["boundary_faces"]==8
    @test nonconforming["topology_counts"]["interior_faces"]==0
    @test nonconforming["triangles"]["count"]==32
end
