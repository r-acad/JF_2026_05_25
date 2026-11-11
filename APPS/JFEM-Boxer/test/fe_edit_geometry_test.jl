using Test, LinearAlgebra
include(joinpath(@__DIR__,"..","src","fe_edit_geometry.jl"))

function fe_test_tube(;offset=[0.,0.,0.],span=2.)
    points=[[-1.,0.,-1.],[1.,0.,-1.],[1.,0.,1.],[-1.,0.,1.]]
    nodes=Dict(i=>Tuple(points[mod1(i,4)]+[0.,i>4 ? span : 0.,0.]+offset) for i in 1:8)
    elements=[Dict{String,Any}("id"=>100+i,"type"=>"CQUAD4","pid"=>7,"theta"=>27.,"zoffs"=>0.01,
        "nodes"=>[i,mod1(i+1,4),mod1(i+1,4)+4,i+4]) for i in 1:4]
    Dict{String,Any}("nodes"=>nodes,"elements"=>elements)
end

function fe_test_area(mesh)
    nodes=Dict(id=>collect(xyz) for (id,xyz) in mesh["nodes"])
    sum(_fe_edit_area(e["nodes"],nodes) for e in mesh["elements"])
end

@testset "Conforming, conservative finite-plane shell cut" begin
    source=fe_test_tube();saved=deepcopy(source)
    cut=fe_cut_mesh(source;point=[0.,.37,0.],normal=[0.,1.,0.],side_length=4.)
    @test source==saved
    @test length(cut.mesh["nodes"])==12
    @test length(cut.mesh["elements"])==8
    @test length(cut.report["cut_nodes"])==4
    @test length(cut.report["side_elements"]["positive"])==4
    @test length(cut.report["side_elements"]["negative"])==4
    @test isempty(cut.report["side_elements"]["crossing"])
    @test fe_test_area(cut.mesh)≈fe_test_area(source) rtol=1e-12
    @test all(e->e["pid"]==7 && e["theta"]==27.0 && e["zoffs"]==.01,cut.mesh["elements"])
    @test all(p->p["fraction"]≈.185 || p["fraction"]≈.815,values(cut.report["node_provenance"]))
    @test isempty(fe_cut_mesh(source;point=[0.,.37,0.],normal=[0.,1.,0.],side_length=1.).report["split_elements"])
    # A square covering only half a face must reject, never leave a partial seam.
    @test_throws ArgumentError fe_cut_mesh(source;point=[.8,.37,0.],normal=[0.,1.,0.],side_length=2.4)
    @test source==saved
    reverse=fe_cut_mesh(source;point=[0.,.37,0.],normal=[0.,-2.,0.],side_length=4.)
    @test fe_test_area(reverse.mesh)≈fe_test_area(cut.mesh)
    @test length(reverse.report["cut_nodes"])==4
    remote=fe_cut_mesh(source;point=[10.,.37,10.],normal=[0.,1.,0.],side_length=1.)
    @test isempty(remote.report["split_elements"])
    @test length(remote.mesh["nodes"])==8
    @test length(remote.mesh["elements"])==4
    tangent=fe_cut_mesh(source;point=[0.,0.,0.],normal=[0.,1.,0.],side_length=4.)
    @test isempty(tangent.report["split_elements"])
end

