using Test
include(joinpath(@__DIR__,"..","src","reference_folder_import.jl"))

function folder_test_write(root,path,text)
    target=joinpath(root,path);mkpath(dirname(target));write(target,text);target
end

@testset "Recursive fragments, INCLUDE union and exact entity deduplication" begin
    mktempdir() do dir
        folder_test_write(dir,"master.bdf","SOL 101\nCEND\nSUBCASE 1\n LOAD = 7\nBEGIN BULK\nINCLUDE 'parts/grids.inc'\nMAT1,1,7.E10,,.3,2700.\nPSHELL,2,1,.002\nENDDATA\n")
        folder_test_write(dir,"parts/grids.inc","GRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,0.,1.,0.\n")
        folder_test_write(dir,"parts/skin.dat","CTRIA3,10,2,1,2,3\nFORCE,7,2,0,10.,0.,0.,1.\n")
        folder_test_write(dir,"duplicate_grid.nas","GRID,1,,0.0,0E0,0.\n")
        folder_test_write(dir,"ignore.f06","solver output")
        folder_test_write(dir,"abaqus.inp","*HEADING\n*NODE\n1,0.,0.,0.\n")
        scan=reference_folder_scan(dir)
        @test length(scan["files"])==4
        @test scan["primary_candidates"]==["master.bdf"]
        @test !scan["primary_required"]
        @test length(scan["fingerprint"])==64
        @test !isempty(scan["warnings"])
        source=reference_folder_source(dir;expected_scan=scan["scan_id"])
        @test source["source_file_count"]==4
        @test source["summary"]["deduplicated_cards"]==1
        @test count(line->startswith(line,"GRID,1,"),split(source["text"],'\n'))==1
        @test occursin("SOL 101\nCEND\nSUBCASE 1\n LOAD = 7",source["text"])
        @test !occursin("INCLUDE '",source["text"])
        @test count(==("BEGIN BULK"),split(source["text"],'\n'))==1
        @test count(==("ENDDATA"),split(source["text"],'\n'))==1
        @test occursin("Folder fragment: parts/skin.dat",source["text"])
        @test read(joinpath(dir,"master.bdf"),String)=="SOL 101\nCEND\nSUBCASE 1\n LOAD = 7\nBEGIN BULK\nINCLUDE 'parts/grids.inc'\nMAT1,1,7.E10,,.3,2700.\nPSHELL,2,1,.002\nENDDATA\n"
    end
end

@testset "Conflicting entity namespaces are explicit and transactional" begin
    for (firstcard,secondcard,label) in (
        ("GRID,1,,0.,0.,0.","GRID,1,,2.,0.,0.","GRID"),
        ("CTRIA3,10,2,1,2,3","CBAR,10,3,1,2,0.,1.,0.","element"),
        ("PSHELL,2,1,.002","PBAR,2,1,.003,1.,1.,1.","property"),
        ("MAT1,1,7.E10,,.3","MAT8,1,1.E10,1.E9,.2,1.E8","material"),
        ("CORD2R,9,0,0.,0.,0.,0.,0.,1.,1.,0.,0.","CORD2C,9,0,0.,0.,0.,0.,0.,1.,1.,0.,0.","coordinate"))
        mktempdir() do dir
            folder_test_write(dir,"first.bdf",firstcard*"\n")
            folder_test_write(dir,"nested/second.bdf",secondcard*"\n")
            error=try reference_folder_source(dir);nothing catch e;e end
            @test error isa ArgumentError
            @test occursin(label,sprint(showerror,error))
            @test occursin("first.bdf:1",sprint(showerror,error))
            @test occursin("nested/second.bdf:1",sprint(showerror,error))
            @test occursin("Deselect",sprint(showerror,error))
            one=reference_folder_source(dir;selected_files=["first.bdf"])
            @test one["summary"]["files"]==1
        end
    end
end

@testset "Load multiplicity and companion material cards" begin
    mktempdir() do dir
        folder_test_write(dir,"a.bdf","GRID,1,,0.,0.,0.\nMAT1,1,7.E10,,.3\nMATS1,1,,PLASTIC,1.,1,1,300.E6\nMATT1,1,10\nCREEP,1,0.,1.E-9\nFORCE,7,1,0,10.,0.,0.,1.\nFORCE,7,1,0,10.,0.,0.,1.\n")
        folder_test_write(dir,"b.bdf","FORCE,7,1,0,10.,0.,0.,1.\nFORCE,7,1,0,20.,0.,0.,1.\nSPC,3,1,123,0.\nSPC,3,1,123,0.\n")
        source=reference_folder_source(dir)
        @test count(line->startswith(line,"FORCE,"),split(source["text"],'\n'))==4
        @test count(line->startswith(line,"SPC,"),split(source["text"],'\n'))==2
        @test occursin("MAT1,1",source["text"])
        @test occursin("MATS1,1",source["text"])
        @test occursin("CREEP,1",source["text"])
        @test any(w->occursin("Both were retained",w),source["summary"]["warnings"])
    end
end

