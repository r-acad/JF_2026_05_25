using Test, Pkg, TOML, SHA, PackageCompiler
include(joinpath(@__DIR__,"..","julia_tools","prepared_sysimage_environment.jl"))
include(joinpath(@__DIR__,"..","julia_tools","shared_precompile_workloads.jl"))
const BuildEnvironment=JFEMPreparedSysimageEnvironment
const SharedImage=JFEMSharedPrecompileWorkloads

function write_contract_toml(path,data)
    mkpath(dirname(path));open(io->TOML.print(io,data;sorted=true),path,"w")
end

@testset "Prepared dependency-only projects satisfy the real shared image contract" begin
    repo=normpath(joinpath(@__DIR__,"..",".."))
    sourceproject=TOML.parsefile(joinpath(repo,"Project.toml"))
    sourcemanifest=TOML.parsefile(joinpath(repo,"Manifest.toml"))
    # A hydrated deployment may list only external packages and Statistics.
    # Pkg is cached through dependencies, but is not a direct project entry.
    names=["AlgebraicMultigrid","CodecZlib","ForwardDiff","HDF5","HTTP",
        "IterativeSolvers","JSON","KrylovKit","MsgPack","NPZ","PackageCompiler",
        "PrecompileTools","StaticArrays","Statistics","VortexLattice","WriteVTK","YAML"]
    mktempdir() do work
        prepared=joinpath(work,"prepared records")
        project=Dict("deps"=>Dict(name=>sourceproject["deps"][name] for name in names))
        manifest=deepcopy(sourcemanifest)
        pop!(manifest["deps"],"OpenJFEM",nothing);pop!(manifest["deps"],"WingFEGen",nothing)
        write_contract_toml(joinpath(prepared,"Project.toml"),project)
        write_contract_toml(joinpath(prepared,"Manifest.toml"),manifest)
        originals=Dict(path=>bytes2hex(sha256(read(path))) for path in
            [joinpath(dir,name) for dir in (repo,prepared) for name in ("Project.toml","Manifest.toml")])
        @test !haskey(project["deps"],"Pkg")
        @test haskey(manifest["deps"],"Pkg")
        derived=BuildEnvironment.prepare_environment(repo,prepared,joinpath(work,"derived"))
        context=PackageCompiler.create_pkg_context(derived)
        requested=SharedImage.required_packages()
        @test :Pkg in requested
        @test all(haskey(context.env.project.deps,String(name)) for name in requested)
        # Call PackageCompiler's actual eligibility check, not a mock of it.
        @test isnothing(PackageCompiler.check_packages_in_project(context,requested))
        @test context.env.project.deps["Pkg"]==Base.PkgId(Pkg).uuid
        resultmanifest=TOML.parsefile(joinpath(derived,"Manifest.toml"))
        @test all(resultmanifest["deps"][name]==entries for (name,entries) in manifest["deps"])
        @test all(bytes2hex(sha256(read(path)))==hash for (path,hash) in originals)
        # Reproduce the reported failure with only the direct Pkg entry removed.
        incomplete=joinpath(work,"previous direct-dependency layout")
        broken=TOML.parsefile(joinpath(derived,"Project.toml"));pop!(broken["deps"],"Pkg",nothing)
        write_contract_toml(joinpath(incomplete,"Project.toml"),broken)
        write_contract_toml(joinpath(incomplete,"Manifest.toml"),resultmanifest)
        oldcontext=PackageCompiler.create_pkg_context(incomplete)
        failure=try PackageCompiler.check_packages_in_project(oldcontext,requested);nothing catch e;e end
        @test failure isa ErrorException
        @test occursin("package(s) Pkg not in project",sprint(showerror,failure))
    end
end