@testset "Seam duplication and translation maintain stationary part" begin
    source=fe_test_tube()
    cut=fe_cut_mesh(source;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test length(cut.report["duplicate_nodes"])==4
    @test length(cut.mesh["nodes"])==16
    pos=cut.report["side_elements"]["positive"];neg=cut.report["side_elements"]["negative"]
    selected_nodes=Set(n for e in cut.mesh["elements"] if e["id"] in pos for n in e["nodes"])
    stationary_nodes=Set(n for e in cut.mesh["elements"] if e["id"] in neg for n in e["nodes"])
    @test isempty(intersect(selected_nodes,stationary_nodes))
    moved=fe_translate_mesh(cut.mesh,pos;direction=[0.,3.,0.],distance=.25)
    @test all(n->moved.mesh["nodes"][n]≈cut.mesh["nodes"][n]+[0.,.25,0.],selected_nodes)
    @test all(n->moved.mesh["nodes"][n]==cut.mesh["nodes"][n],stationary_nodes)
    joined=fe_cut_mesh(source;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    @test_throws ArgumentError fe_translate_mesh(joined.mesh,joined.report["side_elements"]["positive"];vector=[0.,1.,0.])
    detached=fe_translate_mesh(joined.mesh,joined.report["side_elements"]["positive"];vector=[0.,1.,0.],detach_shared=true)
    @test length(detached.report["duplicate_nodes"])==4
end

@testset "Triangle/quad geometry, beams and ID seeds" begin
    mesh=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(2.,0.,0.),3=>(2.,2.,0.),4=>(0.,2.,0.)),
        "elements"=>[Dict{String,Any}("id"=>10,"type"=>"CQUAD4","nodes"=>[1,2,3,4],"pid"=>4)],
        "next_node_id"=>100,"next_element_id"=>1000)
    # One cut corner creates a pentagon that must be triangulated conservatively.
    split=fe_cut_mesh(mesh;point=[.5,0.,0.],normal=[1.,1.,0.],side_length=10.)
    @test all(id->id>=100,keys(split.report["node_provenance"]))
    @test all(id->id==10||id>=1000,keys(split.report["element_parents"]))
    @test all(e->e["type"]=="CTRIA3",split.mesh["elements"])
    @test fe_test_area(split.mesh)≈4.
    beam=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(2.,0.,0.)),
        "elements"=>[Dict{String,Any}("id"=>10,"type"=>"CBEAM","nodes"=>[1,2],"pid"=>9)])
    cut=fe_cut_mesh(beam;point=[.4,0.,0.],normal=[1.,0.,0.],side_length=1.)
    @test length(cut.mesh["elements"])==2
    @test cut.mesh["nodes"][only(cut.report["cut_nodes"])]≈[.4,0.,0.]
    @test all(e->e["type"]=="CBEAM"&&e["pid"]==9,cut.mesh["elements"])
    @test fe_select_mesh(cut.mesh;point=[.4,0.,0.],normal=[1.,0.,0.],side="positive")==cut.report["side_elements"]["positive"]
    @test length(fe_select_mesh(cut.mesh;point=[0.,0.,0.],normal=[1.,0.,0.],side="slab",lower=.4,upper=2.))==1
    @test_throws ArgumentError fe_cut_mesh(beam;point=[0.,0.,0.],normal=[0.,0.,0.],side_length=1.)
end

