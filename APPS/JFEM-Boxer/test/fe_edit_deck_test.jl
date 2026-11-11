using Test
include(joinpath(@__DIR__,"..","src","fe_edit_geometry.jl"))
include(joinpath(@__DIR__,"..","src","fe_edit_deck.jl"))

const FE_SOURCE="""
\$ Retained engineering note
SOL 101
CEND
SUBCASE 1
  SPC = 1
  LOAD = 2
BEGIN BULK
PARAM,POST,-1
MAT1,1,7.0E10,,.3,2700.
PSHELL,4,1,.002
GRID,11,,0.,0.,0.,7
GRID,12,,2.,0.,0.,7
GRID,13,,2.,1.,0.,7
GRID,14,,0.,1.,0.,7
CQUAD4,101,4,11,12,13,14,23.,.001
SPC1,1,123456,11,14
FORCE,2,13,0,100.,0.,0.,1.
ENDDATA
"""

@testset "Source-preserving FE deck adapter" begin
    deck=fe_edit_deck("sample.bdf",FE_SOURCE);mesh=fe_edit_mesh(deck)
    @test fe_edit_render(deck,mesh)==FE_SOURCE
    @test mesh["nodes"][13]==(2.,1.,0.)
    @test fe_edit_summary(mesh)["bounds"]["max"]==[2.,1.,0.]
    result=fe_cut_mesh(mesh;point=[1.,0.,0.],normal=[1.,0.,0.],side_length=10.,duplicate_cut_nodes=true)
    text=fe_edit_render(deck,result.mesh;node_provenance=result.report["node_provenance"],element_parents=result.report["element_parents"],duplicate_nodes=result.report["duplicate_nodes"])
    @test occursin("SUBCASE 1\n  SPC = 1\n  LOAD = 2",text)
    @test occursin("PSHELL,4,1,.002",text)
    @test occursin("FORCE,2,13,0,100.,0.,0.,1.",text)
    @test occursin("SPC1,1,123456,11,14",text)
    @test occursin("CORD2R,",text)
    recut=fe_edit_deck("sample.bdf",text)
    @test all(el["pid"]==4 for el in recut.elements)
    @test length(recut.elements)>1
    @test length(recut.nodes)>4
    @test maximum(el["id"] for el in recut.elements)>=101
    positive=fe_select_mesh(fe_edit_mesh(recut);point=[1.,0.,0.],normal=[1.,0.,0.],side="positive")
    moved=fe_translate_mesh(fe_edit_mesh(recut),positive;vector=[1.,0.,0.])
    movedtext=fe_edit_render(recut,moved.mesh)
    moveddeck=fe_edit_deck("moved.bdf",movedtext)
    @test moveddeck.nodes[13]==(3.,1.,0.)
    @test moveddeck.nodes[11]==(0.,0.,0.)
    @test occursin("FORCE,2,13,0,100.,0.,0.,1.",movedtext)
    # Coordinate-system IDs and loads are not mistaken for GRID IDs.
    globaldeck=fe_edit_deck("cp.bdf","GRID,9,42,1.,2.,3.,77\n";coordinates=Dict(9=>(10.,20.,30.)))
    @test occursin("GRID,9,0,10.0,20.0,30.0,77",fe_edit_render(globaldeck,fe_edit_mesh(globaldeck)))
    @test_throws ArgumentError fe_edit_deck("cp.bdf","GRID,9,42,1.,2.,3.,77\n")
    # Loaded element splitting cannot silently leave a PLOAD on one child.
    loaded=fe_edit_deck("loaded.bdf",replace(FE_SOURCE,"ENDDATA"=>"PLOAD4,9,101,1.\nENDDATA"))
    @test_throws ArgumentError fe_edit_render(loaded,result.mesh;element_parents=result.report["element_parents"])
end

