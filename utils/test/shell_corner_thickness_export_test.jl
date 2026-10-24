module ShellCornerThicknessExportTests
using Test,OpenJFEM,HDF5,JSON

@testset "Corner shell section survives result export" begin
    absolute=Dict{String,Any}("ID"=>1,"PID"=>1,"TYPE"=>"CQUAD4","NODES"=>[1,2,3,4],
        "THETA"=>23.,"ZOFFS"=>.02,"TFLAG"=>0,"CORNER_THICKNESSES_SPECIFIED"=>true,
        "CORNER_THICKNESSES"=>Union{Nothing,Float64}[.002,nothing,.004,.005])
    fractional=Dict{String,Any}("ID"=>2,"PID"=>1,"TYPE"=>"CTRIA3","NODES"=>[1,2,3],
        "ZOFFS"=>-.04,"TFLAG"=>1,"CORNER_THICKNESSES_SPECIFIED"=>true,
        "CORNER_THICKNESSES"=>Union{Nothing,Float64}[.5,nothing,2.])
    ordinary=Dict{String,Any}("ID"=>3,"PID"=>1,"TYPE"=>"CQUAD4","NODES"=>[1,2,3,4])
    model=Dict{String,Any}("CSHELLs"=>Dict("1"=>absolute,"2"=>fractional,"3"=>ordinary),
        "PSHELLs"=>Dict("1"=>Dict("PID"=>1,"MID"=>1,"T"=>.003)),
        "PBARLs"=>Dict(),"PRODs"=>Dict(),"CBARs"=>Dict(),"CRODs"=>Dict())
    original=deepcopy(model)
    q,t=OpenJFEM._reference_input_shell_records(model)
    @test first(q).T==(.002,.003,.004,.005)
    @test first(q).TFLAG==0 && first(q).ZOFFS==.02
    @test last(q).T==(.003,.003,.003,.003)
    @test first(t).T==(.5,1.,2.)
    @test first(t).TFLAG==1 && first(t).ZOFFS==-.04
    @test OpenJFEM._shell_export_mean_thickness(absolute,model["PSHELLs"]["1"])≈.0035
    @test OpenJFEM._shell_export_mean_thickness(fractional,model["PSHELLs"]["1"])≈.0035
    tables=OpenJFEM.build_jfem_element_tables(model,Dict(i=>i for i in 1:4))
    @test first(tables[2])[4]==Float32(.0035)
    @test first(tables[3])[4]==Float32(.0035)
    @test last(tables[2])[4]==Float32(.003)
    mktempdir() do dir
        path=joinpath(dir,"sections.jfem")
        h5open(path,"w") do file
            OpenJFEM._reference_write_input_tables(file,model)
        end
        h5open(path,"r") do file
            quads=read(file["/REFERENCE/INPUT/ELEMENT/CQUAD4"])
            trias=read(file["/REFERENCE/INPUT/ELEMENT/CTRIA3"])
            @test first(quads).T==collect(first(q).T)
            @test first(quads).ZOFFS==.02
            @test first(trias).T==collect(first(t).T)
            @test first(trias).TFLAG==1
            @test first(trias).ZOFFS==-.04
            raw=JSON.parse(read(file["/JFEM/INPUT/SHELL_CORNER_THICKNESS_JSON"],String))
            @test length(raw)==2
            @test raw[1]["RAW_CORNER_THICKNESSES"]==absolute["CORNER_THICKNESSES"]
            @test raw[2]["RAW_CORNER_THICKNESSES"]==fractional["CORNER_THICKNESSES"]
            @test raw[2]["TFLAG"]==1
        end
    end
    @test model==original
end
end
