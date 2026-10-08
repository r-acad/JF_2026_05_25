using Test,JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
function fake_repo(path)
    mkpath(joinpath(path,"src"));write(joinpath(path,"src","OpenJFEM.jl"),"# discovery fixture\n")
    write(joinpath(path,Sys.iswindows() ? "jfem.cmd" : "jfem"),"# discovery fixture\n")
    path
end
tests=@testset "Portable checkout discovery and defaults" begin
    mktempdir() do root
        repo=fake_repo(joinpath(root,"Arbitrary checkout name (test)"));app=joinpath(repo,"WingFEGen");mkpath(app)
        @test first(W.find_jfem(app;environment=Dict()))==repo
        @test W.WingFEGenBootstrap.locate_solver(app;hint="")==repo
        @test samefile(first(W.find_jfem(app;hint="..",environment=Dict())),repo)
        launcher=last(W.find_jfem(app;environment=Dict()))
        @test first(W.find_jfem(app;hint=launcher,environment=Dict()))==repo
        other=fake_repo(joinpath(root,"External solver"))
        @test first(W.find_jfem(app;environment=Dict("WINGFEGEN_JFEM"=>other)))==other
        @test first(W.find_jfem(app;hint=repo,environment=Dict("WINGFEGEN_JFEM"=>other)))==repo
        bad=joinpath(repo,"random.cmd");write(bad,"# not a solver launcher")
        @test_throws ArgumentError W.find_jfem(app;hint=bad,environment=Dict())
        p,unknown=W.normalize_params(Dict("jfem.path"=>".."))
        @test isempty(unknown)&&p["jfem.repo"]==".."
        @test_throws ArgumentError W.normalize_params(Dict("jfem.path"=>"a","jfem.repo"=>"b"))
        mkpath(joinpath(app,"examples"));write(joinpath(app,"examples","wing_default.toml"),"factory")
        path=W.ensure_default_input(app)
        @test path==joinpath(app,"input","wing_input.toml")&&read(path,String)=="factory"
        write(path,"user data");@test W.ensure_default_input(app)==path&&read(path,String)=="user data"
        @test read(joinpath(app,"examples","wing_default.toml"),String)=="factory"
        # Juliaup directory detection does not need JSON or package installation.
        depot=joinpath(root,"depot with spaces");version=joinpath(depot,"juliaup","julia-1.12.3-test","bin")
        mkpath(version);exe=joinpath(version,Sys.iswindows() ? "julia.exe" : "julia");write(exe,"")
        candidates=W.WingFEGenBootstrap.runtime_candidates(;current="unavailable",environment=Dict("JULIAUP_DEPOT_PATH"=>depot),user_home=root)
        @test exe in candidates
        @test W.sensitivity_runtime_compatible(v"1.12.3",Dict("generator"=>v"1.12.1"))
    end
    repo,launcher=W.find_jfem(dirname(@__DIR__))
    @test repo!==nothing&&isfile(launcher)
    @test isfile(joinpath(dirname(@__DIR__),"examples","wing_default.toml"))
    p=W.read_input(joinpath(dirname(@__DIR__),"examples","wing_default.toml"))
    @test p==W.default_params()
end
counts=Test.get_test_counts(tests)
if !isempty(ARGS)
    mkpath(only(ARGS));write(joinpath(only(ARGS),"paths_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
end
