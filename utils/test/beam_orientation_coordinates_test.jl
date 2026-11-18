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

@testset "Beam end offsets resolve their independent OFFT frames" begin
    first_point = SVector(0.2, -0.1, 0.3)
    second_point = SVector(1.7, 0.4, 0.6)
    points = Matrix(hcat(first_point, second_point)')
    ids = Dict(11=>1, 22=>2)
    first_angle, second_angle = 0.47, -0.31
    rotation(angle) = [cos(angle) -sin(angle) 0.0; sin(angle) cos(angle) 0.0; 0.0 0.0 1.0]
    first_rotation, second_rotation = rotation(first_angle), rotation(second_angle)
    cord(matrix) = Dict("U"=>matrix[:,1], "V"=>matrix[:,2],
        "W"=>matrix[:,3], "TYPE"=>"RECTANGULAR")
    model = Dict("GRIDs"=>Dict(
        "11"=>Dict("CD"=>41, "X"=>collect(first_point)),
        "22"=>Dict("CD"=>42, "X"=>collect(second_point)),
        "33"=>Dict("CD"=>0, "X"=>collect(first_point + SVector(0.0,1.0,0.5)))),
        "CORDs"=>Dict("41"=>cord(first_rotation), "42"=>cord(second_rotation)))
    first_offset = SVector(0.01, 0.03, -0.02)
    second_offset = SVector(-0.04, 0.02, 0.01)
    orientation = SVector(0.0, 1.0, 0.5)
    beam = Dict{String,Any}("ID"=>10, "TYPE"=>"CBEAM", "GA"=>11, "GB"=>22,
        "V"=>collect(orientation), "G0"=>0, "OFFT"=>"BBB",
        "WA"=>collect(first_offset), "WB"=>collect(second_offset))
    expected = bar_offsets_and_endpoints(beam, first_point, second_point)

    displacement_frames = deepcopy(beam)
    displacement_frames["OFFT"] = "GGG"
    displacement_frames["V"] = first_rotation' * orientation
    displacement_frames["WA"] = first_rotation' * first_offset
    displacement_frames["WB"] = second_rotation' * second_offset
    resolved = bar_offsets_and_endpoints(displacement_frames, first_point, second_point; model)
    for index in (1,2,4,5)
        @test resolved[index] ≈ expected[index] atol=2e-15
    end
    @test resolved[3]
    # Each GRID has its own displacement frame. The computational nodal frame
    # may differ from CD, so explicit model coordinates take precedence.
    resolved_with_frames = bar_offsets_and_endpoints(displacement_frames, first_point, second_point;
        model, id_map=ids, node_coords=points, node_R=[second_rotation, first_rotation])
    @test resolved_with_frames == resolved
    fallback = bar_offsets_and_endpoints(displacement_frames, first_point, second_point;
        id_map=ids, node_coords=points, node_R=[first_rotation, second_rotation])
    @test fallback[1] ≈ first_offset atol=2e-15
    @test fallback[2] ≈ second_offset atol=2e-15

    # O is constructed on GA--GB before either offset is applied. Unequal
    # end offsets make an incorrect offset-axis construction observable.
    original_axes = hcat(beam_section_axes(beam, first_point, second_point-first_point,
        ids, points; model)...)
    element_frames = deepcopy(beam)
    element_frames["OFFT"] = "BOO"
    element_frames["WA"] = original_axes' * first_offset
    element_frames["WB"] = original_axes' * second_offset
    resolved_element = bar_offsets_and_endpoints(element_frames, first_point, second_point; model)
    @test resolved_element[1] ≈ first_offset atol=2e-15
    @test resolved_element[2] ≈ second_offset atol=2e-15
    @test resolved_element[4] ≈ first_point+first_offset atol=2e-15
    @test resolved_element[5] ≈ second_point+second_offset atol=2e-15
    grid_orientation = merge(element_frames, Dict("G0"=>33))
    resolved_grid = bar_offsets_and_endpoints(grid_orientation, first_point, second_point; model)
    for index in (1,2,4,5)
        @test resolved_grid[index] ≈ resolved_element[index] atol=2e-15
    end

    # A rigid rotation of all geometry must rotate the physical offsets and
    # preserve the element length used by stiffness, mass and stress recovery.
    rigid_rotation = rotation(0.63)
    rotated_beam = deepcopy(element_frames)
    rotated_beam["V"] = rigid_rotation * orientation
    rotated = bar_offsets_and_endpoints(rotated_beam,
        SVector{3}(rigid_rotation*first_point), SVector{3}(rigid_rotation*second_point))
    @test rotated[1] ≈ rigid_rotation*first_offset atol=2e-15
    @test rotated[2] ≈ rigid_rotation*second_offset atol=2e-15
    @test norm(rotated[5]-rotated[4]) ≈ norm(expected[5]-expected[4])

    no_offsets = merge(beam, Dict("WA"=>zeros(3), "WB"=>zeros(3)))
    @test bar_offsets_and_endpoints(no_offsets, first_point, second_point) ==
        (SVector(0.0,0.0,0.0), SVector(0.0,0.0,0.0), false, first_point, second_point)
    @test_throws ArgumentError bar_offsets_and_endpoints(
        merge(beam, Dict("WA"=>[NaN,0.0,0.0])), first_point, second_point)
    @test_throws ArgumentError bar_offsets_and_endpoints(
        merge(beam, Dict("OFFT"=>"GXX")), first_point, second_point)
end