@testset "Reviewed primary header, stale scans and selected dependency closure" begin
    mktempdir() do dir
        folder_test_write(dir,"a.bdf","SOL 101\nCEND\nBEGIN BULK\nGRID,1,,0.,0.,0.\nENDDATA\n")
        folder_test_write(dir,"b.bdf","SOL 103\nCEND\nMETHOD = 8\nBEGIN BULK\nGRID,2,,1.,0.,0.\nENDDATA\n")
        scan=reference_folder_scan(dir)
        @test scan["primary_required"]
        @test_throws ArgumentError reference_folder_source(dir)
        source=reference_folder_source(dir;primary_file="b.bdf")
        @test occursin("SOL 103\nCEND\nMETHOD = 8",source["text"])
        @test !occursin("SOL 101",source["text"])
        @test occursin("GRID,1,",source["text"])&&occursin("GRID,2,",source["text"])
        @test !isempty(source["summary"]["warnings"])
        folder_test_write(dir,"new.inc","GRID,3,,2.,0.,0.\n")
        @test_throws ArgumentError reference_folder_source(dir;primary="b.bdf",expected_scan=scan["fingerprint"])
        @test_throws ArgumentError reference_folder_source(dir;selected_files=["../outside.bdf"])
    end
    mktempdir() do dir
        folder_test_write(dir,"a.bdf","SOL 101\nCEND\nBEGIN BULK\nGRID,1,,0.,0.,0.\nENDDATA")
        folder_test_write(dir,"b.bdf","SOL 101\nCEND\nBEGIN BULK\nGRID,2,,1.,0.,0.\nENDDATA")
        @test !reference_folder_scan(dir)["primary_required"]
        @test occursin("SOL 101",reference_folder_source(dir)["text"])
    end
    mktempdir() do dir
        folder_test_write(dir,"main.bdf","INCLUDE 'unknown/grids.txt'\n")
        folder_test_write(dir,"unknown/grids.txt","GRID,1,,0.,0.,0.\n")
        @test length(reference_folder_scan(dir)["files"])==2
        @test occursin("GRID,1",reference_folder_source(dir)["text"])
        @test_throws ArgumentError reference_folder_source(dir;selected_files=["main.bdf"])
    end
end

@testset "Compressed, fixed-field, large-field and content-filtered inputs" begin
    mktempdir() do dir
        compressed=joinpath(dir,"grid.bdf.gz")
        open(compressed,"w") do io
            stream=CodecZlib.GzipCompressorStream(io)
            write(stream,"GRID,1,,0.,0.,0.\n");close(stream)
        end
        fixed=rpad("GRID",8)*rpad("2",8)*rpad("",8)*rpad("1.",8)*rpad("0.",8)*rpad("0.",8)
        folder_test_write(dir,"grid.inp",fixed*"\n")
        folder_test_write(dir,"other.inp","this is not a model")
        folder_test_write(dir,"large.nas",rpad("GRID*",8)*rpad("3",16)*rpad("",16)*rpad("2.",16)*rpad("0.",16)*"\n"*rpad("*",8)*rpad("0.",16)*"\n")
        scan=reference_folder_scan(dir)
        @test length(scan["files"])==3
        source=reference_folder_source(dir)
        @test occursin("GRID,1,",source["text"])
        @test occursin("GRID*",source["text"])
        @test occursin("GRID    2",source["text"])
    end
end

@testset "Outside INCLUDE, malformed sources and symbolic-link boundaries" begin
    mktempdir() do root
        dir=joinpath(root,"model");mkpath(dir)
        folder_test_write(root,"outside.inc","GRID,1,,0.,0.,0.\n")
        folder_test_write(dir,"main.bdf","INCLUDE '../outside.inc'\n")
        @test_throws ArgumentError reference_folder_scan(dir)
        write(joinpath(dir,"main.bdf"),"INCLUDE 'missing.inc'\n")
        @test_throws ArgumentError reference_folder_scan(dir)
        write(joinpath(dir,"main.bdf"),"SOL 101\nCEND\nGRID,1,,0.,0.,0.\n")
        @test_throws ArgumentError reference_folder_source(dir)
        write(joinpath(dir,"main.bdf"),"+,1,2,3\n")
        @test_throws ArgumentError reference_folder_source(dir)
        write(joinpath(dir,"main.bdf"),"GRID,1,,0.,0.,0.\n")
        if !Sys.iswindows()
            symlink(joinpath(root,"outside.inc"),joinpath(dir,"escaped.inc"))
            scan=reference_folder_scan(dir)
            @test length(scan["files"])==1
            @test any(w->occursin("outside",w),scan["warnings"])
        end
    end
end

@testset "Explicit loose-fragment recovery never reads unresolved outside files" begin
    mktempdir() do root
        dir=joinpath(root,"model");mkpath(dir)
        folder_test_write(root,"outside.inc","GRID,999,,999.,999.,999.\n")
        folder_test_write(dir,"main.bdf","INCLUDE '../outside.inc'\nINCLUDE 'lost.inc'\nINCLUDE 'unterminated\nGRID,1,,0.,0.,0.\n")
        @test_throws ArgumentError reference_folder_scan(dir)
        scan=reference_folder_scan(dir;ignore_unresolved_includes=true)
        @test length(scan["files"])==1
        @test length(scan["warnings"])==3
        source=reference_folder_source(dir;ignore_unresolved_includes=true,expected_scan=scan["scan_id"])
        @test occursin("GRID,1,",source["text"])
        @test !occursin("GRID,999,",source["text"])
        @test source["summary"]["ignore_unresolved_includes"]
        @test occursin("Collection warning: Ignored unresolved INCLUDE",source["text"])
        folder_test_write(dir,"main.bdf","INCLUDE 'nested/\n geometry.txt'\nGRID,1,,0.,0.,0.\n")
        folder_test_write(dir,"nested/geometry.txt","GRID,2,,1.,0.,0.\n")
        @test length(reference_folder_scan(dir;ignore_unresolved_includes=true)["files"])==2
        @test occursin("GRID,2,",reference_folder_source(dir;ignore_unresolved_includes=true)["text"])
    end
end
