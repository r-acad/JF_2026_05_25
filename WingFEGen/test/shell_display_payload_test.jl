using Test
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

@testset "Imported property thickness display bounds retain laminate Z0" begin
    native=Dict{String,Any}("MATs"=>Dict("1"=>Dict("E"=>71e9,"NU"=>.3,"RHO"=>2700.)),
        "PSHELLs"=>Dict{String,Any}("11"=>Dict("T"=>.02,"MID"=>1),
        "12"=>Dict("T"=>.03,"PCOMP_Z0"=>.007,"PLY_DATA"=>[
            Dict("mid"=>1,"z_bot"=>.007,"z_top"=>.017,"theta"=>0.),
            Dict("mid"=>1,"z_bot"=>.017,"z_top"=>.037,"theta"=>90.)])))
    original=deepcopy(native)
    shell=W.imported_properties(native,W.ElemGroup("IMPORTED_QUAD_P11",:quad,11))
    @test shell["z_bottom_m"]==-.01
    @test shell["z_top_m"]==.01
    composite=W.imported_properties(native,W.ElemGroup("IMPORTED_QUAD_P12",:quad,12))
    @test composite["z_bottom_m"]==.007
    @test composite["z_top_m"]≈.037
    @test composite["thickness_m"]==.03
    @test native==original
    delete!(native["PSHELLs"]["12"],"PCOMP_Z0")
    fallback=W.imported_properties(native,W.ElemGroup("IMPORTED_QUAD_P12",:quad,12))
    @test fallback["z_bottom_m"]==.007
    @test fallback["z_top_m"]≈.037
end