@testset "Unsupported crossings and rigid boundaries are explicit" begin
    source=fe_test_tube()
    solid=Dict{String,Any}("id"=>200,"type"=>"CHEXA","nodes"=>collect(1:8))
    push!(source["elements"],solid)
    @test_throws ArgumentError fe_cut_mesh(source;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    shell=fe_test_tube()
    shell["rigid_links"]=[Dict{String,Any}("id"=>900,"type"=>"RBE2","nodes"=>[1,7])]
    rigid_cut=fe_cut_mesh(shell;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test rigid_cut.mesh["rigid_links"]==shell["rigid_links"]
    moved=fe_translate_mesh(rigid_cut.mesh,rigid_cut.report["side_elements"]["positive"];vector=[0.,1.,0.])
    @test moved.mesh["rigid_links"]==shell["rigid_links"]
    @test fe_translate_mesh(shell,[101];vector=[1.,0.,0.],detach_shared=true).report["retained_rigid_ids"]==[900]
    @test_throws ArgumentError fe_copy_mesh(shell,[101];vector=[0.,2.,0.])
end

@testset "Existing seam nodes and finite footprints" begin
    cut=fe_cut_mesh(fe_test_tube();point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    repeated=fe_cut_mesh(cut.mesh;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test isempty(repeated.report["split_elements"])
    @test length(repeated.report["duplicate_nodes"])==4
    @test all(id->id in cut.report["cut_nodes"],keys(repeated.report["duplicate_nodes"]))
    # A second disconnected tube lies on the infinite plane but outside its square.
    far=fe_test_tube(;offset=[10.,0.,0.])
    far_cut=fe_cut_mesh(far;point=[10.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    merged=deepcopy(cut.mesh)
    for (id,xyz) in far_cut.mesh["nodes"]
        merged["nodes"][id+1000]=xyz
    end
    for e in far_cut.mesh["elements"]
        copied=deepcopy(e);copied["id"]+=1000;copied["nodes"].+=1000
        push!(merged["elements"],copied)
    end
    scoped=fe_cut_mesh(merged;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test length(scoped.report["duplicate_nodes"])==4
    @test all(id->id<1000,keys(scoped.report["duplicate_nodes"]))
    # A coplanar diaphragm stays attached to the original seam by policy.
    seam=cut.report["cut_nodes"]
    nodes=cut.mesh["nodes"]
    ordered=sort(seam;by=id->atan(nodes[id][3],nodes[id][1]))
    push!(cut.mesh["elements"],Dict{String,Any}("id"=>900,"type"=>"CQUAD4","nodes"=>ordered))
    diaphragm=fe_cut_mesh(cut.mesh;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test diaphragm.report["side_elements"]["coplanar"]==[900]
    @test !isempty(diaphragm.report["warnings"])
    @test only(filter(e->e["id"]==900,diaphragm.mesh["elements"]))["nodes"]==ordered
    # A rigid touching the seam and both sides is preserved while the positive
    # structure gets independent attachment aliases.
    cut.mesh["rigid_links"]=[Dict{String,Any}("id"=>990,"type"=>"RBE2","nodes"=>[1,first(seam),5])]
    retained=fe_cut_mesh(cut.mesh;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test retained.mesh["rigid_links"]==cut.mesh["rigid_links"]
    @test retained.report["retained_rigid_ids"]==[990]
end

@testset "Near-vertex slivers are reported, collapsed faces rejected" begin
    mesh=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(2.,0.,0.),3=>(2.,2.,0.),4=>(0.,2.,0.)),
        "elements"=>[Dict{String,Any}("id"=>10,"type"=>"CQUAD4","nodes"=>[1,2,3,4])])
    cut=fe_cut_mesh(mesh;point=[1e-5,0.,0.],normal=[1.,0.,0.],side_length=10.,tolerance=1e-10)
    @test !isempty(cut.report["warnings"])
    @test fe_test_area(cut.mesh)≈4.
    @test all(e->_fe_edit_area(e["nodes"],cut.mesh["nodes"])>0,cut.mesh["elements"])
    invalid=deepcopy(mesh);invalid["elements"][1]["nodes"]=[1,3,2,4]
    @test_throws ArgumentError fe_cut_mesh(invalid;point=[1.,0.,0.],normal=[1.,0.,0.],side_length=10.)
end

@testset "Slice copying, candidate equivalence and topological safeguards" begin
    source=fe_test_tube(;span=1.)
    copied=fe_copy_mesh(source,[101,102,103,104];vector=[0.,1.,0.],count=2)
    @test length(copied.mesh["nodes"])==24
    @test length(copied.mesh["elements"])==12
    @test length(copied.report["copies"])==2
    @test length(unique(e["id"] for e in copied.mesh["elements"]))==12
    candidates=fe_equivalence_candidates(copied.mesh;tolerance=1e-7)
    @test length(candidates["groups"])==8
    @test all(g->length(g)==2,candidates["groups"])
    merged=fe_merge_nodes(copied.mesh,candidates["pairs"];tolerance=1e-7)
    @test length(merged.mesh["nodes"])==16
    @test length(merged.mesh["elements"])==12
    @test fe_test_area(merged.mesh)≈fe_test_area(source)*3
    @test length(source["nodes"])==8
    @test_throws ArgumentError fe_merge_nodes(source,[[1,2]];tolerance=3.)
    rigid=Dict{String,Any}("nodes"=>Dict(1=>[0.,0.,0.],2=>[0.,0.,0.]),"elements"=>Dict{String,Any}[],
        "rigid_links"=>[Dict{String,Any}("id"=>7,"type"=>"RBE2","nodes"=>[1,2])])
    @test_throws ArgumentError fe_merge_nodes(rigid,[[1,2]];tolerance=.001)
    chain=Dict{String,Any}("nodes"=>Dict(1=>[0.,0.,0.],2=>[.9,0.,0.],3=>[1.8,0.,0.]),"elements"=>Dict{String,Any}[])
    @test fe_equivalence_candidates(chain;tolerance=1.)["groups"]==[[1,2]]
    @test fe_merge_nodes(chain,fe_equivalence_candidates(chain;tolerance=1.)["pairs"];tolerance=1.).report["merged_nodes"]==1
    @test_throws ArgumentError fe_merge_nodes(chain,[[1,2],[2,3]];tolerance=1.)
end

@testset "Large-coordinate and spatial-hash scaling fixtures" begin
    source=fe_test_tube(;offset=[1e8,-2e8,3e8])
    cut=fe_cut_mesh(source;point=[1e8,-2e8+1.,3e8],normal=[0.,1.,0.],side_length=4.)
    @test length(cut.report["cut_nodes"])==4
    # Dense exact superposition must have linear-size output, not N*(N-1)/2 pairs.
    many=Dict{String,Any}("nodes"=>Dict(i=>(0.,0.,0.) for i in 1:10000),"elements"=>Dict{String,Any}[])
    found=fe_equivalence_candidates(many;tolerance=1e-6)
    @test length(found["groups"])==1
    @test length(only(found["groups"]))==10000
    @test length(found["pairs"])==9999
    @test found["hash_cells"]==1
end

@testset "Contained orphan and nested rigid reference nodes follow the part" begin
    source=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(1.,0.,0.),3=>(2.,0.,0.),
        4=>(.5,0.,1.),5=>(.75,0.,2.),6=>(3.,0.,0.)),
        "elements"=>[Dict{String,Any}("id"=>100,"type"=>"CBAR","nodes"=>[1,2]),
            Dict{String,Any}("id"=>200,"type"=>"CBAR","nodes"=>[3,6])],
        "rigid_links"=>[Dict{String,Any}("id"=>900,"type"=>"RBE3","nodes"=>[4,1,2]),
            Dict{String,Any}("id"=>901,"type"=>"RBE2","nodes"=>[5,4])])
    closure=fe_selected_node_closure(source,[100])
    @test closure.nodes==Set([1,2,4,5])
    @test closure.auxiliary_nodes==[4,5]
    moved=fe_translate_mesh(source,[100];vector=[0.,1.,0.])
    @test moved.report["auxiliary_nodes"]==[4,5]
    @test moved.mesh["nodes"][4]≈[.5,1.,1.]
    @test moved.mesh["nodes"][5]≈[.75,1.,2.]
    @test moved.mesh["nodes"][3]==collect(source["nodes"][3])
    copied=fe_copy_mesh(source,[100];vector=[0.,1.,0.])
    @test copied.report["auxiliary_nodes"]==[4,5]
    mapping=only(copied.report["copies"])["node_map"]
    @test Set(keys(mapping))==Set([1,2,4,5])
    @test copied.mesh["nodes"][mapping[4]]≈[.5,1.,1.]
    @test length(copied.mesh["rigid_links"])==4
    @test all(id->id in values(mapping),last(copied.mesh["rigid_links"])["nodes"])
    # Sharing even one orphan with an unselected physical footprint blocks the
    # whole auxiliary component; no partial rigid attachment follows the part.
    boundary=deepcopy(source)
    push!(boundary["rigid_links"],Dict{String,Any}("id"=>902,"type"=>"RBE3","nodes"=>[5,3,6]))
    @test isempty(fe_selected_node_closure(boundary,[100]).auxiliary_nodes)
    @test !isempty(fe_translate_mesh(boundary,[100];vector=[0.,1.,0.]).report["retained_rigid_ids"])
    @test_throws ArgumentError fe_copy_mesh(boundary,[100];vector=[0.,1.,0.])
    # Selecting the complete physical region admits the same nested component.
    @test fe_selected_node_closure(boundary,[100,200]).auxiliary_nodes==[4,5]
end

@testset "Retained seam joints detach positive structure and rejoin explicitly" begin
    source=fe_cut_mesh(fe_test_tube();point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.).mesh
    seam=sort!([id for (id,p) in source["nodes"] if p[2]==1.])
    source["nodes"][100]=[0.,1.,0.] # a mass/reference GRID exactly in the plane
    source["nodes"][110]=[0.,2.5,0.] # a positive-side RBE reference, without an element
    push!(source["elements"],Dict{String,Any}("id"=>700,"type"=>"CONM2","nodes"=>[100],"mass"=>50.))
    source["rigid_links"]=[
        Dict{String,Any}("id"=>900,"type"=>"RBE3","nodes"=>[100,seam[1],seam[2]],"components"=>"123","weights"=>[1.,2.]),
        Dict{String,Any}("id"=>901,"type"=>"RBE2","nodes"=>[1,seam[1],5],"components"=>"123456"),
        Dict{String,Any}("id"=>902,"type"=>"RBE3","nodes"=>[110,5,6],"components"=>"123","weights"=>[3.,4.])]
    saved=deepcopy(source)
    cut=fe_cut_mesh(source;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    @test source==saved
    @test cut.report["retained_rigid_ids"]==[900,901]
    @test Set(cut.report["retained_rigid_reference_nodes"])==Set([100,seam[1],seam[2],1,5])
    @test haskey(cut.report["detached_rigid_nodes"],5) # off-plane structural attachment
    aliases=cut.report["duplicate_nodes"]
    @test aliases[5]!=5
    @test cut.mesh["nodes"][5]==source["nodes"][5]
    @test cut.mesh["nodes"][aliases[5]]==source["nodes"][5]
    links=Dict(link["id"]=>link for link in cut.mesh["rigid_links"])
    @test links[900]==source["rigid_links"][1]
    @test links[901]==source["rigid_links"][2]
    @test links[902]["nodes"]==[110,aliases[5],6]
    @test links[902]["components"]=="123"&&links[902]["weights"]==[3.,4.]
    @test 700 in cut.report["side_elements"]["coplanar"]
    @test !isempty(cut.report["warnings"])
    moved=fe_translate_mesh(cut.mesh,cut.report["side_elements"]["positive"];vector=[0.,.25,0.])
    @test all(id->moved.mesh["nodes"][id]==source["nodes"][id],cut.report["retained_rigid_reference_nodes"])
    @test moved.mesh["nodes"][110]≈source["nodes"][110]+[0.,.25,0.]
    @test moved.mesh["nodes"][aliases[5]]≈source["nodes"][5]+[0.,.25,0.]
    @test moved.mesh["rigid_links"]==cut.mesh["rigid_links"]
    @test only(filter(e->e["id"]==700,moved.mesh["elements"]))["nodes"]==[100]
    @test_throws ArgumentError fe_merge_nodes(moved.mesh,[[old,new] for (old,new) in aliases];tolerance=1e-8)
    restored=fe_translate_mesh(moved.mesh,cut.report["side_elements"]["positive"];vector=[0.,-.25,0.])
    joined=fe_merge_nodes(restored.mesh,[[old,new] for (old,new) in aliases];tolerance=1e-8)
    @test joined.mesh["rigid_links"]==source["rigid_links"]
    @test length(joined.mesh["nodes"])==length(source["nodes"])
    @test fe_test_area(Dict("nodes"=>joined.mesh["nodes"],"elements"=>filter(e->_fe_edit_type(e) in FE_EDIT_SHELL_TYPES,joined.mesh["elements"])))≈fe_test_area(Dict("nodes"=>source["nodes"],"elements"=>filter(e->_fe_edit_type(e) in FE_EDIT_SHELL_TYPES,source["elements"])))
    # The explicit equivalence guard still rejects a self-connected rigid link.
    invalid=deepcopy(cut.mesh)
    push!(invalid["rigid_links"],Dict{String,Any}("id"=>990,"type"=>"RBE2","nodes"=>[5,aliases[5]],"components"=>"123"))
    @test_throws ArgumentError fe_merge_nodes(invalid,[[5,aliases[5]]];tolerance=1e-8)
end

@testset "Finite-plane contour preview is exact and read-only" begin
    source=fe_test_tube();saved=deepcopy(source)
    preview=fe_cut_intersections(source;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    @test source==saved
    @test length(preview["segments"])==4
    @test sum(norm(segment[2]-segment[1]) for segment in preview["segments"])≈8.
    @test preview["intersected_elements"]==[101,102,103,104]
    @test all(p->p[2]≈1.,(p for segment in preview["segments"] for p in segment))
    @test isempty(preview["warnings"])
    reverse=fe_preview_cut_segments(source;point=[0.,1.,0.],normal=[0.,-2.,0.],side_length=4.)
    @test sum(norm(segment[2]-segment[1]) for segment in reverse["segments"])≈8.
    @test isempty(fe_cut_intersections(source;point=[10.,1.,10.],normal=[0.,1.,0.],side_length=1.)["segments"])
    tangent=fe_cut_intersections(source;point=[0.,0.,0.],normal=[0.,1.,0.],side_length=4.)
    @test length(tangent["segments"])==4
    @test sum(norm(segment[2]-segment[1]) for segment in tangent["segments"])≈8.
    square=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(2.,0.,0.),3=>(2.,2.,0.),4=>(0.,2.,0.)),
        "elements"=>[Dict{String,Any}("id"=>10,"type"=>"CQUAD4","nodes"=>[1,2,3,4])])
    partial=fe_cut_intersections(square;point=[.5,1.,0.],normal=[1.,0.,0.],side_length=1.)
    @test length(partial["segments"])==1
    @test sort!([p[2] for p in only(partial["segments"])])≈[.5,1.5]
    @test partial["partial_elements"]==[10]
    @test !isempty(partial["warnings"])
    coplanar=fe_cut_intersections(square;point=[1.,1.,0.],normal=[0.,0.,1.],side_length=4.)
    @test length(coplanar["segments"])==4
    @test sum(norm(segment[2]-segment[1]) for segment in coplanar["segments"])≈8.
    beam=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(0.,2.,0.)),
        "elements"=>[Dict{String,Any}("id"=>100,"type"=>"CBEAM","nodes"=>[1,2])])
    crossing=fe_cut_intersections(beam;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=1.)
    @test isempty(crossing["segments"])
    @test only(crossing["points"])≈[0.,1.,0.]
    @test crossing["intersected_elements"]==[100]
    solid=deepcopy(source);push!(solid["elements"],Dict{String,Any}("id"=>900,"type"=>"CHEXA","nodes"=>collect(1:8)))
    unsupported=fe_cut_intersections(solid;point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.)
    @test unsupported["unsupported_elements"]==[900]
    @test length(unsupported["segments"])==4
end

@testset "Direct translation retains crossing joints without requiring a new cut" begin
    source=Dict{String,Any}("nodes"=>Dict(1=>(0.,0.,0.),2=>(1.,0.,0.),3=>(2.,0.,0.),4=>(3.,0.,0.),
        5=>(.5,1.,0.),6=>(2.5,1.,0.),7=>(1.5,1.,0.)),
        "elements"=>[Dict{String,Any}("id"=>100,"type"=>"CBAR","nodes"=>[1,2]),Dict{String,Any}("id"=>200,"type"=>"CBAR","nodes"=>[3,4])],
        "rigid_links"=>[Dict{String,Any}("id"=>900,"type"=>"RBE3","nodes"=>[7,2,3],"components"=>"123","weights"=>[1.,2.]),
            Dict{String,Any}("id"=>901,"type"=>"RBE3","nodes"=>[5,1,2],"components"=>"123"),
            Dict{String,Any}("id"=>902,"type"=>"RBE3","nodes"=>[6,3,4],"components"=>"123")])
    saved=deepcopy(source)
    moved=fe_translate_mesh(source,[200];vector=[.25,0.,0.])
    @test source==saved
    @test moved.report["retained_rigid_ids"]==[900]
    @test moved.report["retained_rigid_reference_nodes"]==[2,3,7]
    @test Set(keys(moved.report["detached_rigid_nodes"]))==Set([3])
    alias=moved.report["duplicate_nodes"][3]
    @test moved.mesh["nodes"][alias]≈[2.25,0.,0.]
    @test moved.mesh["nodes"][3]==collect(source["nodes"][3])
    @test all(id->moved.mesh["nodes"][id]==collect(source["nodes"][id]),[1,2,3,5,7])
    @test moved.mesh["nodes"][4]≈[3.25,0.,0.]
    @test moved.mesh["nodes"][6]≈[2.75,1.,0.]
    @test moved.mesh["rigid_links"][1:2]==source["rigid_links"][1:2]
    @test moved.mesh["rigid_links"][3]["nodes"]==[6,alias,4]
    @test !isempty(moved.report["warnings"])
    @test_throws ArgumentError fe_merge_nodes(moved.mesh,[[3,alias]];tolerance=1e-8)
    returned=fe_translate_mesh(moved.mesh,[200];vector=[-.25,0.,0.])
    joined=fe_merge_nodes(returned.mesh,[[3,alias]];tolerance=1e-8)
    @test joined.mesh["rigid_links"]==source["rigid_links"]
    @test all(id->joined.mesh["nodes"][id]==collect(source["nodes"][id]),keys(source["nodes"]))
    # Rigid retention does not bypass the explicit shared-physical-node choice.
    shared=deepcopy(source);shared["elements"][2]["nodes"]=[2,4]
    @test_throws ArgumentError fe_translate_mesh(shared,[200];vector=[.25,0.,0.])
    detached=fe_translate_mesh(shared,[200];vector=[.25,0.,0.],detach_shared=true)
    @test haskey(detached.report["duplicate_nodes"],2)
    @test detached.mesh["nodes"][2]==collect(shared["nodes"][2])
    parts=fe_structural_components(source)
    @test length(parts["parts"])==2
    @test parts["element_part"]==Dict(100=>1,200=>2)
    @test parts["parts"][1]["bounds"]["min"]==[0.,0.,0.]
    @test parts["parts"][2]["bounds"]["max"]==[3.,0.,0.]
    @test !parts["rigid_connections_included"]
end

function fe_point_masses(points)
    Dict{String,Any}("nodes"=>Dict(Int(id)=>collect(xyz) for (id,xyz) in points),
        "elements"=>[Dict{String,Any}("id"=>100+Int(id),"type"=>"CONM2","nodes"=>[Int(id)],"mass"=>1.) for id in sort!(collect(keys(points)))])
end

@testset "Operation-only coincidences preserve old duplicates and selected survivors" begin
    source=fe_point_masses(Dict(1=>(0.,0.,0.),10=>(1.,0.,0.),20=>(5.,0.,0.),21=>(5.,0.,0.)))
    moved=fe_translate_mesh(source,[101];vector=[1.,0.,0.])
    scope=fe_operation_equivalence_candidates(source,moved.mesh,moved.report;tolerance=1e-8)
    @test length(scope["groups"])==1
    group=only(scope["groups"])
    @test group["nodes"]==[1,10]
    @test group["retained_node"]==10 # survivor has a higher ID than the moving node
    @test group["affected_nodes"]==[1]
    @test group["anchor_nodes"]==[10]
    @test !any(id->id in (20,21),(id for g in scope["groups"] for id in g["nodes"]))
    merged=fe_merge_nodes(moved.mesh,scope["pairs"];tolerance=1e-8,retained_nodes=[10])
    @test merged.report["node_map"]==Dict(1=>10)
    @test haskey(merged.mesh["nodes"],20)&&haskey(merged.mesh["nodes"],21)
    @test_throws ArgumentError fe_merge_nodes(moved.mesh,scope["pairs"];tolerance=1e-8,retained_nodes=[1,10])
    ambiguous=fe_point_masses(Dict(1=>(0.,0.,0.),10=>(1.,0.,0.),11=>(1.,0.,0.)))
    step=fe_translate_mesh(ambiguous,[101];vector=[1.,0.,0.])
    choices=fe_operation_equivalence_candidates(ambiguous,step.mesh,step.report;tolerance=1e-8)
    choice=only(choices["groups"])
    @test choice["anchor_nodes"]==[10,11]
    @test choice["nodes"]==[1,10] # other old anchor is never silently included
    @test [11,1] in choices["pairs"]
    @test choice["ambiguous"]
    other=fe_merge_nodes(step.mesh,[[11,1]];tolerance=1e-8,retained_nodes=[11])
    @test haskey(other.mesh["nodes"],10)&&haskey(other.mesh["nodes"],11)
    @test other.report["node_map"]==Dict(1=>11)
    old=fe_point_masses(Dict(1=>(0.,0.,0.),10=>(0.,0.,0.)))
    unchanged=fe_translate_mesh(old,[101];vector=[0.,0.,0.])
    @test isempty(fe_operation_equivalence_candidates(old,unchanged.mesh,unchanged.report;tolerance=1e-8)["groups"])
    oldmoved=fe_point_masses(Dict(1=>(0.,0.,0.),2=>(0.,0.,0.),10=>(1.,0.,0.)))
    movedpair=fe_translate_mesh(oldmoved,[101,102];vector=[1.,0.,0.])
    conservative=fe_operation_equivalence_candidates(oldmoved,movedpair.mesh,movedpair.report;tolerance=1e-8)
    @test only(conservative["groups"])["affected_nodes"]==[1]
    @test conservative["ambiguous_affected_nodes"]==[2]
    @test conservative["unresolved_affected_count"]==1
    @test !isempty(conservative["warnings"])
    # Distinct default anchors can still offer one shared alternative. Do not
    # let selecting that alternative in two groups indirectly merge an old pair.
    indirect=fe_point_masses(Dict(1=>(0.,0.,0.),2=>(.9,0.,0.),10=>(9.1,0.,0.),11=>(10.,0.,0.)))
    shifted=fe_translate_mesh(indirect,[101,102];vector=[10.,0.,0.])
    protected=fe_operation_equivalence_candidates(indirect,shifted.mesh,shifted.report;tolerance=1.)
    @test length(protected["groups"])==1
    @test protected["ambiguous_affected_nodes"]==[2]
    @test !any(pair->2 in pair,protected["pairs"])
    near=fe_translate_mesh(source,[101];vector=[1.0000005,0.,0.])
    @test length(fe_operation_equivalence_candidates(source,near.mesh,near.report;tolerance=1e-6)["groups"])==1
    @test isempty(fe_operation_equivalence_candidates(source,near.mesh,near.report;tolerance=1e-8)["groups"])
    invalid=deepcopy(moved.mesh)
    invalid["rigid_links"]=[Dict{String,Any}("id"=>900,"type"=>"RBE2","nodes"=>[1,10])]
    saved=deepcopy(invalid)
    @test_throws ArgumentError fe_merge_nodes(invalid,scope["pairs"];tolerance=1e-8,retained_nodes=[10])
    @test invalid==saved
end

@testset "Stretching and repeated-copy seam candidates are limited to new collisions" begin
    cut=fe_cut_mesh(fe_test_tube();point=[0.,1.,0.],normal=[0.,1.,0.],side_length=4.,duplicate_cut_nodes=true)
    moved=fe_translate_mesh(cut.mesh,cut.report["side_elements"]["positive"];vector=[0.,1.,0.])
    @test isempty(fe_operation_equivalence_candidates(cut.mesh,moved.mesh,moved.report;tolerance=1e-8)["groups"])
    returned=fe_translate_mesh(moved.mesh,cut.report["side_elements"]["positive"];vector=[0.,-1.,0.])
    back=fe_operation_equivalence_candidates(moved.mesh,returned.mesh,returned.report;tolerance=1e-8)
    @test length(back["groups"])==4
    @test all(g->length(g["nodes"])==2,back["groups"])
    joined=fe_merge_nodes(returned.mesh,back["pairs"];tolerance=1e-8,retained_nodes=[g["retained_node"] for g in back["groups"]])
    @test length(joined.mesh["nodes"])==length(cut.mesh["nodes"])-4
    source=fe_test_tube(;span=1.)
    copies=fe_copy_mesh(source,[101,102,103,104];vector=[0.,1.,0.],count=2)
    seams=fe_operation_equivalence_candidates(source,copies.mesh,copies.report;tolerance=1e-8)
    @test length(seams["groups"])==8
    @test count(g->isempty(g["anchor_nodes"]),seams["groups"])==4 # between different new copies
    @test count(g->!isempty(g["anchor_nodes"]),seams["groups"])==4 # new copy versus existing body
    @test seams["unresolved_affected_count"]==0
    stitched=fe_merge_nodes(copies.mesh,seams["pairs"];tolerance=1e-8,retained_nodes=[g["retained_node"] for g in seams["groups"]])
    @test length(stitched.mesh["nodes"])==16
    @test length(stitched.mesh["elements"])==12
    @test fe_test_area(stitched.mesh)≈3fe_test_area(source)
    zero=fe_copy_mesh(source,[101,102,103,104];vector=[0.,0.,0.])
    zero_scope=fe_operation_equivalence_candidates(source,zero.mesh,zero.report;tolerance=1e-8)
    @test length(zero_scope["groups"])==8
    @test !isempty(zero.report["warnings"])
    snapshot=deepcopy(zero.mesh)
    @test_throws ArgumentError fe_merge_nodes(zero.mesh,zero_scope["pairs"];tolerance=1e-8,
        retained_nodes=[g["retained_node"] for g in zero_scope["groups"]])
    @test zero.mesh==snapshot # duplicate-element protection is transactional
    point=fe_point_masses(Dict(1=>(0.,0.,0.)))
    zero_points=fe_copy_mesh(point,[101];vector=[0.,0.,0.],count=2)
    point_scope=fe_operation_equivalence_candidates(point,zero_points.mesh,zero_points.report;tolerance=1e-8)
    @test only(point_scope["groups"])["affected_nodes"]==[2,3]
    @test point_scope["created_nodes"]==[2,3]
    oldpairs=fe_point_masses(Dict(1=>(0.,0.,0.),2=>(0.,0.,0.)))
    duplicated=fe_copy_mesh(oldpairs,[101,102];vector=[0.,0.,0.])
    preserved=fe_operation_equivalence_candidates(oldpairs,duplicated.mesh,duplicated.report;tolerance=1e-8)
    @test only(preserved["groups"])["anchor_nodes"]==[1,2]
    @test only(preserved["groups"])["affected_nodes"]==[3]
    @test preserved["ambiguous_affected_nodes"]==[4]
end

@testset "Optimized edits retain independent snapshots of all mutable data" begin
    source=fe_point_masses(Dict(1=>(0.,0.,0.),2=>(1.,0.,0.)))
    source["metadata"]=Dict("values"=>[1.,2.])
    source["elements"][2]["nested"]=Dict("values"=>[3.,4.])
    source["rigid_links"]=[Dict{String,Any}("id"=>900,"type"=>"RBE2","nodes"=>[1,2],"weights"=>[.5,.5])]
    moved=fe_translate_mesh(source,[101];vector=[0.,1.,0.])
    moved.mesh["metadata"]["values"][1]=99.
    moved.mesh["elements"][2]["nested"]["values"][1]=98.
    moved.mesh["rigid_links"][1]["weights"][1]=97.
    moved.mesh["nodes"][2][1]=96.
    @test source["metadata"]["values"]==[1.,2.]
    @test source["elements"][2]["nested"]["values"]==[3.,4.]
    @test source["rigid_links"][1]["weights"]==[.5,.5]
    @test source["nodes"][2]==[1.,0.,0.]
end
