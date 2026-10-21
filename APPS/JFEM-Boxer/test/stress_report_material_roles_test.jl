using Test, WingFEGen
const W = WingFEGen

@testset "Imported shell material identities for property reserve factors" begin
    shell=Dict{String,Any}("MID"=>8,"MID2"=>8,"MID3"=>0,"MID4"=>0,"T"=>.01)
    native=Dict{String,Any}("PSHELLs"=>Dict("101"=>shell),
        "MATs"=>Dict("8"=>Dict("E"=>70e9,"NU"=>.3,"RHO"=>2700.),
                    "9"=>Dict("E"=>200e9,"NU"=>.3,"RHO"=>7800.)))
    group=(kind=:quad,pid=101)
    property=W.imported_properties(native,group)
    @test property["material_ids"]==[8]
    @test property["material_roles"]==Dict("MID"=>8,"MID2"=>8)
    @test property["material_id"]==8
    @test property["material"]["type"]=="MAT1"

    shell["MID2"]=9;shell["MID3"]=8;shell["MID4"]=9
    mixed=W.imported_properties(native,group)
    @test mixed["material_ids"]==[8,9]
    @test mixed["material_roles"]==Dict("MID"=>8,"MID2"=>9,"MID3"=>8,"MID4"=>9)
    @test mixed["material_id"]==8
    @test mixed["areal_mass_kg_m2"]==property["areal_mass_kg_m2"]
    @test property["material_ids"]==[8] # snapshots are independent

    shell["MID2"]=-1;delete!(shell,"MID3");delete!(shell,"MID4")
    sentinel=W.imported_properties(native,group)
    @test sentinel["material_ids"]==[8]
    @test sentinel["material_roles"]==Dict("MID"=>8)
end
