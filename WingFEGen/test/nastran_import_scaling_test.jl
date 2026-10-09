using Test, OpenJFEM
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
const N=OpenJFEM
const SOURCE="""
SOL 105
CEND
SPC=1
SUBCASE 1
 LOAD=2
SUBCASE 2
 STATSUB=1
 METHOD=10
SUBCASE 3
 LOAD=2
 SPC=3
SUBCASE 4
 LOAD=4
BEGIN BULK
GRID,11,,0.,0.,0.,,3
GRID,25,,1.,0.,0.
GRID,38,,1.,1.,0.
GRID,49,,0.,1.,0.
CQUAD4,701,123,11,25,38,49
CTRIA3,702,123,11,25,38
PSHELL,123,8,.02
MAT1,8,7.0E10,,.3,2700.
CBAR,801,92,11,25,0.,0.,1.
PBARL,92,8,,T
+,.04,.03,.004,.003
SPC1,1,126,11
SPC1,3,56,38
FORCE,2,25,0,100.,0.,0.,1.
MOMENT,2,38,0,-5.,0.,1.,0.
FORCE,4,49,0,-40.,0.,0.,1.
ENDDATA
"""
@testset "Import load reuse and large-group element axes" begin
    source=W.imported_source(Dict("name"=>"shared_loads.bdf","text"=>SOURCE))
    cc,bulk=N.NastranParser.read_bulk_and_case(readlines(IOBuffer(source["flattened"])))
    cards=N.NastranParser.process_cards(bulk);native=N.build_model(cards,cc)
    N.resolve_nested_coords!(native);N.transform_geometry!(native)
    model=W.imported_model(native,source,W.default_params();cards)
    calls=Int[]
    observed=(Solver=(
        selected_spc_sets=N.Solver.selected_spc_sets,
        get_coord_transform=N.Solver.get_coord_transform,
        _load_sid_scales=N.Solver._load_sid_scales,
        resolve_loads=(m,sid,args...)->begin
            push!(calls,Int(sid));N.Solver.resolve_loads(m,sid,args...)
        end),)
    W.imported_prepare_loads!(observed,model)
    @test calls==[2,4] # Four cases: one call per distinct effective source LOAD.
    loads=model.params["imported.loads"];cases=model.params["imported.cases"]
    @test loads[1]["force_stations"]==loads[2]["force_stations"]==loads[3]["force_stations"]
    @test only(loads[1]["force_stations"])["force"]==[0.,0.,100.]
    @test only(loads[1]["moment_stations"])["moment"]==[0.,-5.,0.]
    @test only(loads[4]["force_stations"])["force"]==[0.,0.,-40.]
    @test occursin("static preload subcase 1",loads[2]["note"])
    @test !occursin("static preload",loads[1]["note"])
    @test cases[1]["spc"]["node_components"]==["1236"]
    @test cases[3]["spc"]["node_components"]==["3","56"]
    @test cases[2]["load_source_case_id"]==1
    # Check every kind and all rows, not just the first element: this is where
    # appending three-tuples made one large property group grow quadratically.
    decode(blob)=copy(reinterpret(Float32,blob.bytes))
    for (kind,count) in ((:quad,40000),(:tria,4),(:bar,4))
        original=only(filter(g->g.kind===kind,model.groups))
        group=W.ElemGroup("large_$(kind)",kind,original.pid)
        append!(group.eids,1:count)
        append!(group.conn,repeat(original.conn,count))
        append!(group.orient,repeat(original.orient,count))
        axes=W.imported_element_axes(model,group)
        expectedcenter=kind===:quad ? [.5,.5,0.] : kind===:tria ? [2/3,1/3,0.] : [.5,0.,0.]
        expectedy=kind===:bar ? [0.,0.,1.] : [0.,1.,0.]
        expectedz=kind===:bar ? [0.,-1.,0.] : [0.,0.,1.]
        @test decode(axes["centers"])≈Float32.(repeat(expectedcenter,count))
        @test decode(axes["x"])==repeat(Float32[1,0,0],count)
        @test decode(axes["y"])==Float32.(repeat(expectedy,count))
        @test decode(axes["z"])==Float32.(repeat(expectedz,count))
        @test decode(axes["lengths"])==ones(Float32,count)
    end
    # Fast standalone-source handling preserves existing CRLF normalization
    # and therefore portable Study identities.
    lf="GRID,1,,0.,0.,0.\nENDDATA\n"
    @test W.imported_expand_includes(_->error("unexpected include"),replace(lf,"\n"=>"\r\n"))==lf
    @test W.imported_expand_includes(_->error("unexpected include"),chop(lf))==chop(lf)
end
