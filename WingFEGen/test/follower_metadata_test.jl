using Test, LinearAlgebra, StaticArrays
const solver_source=let base=normpath(joinpath(@__DIR__,"..",".."))
    candidates=[joinpath(base,"src","solver","follower_loads.jl"),
        joinpath(base,"01_PUBLIC_PROJECT_REPOSITORY","JFEM","src","solver","follower_loads.jl")]
    source=findfirst(isfile,candidates)
    isnothing(source) && error("Cannot locate the sibling JFEM solver source")
    candidates[source]
end
include(solver_source)

@testset "Follower display metadata separates its reference contribution" begin
    # A rotated GRID frame confirms vectors are emitted in BASIC, not CD.
    frame=@SMatrix [0. -1. 0.;1. 0. 0.;0. 0. 1.]
    station=(gid=42,force=SVector(4.,0.,8.),frame=frame,
        rotations=[[(4,1.)],[(5,1.)],[(6,1.)]])
    context=(stations=[station],);u=[0.,0.,0.,0.,pi/2,0.]
    for linear in (false,true)
        result=_follower_result_metadata(context,u,.25;linearized=linear)
        row=only(result["forces"])
        @test row["reference_force_basic"]≈[0.,1.,2.]
        @test row["rotation_basic"]≈[-pi/2,0.,0.]
        expected=linear ? frame*(.25station.force+cross(SVector(0.,pi/2,0.),.25station.force)) : [0.,2.,-1.]
        @test row["force_basic"]≈expected atol=1e-14
        @test result["load_scale"]==.25
    end
end
