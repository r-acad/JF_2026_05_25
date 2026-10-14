using Test,TOML
include(joinpath(@__DIR__,"..","__Start here!__","julia_tools","runtime_images.jl"))
const RuntimeImages=JFEMRuntimeImages
const ImageReceipt=RuntimeImages.JFEMSysimageProvenance

module CanonicalBoxerBootstrap
include(joinpath(@__DIR__,"..","APPS","JFEM-Boxer","src","runtime_bootstrap.jl"))
end
@testset "Boxer bootstrap keeps the enclosing repository" begin
    bootstrap=CanonicalBoxerBootstrap.WingFEGenBootstrap
    mktempdir() do temp
        root=joinpath(temp,"canonical !");foreign=joinpath(temp,"foreign")
        for path in (root,foreign)
            mkpath(joinpath(path,"src"));write(joinpath(path,"src","OpenJFEM.jl"),"# fixture")
        end
        app=joinpath(root,"APPS","JFEM-Boxer");mkpath(app)
        write(joinpath(root,"Manifest.toml"),"julia_version = \"$(VERSION)\"\n")
        write(joinpath(foreign,"Manifest.toml"),"julia_version = \"1.0.0\"\n")
        @test bootstrap.locate_solver(app;hint="")==root
        @test bootstrap.locate_solver(app;hint=foreign)==root
        @test bootstrap.locate_solver(app;hint=joinpath(temp,"missing"))==root
        withenv("WINGFEGEN_JFEM"=>foreign) do
            @test bootstrap.locate_solver(app)==root
            @test bootstrap.requirements(app)==(VERSION.major,VERSION.minor)
        end
    end
end

@testset "Runtime images reject source, environment and identity drift" begin
    mktempdir() do temp
        root=joinpath(temp,"Checkout with spaces ! (fixture)")
        mkpath(joinpath(root,"src"));write(joinpath(root,"src","OpenJFEM.jl"),"# solver fixture")
        write(joinpath(root,"Project.toml"),"[deps]\n")
        app=joinpath(root,"APPS","JFEM-Boxer");mkpath(joinpath(app,"src"))
        write(joinpath(app,"Project.toml"),"[deps]\n")
        write(joinpath(root,"Manifest.toml"),"julia_version = \"$(VERSION)\"\n")
        source=joinpath(app,"src","WingFEGen.jl");write(source,"# app fixture")
        image=RuntimeImages.image_path(root,"boxer");mkpath(dirname(image))
        write(image,"receipt fixture only; never loaded")
        workload=ImageReceipt.workload_hashes(String[],"fixture")
        capture()=ImageReceipt.write_sidecar(root,image,ImageReceipt.input_hashes(root;kind="boxer"),workload;kind="boxer")
        capture()
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (true,"current")
        @test ImageReceipt.check_sysimage(joinpath(root,"."),image;kind="boxer")== (true,"current")
        @test ImageReceipt.check_sysimage(root,image)==(true,"current")
        @test RuntimeImages.image_path(root,"solver")==image
        legacy=TOML.parsefile(ImageReceipt.sidecar(image));legacy["schema"]=2
        open(io->TOML.print(io,legacy),ImageReceipt.sidecar(image),"w")
        @test RuntimeImages.selected_image(root;kind="boxer")== (nothing,"schema_mismatch")
        capture()
        @test RuntimeImages.selected_image(root;kind="boxer")== (image,"current")
        write(joinpath(root,"src","OpenJFEM.jl"),"# changed shared solver code")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"project_changed")
        capture()
        withenv("JFEM_NO_SYSIMAGE"=>"1") do
            @test RuntimeImages.selected_image(root;kind="boxer")== (nothing,"disabled")
        end
        write(source,"# edited app source")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"project_changed")
        capture();write(joinpath(root,"Manifest.toml"),"julia_version = \"1.0.0\"\n")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"project_changed")
        capture();write(joinpath(app,"src","new.jl"),"# new code")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"project_changed")
        capture();write(image,"modified image")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"image_changed")
        capture();data=TOML.parsefile(ImageReceipt.sidecar(image));data["runtime"]["julia_version"]="0.0.0"
        open(io->TOML.print(io,data),ImageReceipt.sidecar(image),"w")
        @test ImageReceipt.check_sysimage(root,image;kind="boxer")== (false,"runtime_changed")
        @test RuntimeImages.image_arguments(nothing)==String[]
        @test RuntimeImages.image_arguments(image)==["--sysimage="*image]
    end
end

@testset "Windows launcher preserves spaces and literal exclamation marks" begin
    if Sys.iswindows()
        repo=normpath(joinpath(@__DIR__,".."))
        mktempdir() do temp
            root=joinpath(temp,"Checkout with spaces ! (fixture)");mkpath(root)
            target=joinpath(root,"__Start here!__","julia_tools");mkpath(target)
            for file in ("runtime_images.jl","sysimage_provenance.jl","launch.jl")
                cp(joinpath(repo,"__Start here!__","julia_tools",file),joinpath(target,file))
            end
            cp(joinpath(repo,"jfem.cmd"),joinpath(root,"jfem.cmd"))
            write(joinpath(target,"jfem.jl"),"println(\"CAPTURE:\",join(ARGS,\"|\"));exit(7)\n")
            deck=joinpath(root,"model ! with spaces.bdf")
            script=joinpath(root,"jfem.cmd")
            body="\"\""*script*"\" \""*deck*"\"\""
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",body]);windows_verbatim=true)
            io=IOBuffer()
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"JFEM_NO_SYSIMAGE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("CAPTURE:"*deck,String(take!(io)))
            cp(joinpath(repo,"JFEM-solver.cmd"),joinpath(root,"JFEM-solver.cmd"))
            oneclick=replace(body,"jfem.cmd"=>"JFEM-solver.cmd")
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",oneclick]);windows_verbatim=true)
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"JFEM_NO_SYSIMAGE"=>"1","OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("CAPTURE:"*deck,String(take!(io)))
            app=joinpath(root,"APPS","JFEM-Boxer");mkpath(app)
            cp(joinpath(repo,"JFEM-Boxer.cmd"),joinpath(root,"JFEM-Boxer.cmd"))
            write(joinpath(app,"JFEM-Boxer.jl"),"println(\"BOXER:\",join(ARGS,\"|\"));exit(7)\n")
            boxer=replace(body,"jfem.cmd"=>"JFEM-Boxer.cmd")
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",boxer]);windows_verbatim=true)
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"WINGFEGEN_JULIA"=>RuntimeImages.bare_julia(),"OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("BOXER:"*deck,String(take!(io)))
        end
    else
        @test true # The actual CMD launch is exercised on Windows.
    end
end
