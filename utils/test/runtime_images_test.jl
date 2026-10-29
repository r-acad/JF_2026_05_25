using Test,TOML
include(joinpath(@__DIR__,"..", "..","utils","julia_tools","runtime_images.jl"))
const RuntimeImages=JFEMRuntimeImages
const ImageReceipt=RuntimeImages.JFEMSysimageProvenance

module CanonicalBoxerBootstrap
include(joinpath(@__DIR__,"..", "..","APPS","JFEM-Boxer","src","runtime_bootstrap.jl"))
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

@testset "Prepared images follow locked metadata and effective preferences" begin
    mktempdir() do temp
        root=joinpath(temp,"source checkout");prepared=joinpath(temp,"prepared cache records")
        mkpath(joinpath(root,"src"));mkpath(prepared)
        write(joinpath(root,"src","OpenJFEM.jl"),"# receipt fixture; no image loading\n")
        uuid="f65a6b52-80e5-4277-8d25-cf0f3d5d7d40"
        project="[deps]\nFixturePkg = \"$uuid\"\n"
        write(joinpath(root,"Project.toml"),project*"[preferences.FixturePkg]\nfrom_source = 1\nchoice = \"source\"\n")
        write(joinpath(prepared,"Project.toml"),project*"[preferences.FixturePkg]\nfrom_prepared = 2\nchoice = \"exported\"\n")
        manifest=joinpath(prepared,"Manifest.toml")
        write(manifest,"julia_version = \"$(VERSION)\"\nmanifest_format = \"2.0\"\n")
        localprefs=joinpath(prepared,"LocalPreferences.toml")
        preftext="[FixturePkg]\nchoice = \"local\"\n[UndeclaredPackage]\nignored = true\n"
        write(localprefs,preftext)
        image=RuntimeImages.image_path(root);mkpath(dirname(image));write(image,"not a loadable image")
        workload=ImageReceipt.workload_hashes(String[],"fixture")
        identity()=ImageReceipt.environment_identity(root;environment=prepared)
        capture()=ImageReceipt.write_sidecar(root,image,ImageReceipt.input_hashes(root),workload;
            environment=prepared,environment_before=identity())
        baseline=identity()
        @test baseline["mode"]=="prepared"
        @test baseline["manifest"]["path"]==manifest
        @test baseline["preferences"]["FixturePkg"]==Dict("from_source"=>1,"from_prepared"=>2,"choice"=>"local")
        @test !haskey(baseline["preferences"],"UndeclaredPackage")
        @test baseline["preference_packages"]["FixturePkg"]==uuid
        oldload=copy(LOAD_PATH)
        try
            empty!(LOAD_PATH);append!(LOAD_PATH,[prepared,root,"@stdlib"])
            @test Base.get_preferences(Base.UUID(uuid))==baseline["preferences"]["FixturePkg"]
            empty!(LOAD_PATH);push!(LOAD_PATH,joinpath(temp,"temporary compilation project"))
            @test identity()==baseline
        finally
            empty!(LOAD_PATH);append!(LOAD_PATH,oldload)
        end
        helpers=joinpath(root,"utils","julia_tools");mkpath(helpers)
        for name in ("check_sysimage.jl","sysimage_provenance.jl")
            cp(joinpath(@__DIR__,"..","julia_tools",name),joinpath(helpers,name))
        end
        capture()
        @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(true,"current")
        @test ImageReceipt.check_sysimage(root,image;environment=joinpath(prepared,"Project.toml"))==(true,"current")
        withenv("JFEM_PACKAGE_ENV"=>prepared,"JFEM_NO_SYSIMAGE"=>nothing) do
            @test RuntimeImages.selected_image(root)==(image,"current")
        end
        @test RuntimeImages.selected_image(root;environment=prepared,external=true)==(image,"current")
        @test ImageReceipt.check_sysimage(root,image;environment=root)==(false,"package_environment_changed")
        # Matching contents in another directory do not silently select a
        # different deployment's image. Paths can be embedded by native code.
        copyenv=joinpath(temp,"another prepared deployment");cp(prepared,copyenv)
        @test ImageReceipt.check_sysimage(root,image;environment=copyenv)==(false,"package_environment_changed")
        open(io->write(io,"# metadata changed\n"),manifest,"a")
        @test RuntimeImages.selected_image(root;environment=prepared)==(nothing,"package_environment_changed")
        @test RuntimeImages.selected_image(root;environment=prepared,external=true)==(nothing,"receipt_not_current_for_worker")
        @test_throws ErrorException ImageReceipt.write_sidecar(root,image,ImageReceipt.input_hashes(root),workload;
            environment=prepared,environment_before=baseline)
        capture()
        write(localprefs,replace(preftext,"local"=>"changed"))
        @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
        capture()
        versioned=joinpath(prepared,"Manifest-v$(VERSION.major).$(VERSION.minor).toml")
        cp(manifest,versioned)
        @test identity()["manifest"]["path"]==versioned
        @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
        capture()
        # JuliaLocalPreferences takes priority over LocalPreferences.
        write(joinpath(prepared,"JuliaLocalPreferences.toml"),"[FixturePkg]\nchoice = \"preferred_file\"\n")
        @test identity()["preferences"]["FixturePkg"]["choice"]=="preferred_file"
        @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
        capture()
        write(joinpath(root,"LocalPreferences.toml"),"[FixturePkg]\nfrom_source = 3\n")
        @test identity()["preferences"]["FixturePkg"]["from_source"]==3
        @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"project_changed")
        capture()
        depot=joinpath(temp,"override depot");mkpath(joinpath(depot,"artifacts"))
        olddepots=copy(DEPOT_PATH)
        try
            pushfirst!(DEPOT_PATH,depot)
            @test identity()["artifact_overrides"]==baseline["artifact_overrides"]
            overrides=joinpath(depot,"artifacts","Overrides.toml")
            write(overrides,"# local native-library redirection\n")
            @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
            capture()
            @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(true,"current")
            write(overrides,"# modified native-library override\n")
            @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
            otherdepot=joinpath(temp,"other override depot");mkpath(joinpath(otherdepot,"artifacts"))
            write(joinpath(otherdepot,"artifacts","Overrides.toml"),"# another native-library redirection\n")
            pushfirst!(DEPOT_PATH,otherdepot)
            capture()
            expected=identity()
            DEPOT_PATH[1],DEPOT_PATH[2]=DEPOT_PATH[2],DEPOT_PATH[1]
            @test identity()["artifact_overrides"]==expected["artifact_overrides"]
            @test identity()["artifact_override_order"]!=expected["artifact_override_order"]
            @test ImageReceipt.check_sysimage(root,image;environment=prepared)==(false,"package_environment_changed")
        finally
            empty!(DEPOT_PATH);append!(DEPOT_PATH,olddepots)
        end
        @test_throws Exception ImageReceipt.environment_identity(root;environment=joinpath(temp,"absent"))
    end
