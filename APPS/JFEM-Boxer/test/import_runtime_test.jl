# Run in the shared repository environment. Importing a deck must not load the
# numerical solver, browser server or unrelated package precompile workloads.
using Test, LinearAlgebra
const IMPORT_REPO=normpath(joinpath(@__DIR__,"..","..",".."))
include(joinpath(@__DIR__,"..","src","reference_import_native_runtime.jl"))
include(joinpath(@__DIR__,"..","src","reference_import_runtime.jl"))
const N=ImportNative;const W=WingFEGen

const REFERENCE="""
SOL 101
CEND
SUBCASE 1
 LABEL = Combined point load
 LOAD = 7
 SPC = 8
SUBCASE 2
 LABEL = Original point load
 LOAD = 5
 SPC = 8
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,1.,0.
CTRIA3,51,1,1,2,3
MAT1,1,7.0E10,,0.3,2700.
PSHELL,1,1,0.01
FORCE,5,2,0,20.,0.,0.,-1.
MOMENT,5,3,0,4.,1.,0.,0.
LOAD,7,1.,2.,5
SPC1,8,123456,1
ENDDATA
"""
@testset "Import-only source and native display context" begin
    lines=N.ReferenceParser.convert_mystran_to_reference(readlines(IOBuffer(REFERENCE)))
    cc,bulk=N.ReferenceParser.read_bulk_and_case(lines);cards=N.ReferenceParser.process_cards(bulk)
    native=N.build_model(cards,cc);N.resolve_nested_coords!(native);N.transform_geometry!(native)
    source=W.imported_source(Dict("name"=>"two_cases.bdf","text"=>REFERENCE))
    model=W.imported_model(native,source,W.default_params();cards)
    @test !N.needs_numerical_load_runtime(native)
    W.imported_prepare_loads!(N,model)
    payload=W.imported_mesh_payload(model)
    @test payload["nodes"]["count"]==3
    @test length(payload["load_cases"])==2
    cases=Dict(row["id"]=>row for row in payload["load_cases"])
    @test cases[1]["loads"]["force_stations"][1]["force"]==[0.,0.,-40.]
    @test cases[1]["loads"]["moment_stations"][1]["moment"]==[8.,0.,0.]
    @test cases[2]["loads"]["force_stations"][1]["force"]==[0.,0.,-20.]
    @test cases[1]["spc"]["count"]==1
    @test cases[1]["spc"]["assignments"][1]["components"]=="123456"
    @test N.Solver._load_sid_scales(native,7)==Dict(7=>1.,5=>2.)
    @test N.Solver.selected_spc_sets(native,8)==Set([8])
    invalid=deepcopy(native);invalid["LOAD_COMBOS"]=[Dict("SID"=>7,"S"=>1.,"COMPS"=>[Dict("LID"=>7,"S"=>1.)])]
    @test_throws ArgumentError N.Solver._load_sid_scales(invalid,7)
    @test_throws ArgumentError N.Solver.selected_spc_sets(native,99)
    for key in ("GRAVs","RFORCEs","ACCEL1s","PLOAD1s")
        body=deepcopy(native);body[key]=[Dict("SID"=>99)]
        @test !N.needs_numerical_load_runtime(body)
        body[key]=[Dict("SID"=>5)]
        @test N.needs_numerical_load_runtime(body)
    end
    thermal=deepcopy(native);thermal["CASE_CONTROL"]["SUBCASES"][1]["TEMP"]=11
    @test N.needs_numerical_load_runtime(thermal)
    rectangular=Dict("U"=>[1.,0.,0.],"V"=>[0.,1.,0.],"W"=>[0.,0.,1.],"Origin"=>[0.,0.,0.],"TYPE"=>"RECTANGULAR")
    @test N.Solver._node_dof_rotation(rectangular,[0.,1.,0.])≈Matrix{Float64}(I,3,3)
    cylindrical=merge(rectangular,Dict("TYPE"=>"CYLINDRICAL"))
    @test N.Solver._node_dof_rotation(cylindrical,[0.,1.,0.])≈[0. -1. 0.;1. 0. 0.;0. 0. 1.] atol=1e-15
    spherical=merge(rectangular,Dict("TYPE"=>"SPHERICAL"))
    @test det(N.Solver._node_dof_rotation(spherical,[1.,2.,3.]))≈1
end

@testset "Abaqus mesh preserves full connectivity without starting numerical packages" begin
    source=W.imported_source(Dict("name"=>"ten_node.inp","text"=>"""
*NODE
1,0,0,0
2,1,0,0
3,0,1,0
4,0,0,1
5,0.5,0,0
6,0.5,0.5,0
7,0,0.5,0
8,0,0,0.5
9,0.5,0,0.5
10,0,0.5,0.5
*ELEMENT,TYPE=C3D10,ELSET=BODY
51,1,2,3,4,5,6,7,8,
9,10
"""))
    document=N.abaqus_parse_input(source["flattened"]);native=N.abaqus_to_model(document;require_analysis=false)
    @test !N.needs_numerical_load_runtime(native)
    model=W.imported_model(native,source,W.default_params());W.imported_prepare_loads!(N,model)
    payload=W.imported_mesh_payload(model)
    @test native["CSOLIDs"]["51"]["NODES"]==collect(1:10)
    @test !payload["imported_deck"]["analysis_ready"]
    @test payload["solid_boundary"]["triangles"]["count"]==16
    @test isempty(payload["loads"]["force_stations"])
    loaded=Set(String(id.name) for id in keys(Base.loaded_modules))
    @test isempty(intersect(loaded,Set(["OpenJFEM","WingFEGen","HTTP","VortexLattice","ForwardDiff","HDF5","KrylovKit","AlgebraicMultigrid"])))
end