@testset "Section thickness and material axes survive clipping" begin
    text=replace(FE_SOURCE,"CQUAD4,101,4,11,12,13,14,23.,.001"=>"CQUAD4,101,4,11,12,13,14,23.,.001\n+,,0,1.,3.,3.,1.")
    deck=fe_edit_deck("tapered.bdf",text);cut=fe_cut_mesh(fe_edit_mesh(deck);point=[1.,0.,0.],normal=[1.,0.,0.],side_length=10.,duplicate_cut_nodes=true)
    rendered=fe_edit_render(deck,cut.mesh;node_provenance=cut.report["node_provenance"],element_parents=cut.report["element_parents"],duplicate_nodes=cut.report["duplicate_nodes"])
    rebuilt=fe_edit_deck("tapered.bdf",rendered)
    cid=only(filter(c->c.kind=="CORD2R",rebuilt.records))
    # Rectangle element x is global +x; theta=23 degrees must produce that
    # same basic material direction, regardless of each fragment's first edge.
    @test fe_edit_real(cid.fields[9])≈cosd(23.) atol=1e-12
    @test fe_edit_real(cid.fields[10])≈sind(23.) atol=1e-12
    for c in rebuilt.records
        c.kind in ("CQUAD4","CTRIA3")||continue
        theta=c.kind=="CQUAD4" ? 7 : 6;start=10
        @test fe_edit_int(c.fields[theta])==fe_edit_int(cid.fields[1])
        for (i,id) in enumerate(fe_edit_grid_ids(c))
            @test fe_edit_real(fe_edit_field(c,start+i))≈1.0 + rebuilt.nodes[id][1] atol=1e-12
        end
    end
    mass=fe_edit_deck("mass.bdf","GRID,1,,0.,0.,0.\nCONM2,100,1,-1,20.,1.,2.,3.\n")
    shifted=fe_translate_mesh(fe_edit_mesh(mass),[100];vector=[2.,0.,0.])
    @test occursin("CONM2,100,1,-1,20.,3.0,2.0,3.0",fe_edit_render(mass,shifted.mesh))
    copy=fe_copy_mesh(fe_edit_mesh(mass),[100];vector=[2.,0.,0.])
    @test occursin("CONM2,101,2,-1,20.,3.0,2.0,3.0",fe_edit_render(mass,copy.mesh;copied_node_maps=[copy.report["copies"][1]["node_map"]]))
    triangle=fe_edit_deck("triangle.bdf","GRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nGRID,3,,0.,2.,0.\nCTRIA3,10,1,1,2,3,10.,.001,\n+,,0,.001,.003,.001\nPSHELL,1,1,.002\nMAT1,1,7.e10,,.3\n")
    tri=fe_cut_mesh(fe_edit_mesh(triangle);point=[1.,0.,0.],normal=[1.,0.,0.],side_length=10.)
    tritext=fe_edit_render(triangle,tri.mesh;node_provenance=tri.report["node_provenance"],element_parents=tri.report["element_parents"])
    trideck=fe_edit_deck("tri.bdf",tritext)
    @test Set(el["type"] for el in trideck.elements)==Set(["CTRIA3","CQUAD4"])
    for c in trideck.records
        c.kind in ("CTRIA3","CQUAD4")||continue
        @test fe_edit_field(c,10)=="0"
        for (i,id) in enumerate(fe_edit_grid_ids(c));@test fe_edit_real(fe_edit_field(c,10+i))≈.001+.001trideck.nodes[id][1] atol=1e-12;end
    end
end

