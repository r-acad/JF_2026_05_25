using Test, OpenJFEM
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
const SOURCE="""
SOL 101
CEND
SUBCASE 1
 SPC=1
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,1.,0.
GRID,4,,1.,1.,0.
GRID,99,,0.,0.,-999.
MAT1,1,7.E10,,.3,2700.
PSHELL,11,1,.01
CTRIA3,101,11,1,2,3
PBAR,12,1,.001,1.E-6,1.E-6,1.E-6
CBEAM,102,12,1,2,0.,0.,1.
PROD,13,1,.003
CROD,103,13,1,3
PELAS,14,1000.
CELAS1,104,14,2,1,4,1
CONM2,105,4,0,3.5
RBE2,106,1,123,2,3
PBARL,16,1,,T
+,0.032,0.020,0.002,0.0025
CBAR,107,16,2,4,0.,0.,1.
SPC1,1,123456,1
ENDDATA
"""
@testset "Imported native beams, rods, springs, constraints and mass markers" begin
    source=W.imported_source(Dict("name"=>"connections.bdf","text"=>SOURCE))
    cc,bulk=OpenJFEM.NastranParser.read_bulk_and_case(readlines(IOBuffer(source["flattened"])))
    cards=OpenJFEM.NastranParser.process_cards(bulk);native=OpenJFEM.build_model(cards,cc)
    OpenJFEM.resolve_nested_coords!(native);OpenJFEM.transform_geometry!(native)
    m=W.imported_model(native,source,W.default_params();cards)
    W.imported_prepare_loads!(OpenJFEM,m)
    mktemp() do path,io
        close(io);W.imported_prepare_inventory!(OpenJFEM,m,cards,path)
    end
    payload=W.imported_mesh_payload(m)
    @test isempty(payload["imported_deck"]["unsupported_visual_cards"])
    @test isempty(payload["imported_deck"]["unprocessed_cards"])
    @test sort(vcat([g.eids for g in m.groups]...))==[101,102,103,107]
    @test only(filter(g->startswith(g["name"],"IMPORTED_CROD_"),payload["groups"]))["properties"]["section"]["area_m2"]==.003
    extras=Dict(row["card"]=>row for row in payload["imported_connections"])
    @test only(extras["CELAS"]["elements"])["nodes"]==[1,3]
    @test only(extras["RBE2/RBAR"]["elements"])["nodes"]==[0,1,2]
    @test only(extras["CONM2"]["elements"])["properties"]["M"]==3.5
    @test payload["spc"]["node_components"]==["123456"]
    @test payload["bbox"]["min"][3]==-999.
    @test payload["display_bbox"]==Dict("min"=>[0.,0.,0.],"max"=>[1.,1.,0.])
    @test 99 in m.node_ids
    original=deepcopy(payload["groups"]);compact=deepcopy(original)
    buffers=W.imported_compact_buffers!(compact;threshold=0)
    for (g,old) in zip(compact,original),(i,field) in enumerate(("eids","conn","orient","centers","x","y","z","lengths"))
        bytes=(i<=3 ? old[field] : old["axes"][field]).bytes;offset=g["binary_offsets"][i]
        @test buffers[field].bytes[offset+1:offset+length(bytes)]==bytes
    end
    for (g,old) in zip(compact,original)
        section=get(old["properties"],"section",nothing);section===nothing||delete!(section,"placement")
        props=deepcopy(g["properties"])
        for key in ("material","face_material","core_material")
            haskey(props,key)&&(props[key]=buffers["materials"][props[key]+1])
        end
        for ply in get(props,"plies",Any[]);ply["material"]=buffers["materials"][ply["material"]+1];end
        @test props==old["properties"]
    end
    mktempdir() do directory
        path=joinpath(directory,"native.jls");W.Serialization.serialize(path,native)
        m.params["imported.native"]=nothing;m.params["imported.native_path"]=path
        @test W.is_imported_model(m)
        @test W.imported_native(m)==native
        @test W.imported_native(m)===m.params["imported.native"]
        @test W.section_definition(m.params,16)==W.imported_section(native["PBARLs"]["16"])
        m.params["imported.native"]=nothing;m.params["imported.native_path"]=path*".missing"
        @test_throws ArgumentError W.imported_native(m)
        m.params["imported.native"]=native
    end
end
