using Test, Pkg, TOML, UUIDs, SHA
include(joinpath(@__DIR__,"..","julia_tools","environment_setup.jl"))
include(joinpath(@__DIR__,"..","julia_tools","runtime_images.jl"))
const PreparedEnvironment = JFEMEnvironmentSetup
const PreparedImages = JFEMRuntimeImages

function prepared_toml(file,data)
    mkpath(dirname(file))
    open(file,"w") do io;TOML.print(io,data);end
end

@testset "Prepared package metadata, cached trees and separate solver source" begin
    oldproject=Base.active_project();oldload=copy(LOAD_PATH);olddepots=copy(DEPOT_PATH)
    oldloadenv=get(ENV,"JULIA_LOAD_PATH",nothing)
    try
        mktempdir() do work
            repo=joinpath(work,"solver source");prepared=joinpath(work,"prepared environment")
            depot=joinpath(work,"existing depot");mkpath(depot);pushfirst!(DEPOT_PATH,depot)
            sourceuuid=uuid4();cacheuuid=uuid4();auxuuid=uuid4();appuuid=uuid4()
            cachehash=repeat("1",40);auxhash=repeat("2",40);otherhash=repeat("3",40)
            paths=String[]
            for (name,uuid,hash,code,deps) in [
                ("JFEMCachedFixture",cacheuuid,cachehash,"using JFEMAuxFixture\nanswer()=JFEMAuxFixture.answer()+1",Dict("JFEMAuxFixture"=>string(auxuuid))),
                ("JFEMAuxFixture",auxuuid,auxhash,"answer()=41",Dict{String,String}())]
                root=joinpath(depot,"packages",name,Base.version_slug(uuid,Base.SHA1(hash)))
                prepared_toml(joinpath(root,"Project.toml"),Dict("name"=>name,"uuid"=>string(uuid),"version"=>"1.0.0","deps"=>deps))
                mkpath(joinpath(root,"src"));write(joinpath(root,"src",name*".jl"),"__precompile__(false)\nmodule $name\n$code\nend\n")
                append!(paths,[joinpath(root,"Project.toml"),joinpath(root,"src",name*".jl")])
            end
            project=Dict("name"=>"JFEMPreparedSourceFixture","uuid"=>string(sourceuuid),"version"=>"0.1.0",
                "deps"=>Dict("JFEMCachedFixture"=>string(cacheuuid),"JFEMBundledAppFixture"=>string(appuuid)),
                "sources"=>Dict("JFEMBundledAppFixture"=>Dict("path"=>"APPS/JFEMBundledAppFixture")))
            prepared_toml(joinpath(repo,"Project.toml"),project)
            app=joinpath(repo,"APPS","JFEMBundledAppFixture")
            prepared_toml(joinpath(app,"Project.toml"),Dict("name"=>"JFEMBundledAppFixture","uuid"=>string(appuuid),
                "version"=>"0.1.0","deps"=>Dict("JFEMCachedFixture"=>string(cacheuuid))))
            mkpath(joinpath(app,"src"));write(joinpath(app,"src","JFEMBundledAppFixture.jl"),
                "__precompile__(false)\nmodule JFEMBundledAppFixture\nusing JFEMCachedFixture\nanswer()=JFEMCachedFixture.answer()\nend\n")
            append!(paths,[joinpath(app,"Project.toml"),joinpath(app,"src","JFEMBundledAppFixture.jl")])
            mkpath(joinpath(repo,"src"));write(joinpath(repo,"src","JFEMPreparedSourceFixture.jl"),
                "__precompile__(false)\nmodule JFEMPreparedSourceFixture\nusing JFEMCachedFixture\nanswer()=JFEMCachedFixture.answer()\nend\n")
            prepared_toml(joinpath(prepared,"Project.toml"),Dict("deps"=>Dict("JFEMCachedFixture"=>string(cacheuuid))))
            function manifest(hash,version)
                Dict("julia_version"=>string(VERSION),"manifest_format"=>"2.0","deps"=>Dict(
                    "JFEMCachedFixture"=>[Dict("uuid"=>string(cacheuuid),"version"=>version,"git-tree-sha1"=>hash,"deps"=>["JFEMAuxFixture"])],
                    "JFEMAuxFixture"=>[Dict("uuid"=>string(auxuuid),"version"=>"1.0.0","git-tree-sha1"=>auxhash)]))
            end
            repomanifest=manifest(otherhash,"2.0.0")
            repomanifest["deps"]["JFEMBundledAppFixture"]=[Dict("uuid"=>string(appuuid),"version"=>"0.1.0",
                "path"=>"APPS/JFEMBundledAppFixture","deps"=>["JFEMCachedFixture"])]
            prepared_toml(joinpath(repo,"Manifest.toml"),repomanifest)
            prepared_toml(joinpath(prepared,"Manifest.toml"),manifest(cachehash,"1.0.0"))
            append!(paths,[joinpath(p,n) for p in (repo,prepared) for n in ("Project.toml","Manifest.toml")])
            before=Dict(file=>bytes2hex(sha256(read(file))) for file in paths)
            withenv("JFEM_PACKAGE_ENV"=>nothing,"JFEM_AUTO_INSTALL"=>"0") do
                @test PreparedEnvironment.package_environment(repo)==(repo,false)
                @test_throws ErrorException PreparedEnvironment.ensure_environment(repo;io=devnull)
            end
            withenv("JFEM_PACKAGE_ENV"=>prepared,"JFEM_AUTO_INSTALL"=>"1","JFEM_NO_SYSIMAGE"=>nothing) do
                @test PreparedEnvironment.package_environment(repo)==(prepared,true)
                @test !PreparedEnvironment.ensure_environment(repo;io=devnull)
                @test Base.active_project()==joinpath(prepared,"Project.toml")
                @test LOAD_PATH==[prepared,repo,"@stdlib"]
                @test ENV["JULIA_LOAD_PATH"]==join(LOAD_PATH,Sys.iswindows() ? ';' : ':')
                @test isempty(PreparedEnvironment.missing_sources())
                @test occursin(Base.version_slug(cacheuuid,Base.SHA1(cachehash)),Base.find_package("JFEMCachedFixture"))
                @test Base.find_package("JFEMPreparedSourceFixture")==joinpath(repo,"src","JFEMPreparedSourceFixture.jl")
                loaded=Base.require(Main,:JFEMPreparedSourceFixture)
                @test Base.invokelatest(()->loaded.answer())==42
                @test Base.find_package("JFEMBundledAppFixture")==joinpath(app,"src","JFEMBundledAppFixture.jl")
                localapp=Base.require(Main,:JFEMBundledAppFixture)
                @test Base.invokelatest(()->localapp.answer())==42
                @test PreparedImages.selected_image(repo)==(nothing,"external_package_environment")
                # Exercise the normal two-process launcher with the same
                # mismatched source manifest and intact prepared dependency.
                probe=joinpath(work,"launch probe.jl")
                checker=joinpath(@__DIR__,"..","julia_tools","environment_setup.jl")
                write(probe,"include("*repr(checker)*")\n"*
                    "JFEMEnvironmentSetup.ensure_environment(ARGS[1])\n"*
                    "using JFEMPreparedSourceFixture\n"*
                    "println(\"PREPARED_LAUNCH_OK=\",JFEMPreparedSourceFixture.answer())\n")
                launcher=joinpath(@__DIR__,"..","julia_tools","launch.jl")
                # DEPOT_PATH changes in this fixture must reach the child too.
                withenv("JULIA_DEPOT_PATH"=>join(DEPOT_PATH,Sys.iswindows() ? ';' : ':')) do
                    diagnostics=IOBuffer()
                    output=read(pipeline(`$(PreparedImages.bare_julia()) --startup-file=no --threads=1 $launcher solver $repo $probe $repo`;
                        stderr=diagnostics),String)
                    @test occursin("PREPARED_LAUNCH_OK=42",output)
                    @test !occursin("run setup",String(take!(diagnostics)))
                end
            end
            @test all(bytes2hex(sha256(read(file)))==hash for (file,hash) in before)
            withenv("JFEM_PACKAGE_ENV"=>joinpath(prepared,"Project.toml")) do
                @test PreparedEnvironment.package_environment(repo)==(prepared,true)
            end
            bad=joinpath(work,"unavailable prepared sources")
            prepared_toml(joinpath(bad,"Project.toml"),Dict("deps"=>Dict("JFEMCachedFixture"=>string(cacheuuid))))
            prepared_toml(joinpath(bad,"Manifest.toml"),manifest(otherhash,"2.0.0"))
            withenv("JFEM_PACKAGE_ENV"=>bad,"JFEM_AUTO_INSTALL"=>"1") do
                failure=try PreparedEnvironment.ensure_environment(repo;io=devnull);nothing catch e;e end
                @test failure isa ErrorException
                @test occursin("nothing was installed, resolved or updated",sprint(showerror,failure))
                @test !isdir(joinpath(depot,"packages","JFEMCachedFixture",Base.version_slug(cacheuuid,Base.SHA1(otherhash))))
            end
            withenv("JFEM_PACKAGE_ENV"=>joinpath(work,"absent")) do
                @test_throws ErrorException PreparedEnvironment.package_environment(repo)
            end
            withenv("JFEM_PACKAGE_ENV"=>repo,"JFEM_NO_SYSIMAGE"=>nothing) do
                @test PreparedImages.selected_image(repo)==(nothing,"image_missing")
            end
            @test all(bytes2hex(sha256(read(file)))==hash for (file,hash) in before)
        end
    finally
        empty!(LOAD_PATH);append!(LOAD_PATH,oldload)
        empty!(DEPOT_PATH);append!(DEPOT_PATH,olddepots)
        oldloadenv===nothing ? pop!(ENV,"JULIA_LOAD_PATH",nothing) : (ENV["JULIA_LOAD_PATH"]=oldloadenv)
        oldproject===nothing ? Pkg.activate(;io=devnull) : Pkg.activate(dirname(oldproject);io=devnull)
    end
end
