using Test
module ShellResultRotationFixture
using Test
# The tensor transport is independent of model construction and the web server.
struct Model end
struct ElemGroup end
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","shell_frames.jl"))
function checks()
    for field in ("stress","strain"),angle in (.37,pi/2,1.2)
        original=Dict("normal_x"=>2.,"normal_y"=>7.,"shear_xy"=>3.)
        typed=Dict("z1"=>copy(original),"z2"=>copy(original))
        flexible=Dict{String,Any}("z1"=>copy(original),"z2"=>copy(original))
        rotate_shell_results!(typed,field,cos(angle),sin(angle))
        rotate_shell_results!(flexible,field,cos(angle),sin(angle))
        @test typed==flexible
        @test typed["z1"]!=original
        @test typed["z1"]["normal_x"]+typed["z1"]["normal_y"]≈9.
        if angle==pi/2
            @test typed["z1"]["normal_x"]≈7.
            @test typed["z1"]["normal_y"]≈2.
            @test typed["z1"]["shear_xy"]≈-3.
        end
    end
end
end
@testset "Shell tensor rotation stores typed parent faces after conversion" begin
    ShellResultRotationFixture.checks()
end