end

@testset "Windows launcher preserves spaces and literal exclamation marks" begin
    if Sys.iswindows()
        repo=normpath(joinpath(@__DIR__,"..", ".."))
        mktempdir() do temp
            root=joinpath(temp,"Checkout with spaces ! (fixture)");mkpath(root)
            target=joinpath(root,"utils","julia_tools");mkpath(target)
            for file in ("runtime_images.jl","sysimage_provenance.jl","launch.jl")
                cp(joinpath(repo,"utils","julia_tools",file),joinpath(target,file))
            end
            solver=joinpath(root,"APPS","JFEM-solver","Windows");mkpath(solver)
            cp(joinpath(repo,"APPS","JFEM-solver","Windows","jfem.cmd"),joinpath(solver,"jfem.cmd"))
            write(joinpath(target,"jfem.jl"),"println(\"CAPTURE:\",join(ARGS,\"|\"));exit(7)\n")
            deck=joinpath(root,"model ! with spaces.bdf")
            script=joinpath(solver,"jfem.cmd")
            body="\"\""*script*"\" \""*deck*"\"\""
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",body]);windows_verbatim=true)
            io=IOBuffer()
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"JFEM_NO_SYSIMAGE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("CAPTURE:"*deck,String(take!(io)))
            cp(joinpath(repo,"APPS","JFEM-solver","Windows","JFEM-solver.cmd"),joinpath(solver,"JFEM-solver.cmd"))
            oneclick=replace(body,"jfem.cmd"=>"JFEM-solver.cmd")
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",oneclick]);windows_verbatim=true)
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"JFEM_NO_SYSIMAGE"=>"1","OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("CAPTURE:"*deck,String(take!(io)))
            app=joinpath(root,"APPS","JFEM-Boxer");mkpath(app)
            mkpath(joinpath(app,"Windows"))
            cp(joinpath(repo,"APPS","JFEM-Boxer","Windows","JFEM-Boxer.cmd"),joinpath(app,"Windows","JFEM-Boxer.cmd"))
            write(joinpath(app,"JFEM-Boxer.jl"),"println(\"BOXER:\",join(ARGS,\"|\"));exit(7)\n")
            boxer=replace(body,script=>joinpath(app,"Windows","JFEM-Boxer.cmd"))
            command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",boxer]);windows_verbatim=true)
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>RuntimeImages.bare_julia(),"WINGFEGEN_JULIA"=>RuntimeImages.bare_julia(),"OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("BOXER:"*deck,String(take!(io)))
        end
    else
        @test true # The actual CMD launch is exercised on Windows.
    end
end
