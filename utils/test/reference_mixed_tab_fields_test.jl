using Test
module MixedTabFixture
include(joinpath(@__DIR__,"..","..","src","parsing","utilities.jl"))
include(joinpath(@__DIR__,"..","..","src","parsing","card_processor.jl"))
include(joinpath(@__DIR__,"..","..","src","parsing","extract_constraints.jl"))
end
const MT=MixedTabFixture

@testset "Mixed fixed-field runs separated by tabs" begin
    first_line=rpad("RBE3",8)*lpad("101",8)*"        "*lpad("10",8)*lpad("123456",8)*lpad("0.5",8)*"\t"*lpad("2",8)*lpad("20",8)*lpad("30",8)
    continuation="        "*lpad("40",8)*lpad("50",8)*lpad("1.",8)*lpad("1",8)*lpad("20",8)*lpad("30",8)*lpad("40",8)*lpad("50",8)
    fixed=replace(first_line,"\t"=>"")
    mixed_cards=MT.process_cards([first_line,continuation])
    fixed_cards=MT.process_cards([fixed,continuation])
    @test mixed_cards==fixed_cards
    rbe=MT.extract_rbe3(mixed_cards["RBE3"])["101"]
    @test rbe["REFGRID"]==10
    @test rbe["REFC"]==123456
    @test rbe["WT_GROUPS"][1]==(wt=.5,comps=2,grids=[20,30,40,50])
    @test rbe["WT_GROUPS"][2]==(wt=1,comps=1,grids=[20,30,40,50])
    # Empty tab fields are positional; long single numeric tokens remain whole.
    fields=MT.get_reference_fields_from_line("GRID\t1\t\t0.\t0.\t0.")
    @test fields[1:5]==["1","","0.","0.","0."]
    @test MT.get_reference_fields_from_line("MAT1\t1\t1234567890123.")[2]=="1234567890123."
    run=lpad("123456789",16)*"                "*lpad("1.234e-12",16)
    large=MT.get_reference_fields_from_line("GRID*\t"*run;large_field=true)
    @test large[1:3]==["123456789","","1.234e-12"]
    # Commas continue to define free format even when surrounding whitespace has tabs.
    @test MT.get_reference_fields_from_line("GRID,1,\t,0.,0.,0.")[1:5]==["1","","0.","0.","0."]
end
