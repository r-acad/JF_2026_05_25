using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
length(ARGS)==2||error("Usage: julia --project=. test/imported_material_orientation_test.jl <evidence-directory> <fixture-directory>")
const evidence=abspath(ARGS[1]);const fixtures=abspath(ARGS[2]);mkpath(evidence);mkpath(fixtures)
function solver_parser_path()
    explicit=strip(get(ENV,"JFEM_SOLVER_SOURCE_ROOT",""));container=abspath(joinpath(@__DIR__,"..",".."))
    candidates=isempty(explicit) ? [container,joinpath(container,"01_PUBLIC_PROJECT_REPOSITORY","JFEM")] : [abspath(explicit)]
    for root in candidates
        path=joinpath(root,"src","parsing","ReferenceParser.jl");isfile(path)&&return path
    end
    error("Set JFEM_SOLVER_SOURCE_ROOT to the JFEM repository root")
end
include(solver_parser_path());const N=ReferenceParser
const source_text="""
SOL 103
CEND
TITLE = Imported material directions
SUBCASE 1
  LABEL = THETA and MCID
  METHOD = 7
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,2.,0.,0.
GRID,4,,0.,1.,0.
GRID,5,,1.,1.,0.
GRID,6,,2.,1.,0.
GRID,7,,0.,2.,0.
GRID,8,,1.,2.,0.
GRID,9,,2.,2.,0.
CORD2R,42,,0.,0.,0.,0.,0.,1.
+,0.,1.,0.
CQUAD4,701,123,1,2,5,4,30.
CQUAD4,405,123,2,3,6,5,42
CTRIA3,900,124,4,5,8,42
CTRIA3,802,124,4,8,7,-25.
CQUAD4,995,125,5,6,9,8,0
CQUAD4,996,125,5,6,9,8,0.
CBAR,1100,92,1,2,0.,0.,1.
PSHELL,123,8,.02,8
PSHELL,124,8,.02,8
PSHELL,125,8,.02,8
PBAR,92,8,.003,.00001,.00002,.00001
MAT1,8,7.0E10,,.3,2700.
EIGRL,7,,,3,,,,MASS
ENDDATA
"""
_,bulk=N.read_bulk_and_case(String.(split(source_text,'\n')));cards=N.process_cards(bulk)
# Construct the importer's native record directly from the canonical extractors.
# All GRID and coordinate references are BASIC, so no solver transformation or
# finite-element assembly is needed for this metadata test.
native=Dict{String,Any}("SOL"=>103,"CASE_CONTROL"=>Dict("SUBCASES"=>Dict(1=>Dict("LABEL"=>"THETA and MCID"))),
    "GRIDs"=>N.extract_grid(cards["GRID"]),"CORDs"=>N.extract_coords(cards["CORD2R"]),
    "CSHELLs"=>N.extract_shells(vcat(cards["CQUAD4"],cards["CTRIA3"])),
    "PSHELLs"=>N.extract_props_shell(cards["PSHELL"]),"MATs"=>N.extract_mats(cards["MAT1"]),
    "CBARs"=>N.extract_cbar(cards["CBAR"]),"PBARLs"=>N.extract_pbar(cards["PBAR"]),"SPC1s"=>Any[])
source=W.imported_source(Dict("name"=>"imported_material_directions.bdf","text"=>source_text))
model=W.imported_model(native,source,W.default_params();cards)
decode(blob,T)=copy(reinterpret(T,blob.bytes))
function group_ids(payload,group)
    haskey(group,"eids")&&return decode(group["eids"],Int32)
    bytes=payload["imported_buffers"]["eids"].bytes;offset=group["binary_offsets"][1]
    return reinterpret(Int32,bytes[offset+1:offset+4group["count"]])
