using Test, LinearAlgebra, SparseArrays, StaticArrays, Dates
include(joinpath(@__DIR__, "..", "..", "src", "solver", "input_context.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "solver", "helpers.jl"))

@testset "Beam orientation follows GA displacement coordinates" begin
    ids = Dict(1=>1, 2=>2, 3=>3)
    points = [0.0 0.0 0.0; 0.0 1.0 0.0; 1.0 0.0 0.0]
    cord = Dict("U"=>[0.0,-1.0,0.0], "V"=>[1.0,0.0,0.0],
        "W"=>[0.0,0.0,1.0], "TYPE"=>"RECTANGULAR")
    model = Dict("GRIDs"=>Dict("1"=>Dict("CD"=>42)), "CORDs"=>Dict("42"=>cord))
    beam = Dict{String,Any}("TYPE"=>"CBEAM", "ID"=>10, "GA"=>1, "GB"=>2,
        "G0"=>0, "V"=>[0.0,1.0,0.0], "OFFT"=>"GGG")
    origin = SVector{3,Float64}(points[1,:])
    axis = SVector{3,Float64}(points[2,:] - points[1,:])
    rotations = [_node_dof_rotation(cord, origin) for _ in 1:3]
    @test resolve_bar_vref(beam,origin,ids,points;model) == SVector(1.0,0.0,0.0)
    @test resolve_bar_vref(beam,origin,ids,points,rotations) == SVector(1.0,0.0,0.0)
    basic = merge(beam, Dict("V"=>[1.0,0.0,0.0], "OFFT"=>"BGG"))
    @test beam_section_axes(beam,origin,axis,ids,points;model) ==
        beam_section_axes(basic,origin,axis,ids,points;model)
    grid_reference = merge(beam,Dict("G0"=>3))
    @test resolve_bar_vref(grid_reference,origin,ids,points;model) == SVector(1.0,0.0,0.0)
    @test beam_section_axes(grid_reference,origin,axis,ids,points;model) ==
        beam_section_axes(basic,origin,axis,ids,points;model)
    parallel_basic = merge(beam,Dict("OFFT"=>"BGG"))
    @test_throws ArgumentError beam_section_axes(parallel_basic,origin,axis,ids,points;model)
    @test_throws ArgumentError beam_section_axes(beam,origin,zeros(3),ids,points;model)

    cylindrical = Dict("U"=>[1.0,0.0,0.0], "V"=>[0.0,1.0,0.0],
        "W"=>[0.0,0.0,1.0], "TYPE"=>"CYLINDRICAL", "Origin"=>zeros(3))
    cylindrical_model = Dict("GRIDs"=>Dict("1"=>Dict("CD"=>43)), "CORDs"=>Dict("43"=>cylindrical))
    at_y = SVector(0.0,1.0,0.0)
    @test resolve_bar_vref(beam,at_y,ids,points;model=cylindrical_model) ≈ SVector(-1.0,0.0,0.0) atol=1e-15
end
