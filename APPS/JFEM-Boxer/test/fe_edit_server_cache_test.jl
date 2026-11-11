module FEEditServerCacheTests
using Test,LinearAlgebra
include(joinpath(@__DIR__,"..","src","fe_edit_geometry.jl"))
include(joinpath(@__DIR__,"..","src","fe_edit_deck.jl"))
include(joinpath(@__DIR__,"..","src","fe_edit_server.jl"))
const IMPORTED_MODELS=Dict{String,Any}()
const IMPORTED_MODELS_LOCK=ReentrantLock()
struct FakeModel
    params::Dict{String,Any}
end
mutable struct FakeJob
    state::Symbol
    model::FakeModel
end
mutable struct FakeState
    model::Any
    jobs::Dict{String,FakeJob}
    sensitivity_jobs::Dict{String,FakeJob}
end

const TEXT="""
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.,1.,0.
GRID,4,,0.,1.,0.
GRID,5,,2.,0.,0.
GRID,6,,3.,0.,0.
GRID,7,,3.,1.,0.
GRID,8,,2.,1.,0.
CQUAD4,1,1,1,2,3,4,0.0
CQUAD4,2,1,5,6,7,8,0.0
PSHELL,1,1,.002
MAT1,1,7.e10,,.3
"""
function session(id)
    deck=fe_edit_deck("cache.bdf",TEXT)
    source=Dict{String,Any}("name"=>"cache.bdf","text"=>TEXT,"flattened"=>TEXT,"signature"=>"source", "format"=>"reference")
    FEEditSession(id,0,source,source,deck,Dict{String,Any}(),Dict{String,Any}[],String[])
end
fake(token)=FakeModel(Dict{String,Any}("imported.token"=>token))

@testset "Borrowed capture avoids duplicate copies without sharing edit results" begin
    s=session("borrowed")
    borrowed=fe_edit_mesh(s.deck;copy_geometry=false)
    @test borrowed["nodes"]===s.deck.nodes
    @test borrowed["elements"]===s.deck.elements
    copied=fe_edit_mesh(s.deck)
    @test copied["nodes"]!==s.deck.nodes
    @test copied["elements"]!==s.deck.elements
    original=deepcopy(s.deck.nodes)
    moved=fe_translate_mesh(borrowed,[1];vector=[0.,0.,2.])
    @test s.deck.nodes==original
    @test moved.mesh["nodes"][1]==[0.,0.,2.]
    @test moved.mesh["nodes"][5]==[2.,0.,0.]
    @test s.deck.elements[1]["nodes"]==[1,2,3,4]
    @test fe_edit_render(s.deck,borrowed)==TEXT
end

@testset "Edit cache evicts only obsolete owned models and protects active jobs" begin
    empty!(IMPORTED_MODELS)
    s=session("owned-cache");st=FakeState(nothing,Dict{String,FakeJob}(),Dict{String,FakeJob}())
    IMPORTED_MODELS["user-baseline"]=fake("user-baseline")
    IMPORTED_MODELS["other-session"]=fake("other-session")
    commit(token)=fe_edit_commit!(st,s,s.source,(model=fake(token),token=token,deck=s.deck);push_history=false)
    commit("edit-1");commit("edit-2")
    @test !haskey(IMPORTED_MODELS,"edit-1")
    @test haskey(IMPORTED_MODELS,"edit-2")
    @test haskey(IMPORTED_MODELS,"user-baseline")
    @test haskey(IMPORTED_MODELS,"other-session")
    st.jobs["active"]=FakeJob(:running,IMPORTED_MODELS["edit-2"])
    commit("edit-3")
    @test haskey(IMPORTED_MODELS,"edit-2")
    @test haskey(IMPORTED_MODELS,"edit-3")
    st.jobs["active"].state=:done
    st.sensitivity_jobs["active"]=FakeJob(:queued,IMPORTED_MODELS["edit-3"])
    commit("edit-4")
    @test !haskey(IMPORTED_MODELS,"edit-2")
    @test haskey(IMPORTED_MODELS,"edit-3")
    st.sensitivity_jobs["active"].state=:done
    commit("edit-5")
    @test !haskey(IMPORTED_MODELS,"edit-3")
    @test !haskey(IMPORTED_MODELS,"edit-4")
    @test FE_EDIT_OWNED_TOKENS[s.id]==Set(["edit-5"])
    @test Set(keys(IMPORTED_MODELS))==Set(["user-baseline","other-session","edit-5"])
