using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
solver_repo,_=W.find_jfem(dirname(@__DIR__))
include(joinpath(solver_repo,"src","parsing","ReferenceParser.jl"))
const N=ReferenceParser

@testset "Portable 16-column Reference output" begin
    for value in (0.0,-0.0,Float64(pi),-Float64(pi),1e-200,1e200,71e9,1.234567890123456,-1.234567890123456e-40)
        field=W.nas_large_field(value)
        @test length(field)==16
        @test parse(Float64,strip(field))≈value rtol=5e-10 atol=0
        @test occursin('.',field)||occursin('E',field)
    end
    @test_throws ArgumentError W.nas_large_field(Inf)
    @test_throws ArgumentError W.nas_large_field(NaN)
    @test_throws ArgumentError W.nas_large_field("x"^17)
    buffer=IOBuffer();W.card!(IOContext(buffer,:large_field=>true),"CBAR",
        (1,2,3,4,0.123456789012345,-0.23456789012345,0.3456789012345,"GGG",
         nothing,nothing,0.010123456789,-0.020123456789,0.030123456789,
         0.010123456789,-0.020123456789,0.030123456789))
    lines=split(chomp(String(take!(buffer))),'\n')
    @test length(lines)==4
    @test all(length(line)==72 for line in lines)
    @test startswith(lines[1],"CBAR*")
    @test all(startswith(line,"*") for line in lines[2:end])
    fields=[line[9+16i:24+16i] for line in lines for i in 0:3]
    @test parse(Float64,fields[16])≈0.030123456789 rtol=1e-12

    # The exact free-field path used by sensitivities is deliberately unchanged.
    buffer=IOBuffer();W.card!(IOContext(buffer,:full_precision=>true),"GRID",(1,nothing,Float64(pi),0.0,0.0))
    @test String(take!(buffer))=="GRID,1,,$(Float64(pi)),0.0,0.0\n"

    mktempdir() do folder
        file=joinpath(folder,"large.bdf")
        open(file,"w") do io
            println(io,"SOL 101\nCEND\nSUBCASE 1\n  SPC = 1\n  LOAD = 1\nBEGIN BULK")
            large=IOContext(io,:large_field=>true)
            W.card!(large,"GRID",(1,nothing,0.0,0.0,0.0))
            W.card!(large,"GRID",(2,nothing,1.23456789012345,0.0,0.0))
            W.card!(large,"MAT1",(1,71e9,nothing,0.33,2780.0))
            W.card!(large,"PBAR",(1,1,0.001,1e-7,2e-7,3e-7))
            W.card!(large,"CBAR",(1,1,1,2,0.0,0.0,1.0,"GGG",nothing,nothing,
                0.0,0.01,0.0,0.0,0.01,0.0))
            W.card!(large,"SPC1",(1,"123456",1))
            W.card!(large,"FORCE",(1,2,0,3.14,0.0,0.0,1.0))
            println(io,"ENDDATA")
        end
        _,bulk=N.read_bulk_and_case(readlines(file));parsed=N.process_cards(bulk)
        @test length(parsed["GRID"])==2
        bars=N.extract_cbar(parsed["CBAR"])
        @test length(bars)==1
        @test only(values(bars))["WB"]≈[0.0,0.01,0.0] rtol=1e-12
    end

    @testset "Generated bars use portable default OFFT" begin
        params=W.default_params()
        merge!(params,Dict("box.rib_pitch"=>3.0,"box.stringer_pitch"=>0.5,
            "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
            "properties.rib_stiffeners_enabled"=>false,"output.solution"=>"101"))
        model=W.build_model(params)
        mktempdir() do folder
            for large in (false,true)
                path=joinpath(folder,"bars_$(large).bdf")
                W.write_reference(model,path;large_field=large)
                _,bulk=N.read_bulk_and_case(readlines(path));cards=N.process_cards(bulk)
                @test all(isempty(strip(string(N.safe_get(c,10,"")))) for c in cards["CBAR"])
                bars=N.extract_cbar(cards["CBAR"])
                @test any(any(!iszero,bar["WA"]) for bar in values(bars))
                @test all(node["CD"]==0 for node in values(N.extract_grid(cards["GRID"])))
            end
            model.params["output.solution"]="105"
            path=joinpath(folder,"buckling.bdf")
            W.write_reference(model,path;large_field=true)
            case_control=first(split(read(path,String),"BEGIN BULK"))
            subcases=split(case_control,r"(?m)^SUBCASE \d+\n")[2:end]
            @test length(subcases)==2
            @test all(occursin(r"(?m)^  SPC = 1$",subcase) for subcase in subcases)
            @test occursin("  STATSUB = 1",last(subcases))
        end
    end
end
