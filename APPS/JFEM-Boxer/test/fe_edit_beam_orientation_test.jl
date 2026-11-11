using Test,LinearAlgebra
include(joinpath(@__DIR__,"..","src","fe_edit_geometry.jl"))
include(joinpath(@__DIR__,"..","src","fe_edit_deck.jl"))

const ORIENTATION_SOURCE="""
GRID,1,,10.,0.,0.,42
GRID,2,,12.,0.,0.,42
GRID,3,,10.,2.,1.
GRID,4,,0.,0.,0.
GRID,5,,0.,2.,0.
GRID,6,,30.,0.,0.
GRID,7,,32.,0.,0.
GRID,8,,30.,1.,0.
CBAR,16019518,7,1,2,3,,,GOG
+,5,6,.1,.2,0.,.3,0.,.1
CBAR,16019519,7,4,5,2,,,GGG
CBEAM,16019520,7,1,2,3,,,GOO
+,0,0,.01,0.,0.,.02,0.,0.
+,41,42
CBAR,16019521,7,6,7,8,,,GGG \$ unchanged source record
"""

card(deck,id)=only(filter(row->!isempty(row.fields)&&fe_edit_int(row.fields[1])==id&&row.kind in ("CBAR","CBEAM"),deck.records))
function simple_beam(;base=[0.,0.,0.],tip=[2.,0.,0.],reference=[0.,2.,1.])
    text="GRID,1,,"*join(base,",")*"\nGRID,2,,"*join(tip,",")*"\nGRID,3,,"*join(reference,",")*"\nCBAR,16019518,7,1,2,3,,,GGG\n"
    fe_edit_deck("beam.bdf",text)
end

@testset "Automatic BASIC orientations preserve moving and stationary beam frames" begin
    deck=fe_edit_deck("source.bdf",ORIENTATION_SOURCE)
    moved=fe_translate_mesh(fe_edit_mesh(deck),[16019518,16019520];vector=[0.,0.,3.])
    conversions=fe_edit_preserve_beam_orientations!(deck,moved.mesh)
    @test Set(row["eid"] for row in conversions)==Set([16019518,16019519,16019520])
    @test deck.nodes[3]==(10.,2.,1.)
    text=fe_edit_render(deck,moved.mesh);parsed=fe_edit_deck("moved.bdf",text)
    @test parsed.nodes[1]==(10.,0.,3.)
    @test parsed.nodes[2]==(12.,0.,3.)
    @test parsed.nodes[3]==(10.,2.,1.)
    @test parsed.nodes[4]==deck.nodes[4]
    @test parsed.nodes[5]==deck.nodes[5]
    for id in (16019518,16019520)
        c=card(parsed,id)
        @test fe_edit_orientation_grid(c)==0
        @test [fe_edit_real(c.fields[i]) for i in 5:7]≈[0.,2.,1.]/sqrt(5.) atol=1e-15
        @test c.fields[9:end]==card(deck,id).fields[9:end]
    end
    @test card(parsed,16019518).fields[8]=="BOG"
    @test card(parsed,16019520).fields[8]=="BOO"
    # This beam did not move, but its G0=2 did. Its section must stay fixed.
    @test [fe_edit_real(card(parsed,16019519).fields[i]) for i in 5:7]==[1.,0.,0.]
    @test card(parsed,16019519).fields[8]=="BGG"
    @test card(parsed,16019521).raw==card(deck,16019521).raw
    @test ORIENTATION_SOURCE==join((record.raw for record in deck.records),"\n")
end

@testset "Copy and cut use the original G0 direction" begin
    deck=fe_edit_deck("source.bdf",ORIENTATION_SOURCE)
    copied=fe_copy_mesh(fe_edit_mesh(deck),[16019518,16019520];vector=[0.,0.,5.])
    converted=fe_edit_preserve_beam_orientations!(deck,copied.mesh)
    @test length(converted)==2
    text=fe_edit_render(deck,copied.mesh;copied_node_maps=[row["node_map"] for row in copied.report["copies"]])
    parsed=fe_edit_deck("copy.bdf",text)
    @test card(parsed,16019518).raw==card(deck,16019518).raw
    for row in converted
        c=card(parsed,row["eid"])
        @test fe_edit_orientation_grid(c)==0
        @test [fe_edit_real(c.fields[i]) for i in 5:7]≈[0.,2.,1.]/sqrt(5.) atol=1e-15
    end
    @test parsed.nodes[3]==deck.nodes[3]
    simple=simple_beam();cut=fe_cut_mesh(fe_edit_mesh(simple);point=[1.,0.,0.],normal=[1.,0.,0.],side_length=10.)
    @test length(fe_edit_preserve_beam_orientations!(simple,cut.mesh))==2
    cutdeck=fe_edit_deck("cut.bdf",fe_edit_render(simple,cut.mesh;element_parents=cut.report["element_parents"]))
    @test all(fe_edit_orientation_grid(c)==0 for c in cutdeck.records if c.kind=="CBAR")
end

@testset "Defaults, explicit vector detection and invalid source directions" begin
    source=replace(ORIENTATION_SOURCE,"CBAR,16019518,7,1,2,3,,,GOG"=>"BAROR,,7,,,,,,GOO\nCBAR,16019518,7,1,2,3,,,")
    deck=fe_edit_deck("default.bdf",source)
    moved=fe_translate_mesh(fe_edit_mesh(deck),[16019518,16019520];vector=[0.,0.,3.])
    fe_edit_preserve_beam_orientations!(deck,moved.mesh)
    @test card(fe_edit_deck("d.bdf",fe_edit_render(deck,moved.mesh)),16019518).fields[8]=="BOO"
    explicit=FEEditCard("CBAR",["1","7","10","20","1","0","1","GGG"],"")
    @test fe_edit_orientation_grid(explicit)==0
    @test fe_edit_node_fields(explicit)==[3,4]
    shorthand=fe_edit_deck("b.bdf",replace(ORIENTATION_SOURCE,"GOG"=>"B"))
    @test fe_edit_beam_offt(shorthand,card(shorthand,16019518))==("BGG","BGG")
    bit=fe_edit_deck("bit.bdf",replace(ORIENTATION_SOURCE,"CBEAM,16019520,7,1,2,3,,,GOO"=>"CBEAM,16019520,7,1,2,3,,,0.0"))
    changed=fe_translate_mesh(fe_edit_mesh(bit),[16019518,16019520];vector=[0.,0.,3.])
    @test_throws ArgumentError fe_edit_preserve_beam_orientations!(bit,changed.mesh)
    for invalid in (simple_beam(reference=[0.,1e-7,0.]),simple_beam(reference=[1.,0.,0.]),simple_beam(tip=[0.,0.,0.]),simple_beam(reference=[0.,0.,0.]))
        moved=fe_translate_mesh(fe_edit_mesh(invalid),[16019518];vector=[0.,0.,3.])
        @test_throws ArgumentError fe_edit_preserve_beam_orientations!(invalid,moved.mesh)
    end
    small=simple_beam(base=[1e8,0.,0.],tip=[1e8+2,0.,0.],reference=[1e8,1e-5,2e-5])
    moved=fe_translate_mesh(fe_edit_mesh(small),[16019518];vector=[0.,0.,3.])
    @test only(fe_edit_preserve_beam_orientations!(small,moved.mesh))["basic_vector"]≈[0.,1.,2.]/sqrt(5.) atol=1e-15
end