end

@testset "Connected parts are cached only for the current revision and plane" begin
    s=session("parts-cache");plane=Dict("point"=>[1.5,0.,0.],"normal"=>[1.,0.,0.],"side_length"=>10.)
    first=fe_edit_cached_parts(s;plane)
    @test first["structural_part_count"]==2
    @test fe_edit_cached_parts(s;plane)===first
    changed=fe_edit_cached_parts(s;plane=merge(plane,Dict("point"=>[.5,0.,0.])))
    @test changed!==first
    s.revision+=1
    @test fe_edit_cached_parts(s;plane)!==first
end

@testset "Operation overlap review cannot merge preexisting anchors or stale groups" begin
    s=session("operation-review")
    pending=Dict{String,Any}("revision"=>0,"operation_id"=>"copy-1","tolerance"=>1e-6,
        "candidate_groups"=>[Dict("nodes"=>[9,3,7],"affected_nodes"=>[9],"anchor_nodes"=>[3,7]),Dict("nodes"=>[10,4],"affected_nodes"=>[10],"anchor_nodes"=>[4])],
        "pairs"=>[[9,3],[9,7],[10,4]])
    FE_EDIT_OPERATION_CANDIDATES[s.id]=pending
    good=Dict("operation_id"=>"copy-1","groups"=>[Dict("nodes"=>[9,7],"retained_node"=>7)],"tolerance"=>1e-6)
    @test fe_edit_operation_groups(s,good)===pending
    @test_throws ArgumentError fe_edit_operation_groups(s,merge(good,Dict("groups"=>[Dict("nodes"=>[9,3,7],"retained_node"=>3)])))
    @test_throws ArgumentError fe_edit_operation_groups(s,merge(good,Dict("groups"=>[Dict("nodes"=>[3,7],"retained_node"=>3)])))
    @test_throws ArgumentError fe_edit_operation_groups(s,merge(good,Dict("groups"=>[Dict("nodes"=>[9,4],"retained_node"=>4)])))
    @test_throws ArgumentError fe_edit_operation_groups(s,merge(good,Dict("operation_id"=>"old")))
    @test_throws ArgumentError fe_edit_operation_groups(s,merge(good,Dict("tolerance"=>1e-3)))
    s.revision+=1
    @test_throws ArgumentError fe_edit_operation_groups(s,good)
end

@testset "Scoped copy overlap review honors an alternative anchor without gluing old nodes" begin
    source="GRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,2.,0.,0.\nGRID,4,,3.,0.,0.\nGRID,7,,2.,0.,0.\nGRID,8,,2.,0.,0.\nCROD,1,1,1,2\nCROD,2,1,3,4\n"
    deck=fe_edit_deck("coincidences.bdf",source);before=fe_edit_mesh(deck;copy_geometry=false)
    copied=fe_copy_mesh(before,[1];vector=[2.,0.,0.],count=1)
    review=fe_operation_equivalence_candidates(before,copied.mesh,copied.report;tolerance=1e-6)
    @test Set(Int.(review["created_nodes"]))==Set([9,10])
    pairs=Set((min(pair...),max(pair...)) for pair in review["pairs"])
    @test (3,9) in pairs
    @test (7,9) in pairs
    @test (8,9) in pairs
    @test !((3,7) in pairs)
    @test !((7,8) in pairs)
    s=session("actual-operation-review")
    pending=merge(Dict{String,Any}(review),Dict("revision"=>0,"operation_id"=>"copy-actual","candidate_groups"=>review["groups"]))
    FE_EDIT_OPERATION_CANDIDATES[s.id]=pending
    chosen=Dict("operation_id"=>"copy-actual","groups"=>[Dict("nodes"=>[9,7],"retained_node"=>7)],"tolerance"=>1e-6)
    @test fe_edit_operation_groups(s,chosen)===pending
    merged=fe_merge_nodes(copied.mesh,[[9,7]];tolerance=1e-6,retained_nodes=[7])
    @test !haskey(merged.mesh["nodes"],9)
    @test all(haskey(merged.mesh["nodes"],id) for id in (3,7,8))
    @test merged.report["node_map"]==Dict(9=>7)
    @test before["nodes"]==deck.nodes
    @test before["elements"][1]["nodes"]==[1,2]
end
end