@testset "Copies preserve rigid membership without copying loads and constraints" begin
    source=replace(FE_SOURCE,"ENDDATA"=>"RBE3,990,,11,123,1.0,123,12,13,14\nENDDATA")
    deck=fe_edit_deck("rigid.bdf",source);mesh=fe_edit_mesh(deck)
    @test mesh["next_element_id"]==991
    @test only(mesh["rigid_links"])["nodes"]==[11,12,13,14]
    result=fe_copy_mesh(mesh,[101];vector=[3.,0.,0.],count=2)
    text=fe_edit_render(deck,result.mesh;element_parents=result.report["element_parents"],copied_node_maps=[row["node_map"] for row in result.report["copies"]])
    new=fe_edit_deck("copied.bdf",text)
    @test length(new.nodes)==12
    @test length(new.elements)==3
    @test count(c->c.kind=="FORCE",new.records)==1
    @test count(c->c.kind=="SPC1",new.records)==1
    @test count(c->c.kind=="RBE3",new.records)==3
    @test length(unique(c.fields[1] for c in new.records if c.kind in ("CQUAD4","RBE3")))==6
    @test all(c->fe_edit_int(fe_edit_field(c,6))==7,filter(c->c.kind=="GRID",new.records))
    constrained=fe_edit_deck("permanent.bdf",replace(FE_SOURCE,"GRID,13,,2.,1.,0.,7"=>"GRID,13,,2.,1.,0.,7,123"))
    constrainedmesh=fe_edit_mesh(constrained)
    alias=maximum(keys(constrainedmesh["nodes"]))+1
    constrainedmesh["nodes"][alias]=constrainedmesh["nodes"][13]
    aliastext=fe_edit_render(constrained,constrainedmesh;duplicate_nodes=Dict(13=>alias))
    aliasdeck=fe_edit_deck("detached.bdf",aliastext)
    @test fe_edit_field(only(filter(c->c.kind=="GRID"&&c.fields[1]==string(alias),aliasdeck.records)),6)=="7"
    @test fe_edit_field(only(filter(c->c.kind=="GRID"&&c.fields[1]==string(alias),aliasdeck.records)),7)==""
    @test occursin("GRID,13,,2.,1.,0.,7,123",aliastext)
    warpedsource=replace(FE_SOURCE,"GRID,13,,2.,1.,0.,7"=>"GRID,13,,2.,1.,.1,7","PSHELL,4,1,.002"=>"PCOMP,4,,,,,,\n+,1,.002,0.,YES")
    warped=fe_edit_deck("warped_composite.bdf",warpedsource);aliases=fe_edit_mesh(warped)
    aliases["nodes"][15]=aliases["nodes"][13];aliases["elements"][1]["nodes"][3]=15
    for id in aliases["elements"][1]["nodes"];aliases["nodes"][id]=Tuple(collect(aliases["nodes"][id])+[3.,0.,0.]);end
    warpedtext=fe_edit_render(warped,aliases;duplicate_nodes=Dict(13=>15))
    @test !occursin("CORD2R",warpedtext)
    @test occursin("CQUAD4,101,4,11,12,15,14,23.,.001",warpedtext)
end

@testset "Equivalence remaps declared GRID references and rejects ambiguous sets" begin
    source="""
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,1.,0.
GRID,4,,0.,0.,0.
CTRIA3,10,1,4,2,3
SPC1,7,123,4
FORCE,8,4,0,10.,0.,1.,0.
MPC,99,4,1,1.,2,1,-1.
RBE2,11,2,123,4
"""
    deck=fe_edit_deck("merge.bdf",source);mesh=fe_edit_mesh(deck)
    merge=fe_merge_nodes(mesh,[[1,4]];tolerance=1e-6)
    text=fe_edit_render(deck,merge.mesh;node_mapping=merge.report["node_map"])
    @test !occursin("GRID,4,",text)
    @test occursin("CTRIA3,10,1,1,2,3",text)
    @test occursin("SPC1,7,123,1",text)
    @test occursin("FORCE,8,1,0,10.,0.,1.,0.",text)
    @test occursin("MPC,99,1,1,1.,2,1,-1.",text)
    @test occursin("RBE2,11,2,123,1",text)
    ambiguous=fe_edit_deck("sets.bdf",source*"SET1,23,4\n")
    @test_throws ArgumentError fe_edit_render(ambiguous,merge.mesh;node_mapping=merge.report["node_map"])
    ranges=fe_edit_deck("range.bdf",source*"SPC1,6,123,1,THRU,4\n")
    @test occursin("SPC1,6,123,1,2,3",fe_edit_render(ranges,merge.mesh;node_mapping=merge.report["node_map"]))
end