end
function check_orientation(payload,native)
    for group in payload["groups"]
        if group["kind"]=="bar"
            @test !haskey(group,"material_orientation");continue
        end
        ids=group_ids(payload,group);orientation=group["material_orientation"]
        @test length(ids)==group["count"]
        @test decode(orientation["mcid"],Int32)==[native["CSHELLs"][string(id)]["MCID"] for id in ids]
        @test decode(orientation["mcid_specified"],Int32)==Int32[native["CSHELLs"][string(id)]["MCID_SPECIFIED"] for id in ids]
        @test decode(orientation["theta"],Float32)==Float32[native["CSHELLs"][string(id)]["THETA"] for id in ids]
    end
end
suite=@testset "Imported shell material orientation and buffer compaction" begin
    @test native["CSHELLs"]["701"]["THETA"]==30. && native["CSHELLs"]["701"]["MCID"]==0
    @test native["CSHELLs"]["405"]["MCID"]==42 && native["CSHELLs"]["405"]["THETA"]==0.
    @test native["CSHELLs"]["802"]["THETA"]==-25.
    @test native["CSHELLs"]["995"]["MCID_SPECIFIED"] && !native["CSHELLs"]["996"]["MCID_SPECIFIED"]
    @test native["CORDs"]["42"]["U"]==[0.,1.,0.]
    before=deepcopy(native);payload=W.imported_mesh_payload(model)
    @test native==before
    @test payload["imported_buffers"]===nothing
    @test decode(only(filter(g->g["pid"]==123,payload["groups"]))["eids"],Int32)==[405,701]
    check_orientation(payload,native)
    restored=W.unpack_view_payload(W.MsgPack.pack(payload));check_orientation(restored,native)
    frames=Dict(c["id"]=>c for c in payload["coordinate_systems"]["systems"])
    @test frames[42]["usage"]["shell_mcid"]==2 && frames[42]["usage"]["shell_eids"]==[405,900]
    @test frames[0]["usage"]["shell_mcid"]==1 && frames[0]["usage"]["shell_eids"]==[995]
    @test isempty(payload["coordinate_systems"]["warnings"])
    # Cross the real >1000-group threshold with two differently oriented
    # elements per property. Native insertion order differs from EID order.
    many=deepcopy(native);many["CSHELLs"]=Dict{String,Any}();many["PSHELLs"]=Dict{String,Any}();empty!(many["CBARs"])
    for i in 1:1001
        pid=2000+i;many["PSHELLs"][string(pid)]=copy(native["PSHELLs"]["123"])
        for (j,original) in ((1,"701"),(0,"405"))
            eid=10000+3i+j
            element=merge(copy(native["CSHELLs"][original]),Dict("ID"=>eid,"PID"=>pid))
            j==1&&(element["THETA"]=-80.0+i/10)
            many["CSHELLs"][string(eid)]=element
        end
    end
    expanded=W.imported_model(many,source,W.default_params();cards)
    compact=W.imported_mesh_payload(expanded)
    @test length(compact["groups"])==1001
    @test compact["imported_buffers"]!==nothing
    @test all(group->!haskey(group,"eids")&&!haskey(group,"axes")&&haskey(group,"material_orientation"),compact["groups"])
    @test length(compact["imported_buffers"]["eids"].bytes)==2002sizeof(Int32)
    check_orientation(compact,many)
    restored_compact=W.unpack_view_payload(W.MsgPack.pack(compact));check_orientation(restored_compact,many)
    @test length(compact["imported_buffers"]["materials"])==1
    write(joinpath(evidence,"payload.msgpack"),W.MsgPack.pack(payload))
    write(joinpath(evidence,"compact-payload.msgpack"),W.MsgPack.pack(compact))
    write(joinpath(evidence,"schema.json"),W.JSON.json(W.schema_payload(W.default_params(),"")))
    write(joinpath(evidence,"params.json"),W.JSON.json(W.default_params()))
    write(joinpath(fixtures,"imported_material_directions.bdf"),source_text)
end
counts=Test.get_test_counts(suite)
write(joinpath(evidence,"summary.json"),W.JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"native_shells"=>6,"small_groups"=>4,
    "compacted_groups"=>1001,"compacted_shells"=>2002,"native_solver_run"=>false),2))
