using Test, WingFEGen
const IR=WingFEGen

const ISOTROPIC_IMPORT="""
SOL 101
CEND
SUBCASE 1
 SPC = 8
 LOAD = 5
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.,1.,0.
GRID,4,,0.,1.,0.
CQUAD4,51,1,1,2,3,4
MAT1,1,7.0E10,,0.3,2700.
PSHELL,1,1,0.01
FORCE,5,3,0,20.,0.,0.,-1.
SPC1,8,123456,1,2
ENDDATA
"""
const COMPOSITE_IMPORT=replace(ISOTROPIC_IMPORT,
    "MAT1,1,7.0E10,,0.3,2700.\nPSHELL,1,1,0.01"=>
    "MAT8,1,135000000000,10000000000,0.3,5000000000,5000000000,5000000000,1600.\nPCOMP,1,-0.001,0.,,,,,\n+,1,0.001,0.,YES,1,0.001,90.,YES")
const ABAQUS_IMPORT="""
*NODE
11,0,0,0
12,1,0,0
13,0,1,0
14,0,0,1
*ELEMENT,TYPE=C3D4,ELSET=BODY
51,11,12,13,14
"""

function importer_regression_wait(path,process,log;seconds=180.)
    deadline=time()+seconds
    while !isfile(path)&&process_running(process)&&time()<deadline;sleep(.05);end
    isfile(path)||error("Owned import worker did not produce $(basename(path)): "*(isfile(log) ? read(log,String) : "no log"))
end

@testset "Standalone native reader and reused service import without analysis" begin
    repo=normpath(joinpath(@__DIR__,"../../.."));app=dirname(@__DIR__)
    mktempdir() do root
        script=joinpath(app,"src/reference_import_worker.jl")
        julia=Cmd([joinpath(Sys.BINDIR,Base.julia_exename())])
        function capture(name,text;format="reference")
            directory=joinpath(root,name);mkpath(directory)
            source=IR.imported_source(Dict("name"=>name*(format=="abaqus" ? ".inp" : ".bdf"),"text"=>text,"format"=>format))
            IR.Serialization.serialize(joinpath(directory,"input.jls"),(source,IR.default_params()))
            return directory,source
        end
        function payload(directory,source)
            @test !isfile(joinpath(directory,"error.json"))
            isfile(joinpath(directory,"error.json"))&&error(read(joinpath(directory,"error.json"),String))
            data=IR.MsgPack.unpack(read(joinpath(directory,"payload.msgpack")))
            @test data["model_source"]["text"]==source["text"]
            @test data["model_source"]["format"]==source["format"]
            @test isfile(joinpath(directory,"native.jls"))
            @test isfile(joinpath(directory,"model.jls"))
            return data
        end
        one,source=capture("isotropic",ISOTROPIC_IMPORT)
        command=`$julia --startup-file=no --compiled-modules=existing -O1 --threads=1 --project=$repo $script $one $repo $app`
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        log=joinpath(one,"worker.log")
        process=open(log,"w") do output
            run(pipeline(ignorestatus(command);stdout=output,stderr=output);wait=false)
        end
        try
            importer_regression_wait(joinpath(one,"done.txt"),process,log)
            wait(process);@test success(process)
            data=payload(one,source)
            @test data["nodes"]["count"]==4
            @test data["loads"]["force_stations"][1]["force"]==[0.,0.,-20.]
            @test data["spc"]["count"]==2
            runtime=IR.JSON.parsefile(joinpath(one,"runtime.json"))
            @test "ForwardDiff" in runtime["loaded_packages"]
            @test isempty(intersect(Set(runtime["loaded_packages"]),Set(["OpenJFEM","HTTP","VortexLattice","HDF5","KrylovKit"])))
        finally
            process_running(process)&&kill(process);wait(process)
        end
        queue=joinpath(root,"service");mkpath(queue)
        command=`$julia --startup-file=no --compiled-modules=existing -O1 --threads=1 --project=$repo $script --serve $queue $repo $app`
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        log=joinpath(queue,"worker.log")
        process=open(log,"w") do output
            run(pipeline(ignorestatus(command);stdout=output,stderr=output);wait=false)
        end
        try
            importer_regression_wait(joinpath(queue,"ready.txt"),process,log)
            pid=getpid(process)
            for (name,text,format) in (("composite",COMPOSITE_IMPORT,"reference"),("tetrahedron",ABAQUS_IMPORT,"abaqus"))
                directory,source=capture(name,text;format)
                write(joinpath(queue,"request.tmp"),directory)
                mv(joinpath(queue,"request.tmp"),joinpath(queue,"request.txt");force=true)
                importer_regression_wait(joinpath(directory,"done.txt"),process,log)
                @test process_running(process)
                @test getpid(process)==pid
                data=payload(directory,source)
                @test data["nodes"]["count"]==4
                if format=="reference"
                    native=IR.Serialization.deserialize(joinpath(directory,"native.jls"))
                    @test native["PSHELLs"]["1"]["TYPE"]=="PCOMP_CLT"
                    @test native["MATs"]["1"]["E1"]==135000000000.
                    @test length(native["PSHELLs"]["1"]["PLY_DATA"])==2
                    @test all(isfinite,native["PSHELLs"]["1"]["Cm"])
                    @test data["loads"]["force_stations"][1]["force"]==[0.,0.,-20.]
                else
                    @test data["solid_boundary"]["triangles"]["count"]==4
                    @test !data["imported_deck"]["analysis_ready"]
                end
            end
            runtime=IR.JSON.parsefile(joinpath(queue,"runtime.json"))
            @test runtime["runtime"]=="import-only"
            @test "ForwardDiff" in runtime["loaded_packages"]
            @test isempty(intersect(Set(runtime["loaded_packages"]),Set(["OpenJFEM","HTTP","VortexLattice","HDF5","KrylovKit"])))
        finally
            process_running(process)&&kill(process);wait(process)
        end
    end
end
