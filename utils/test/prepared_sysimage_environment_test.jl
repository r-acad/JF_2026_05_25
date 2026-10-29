using Test, Pkg, TOML, UUIDs, SHA, Artifacts
include(joinpath(@__DIR__,"..","julia_tools","prepared_sysimage_environment.jl"))
const PreparedBuild=JFEMPreparedSysimageEnvironment

function build_fixture_toml(path,data)
    mkpath(dirname(path))
    open(path,"w") do io;TOML.print(io,data;sorted=true);end
end

@testset "Offline prepared sysimage build environment" begin
    oldproject=Base.active_project();oldload=copy(LOAD_PATH);olddepot=copy(DEPOT_PATH)
    oldoffline=Pkg.OFFLINE_MODE[]
    changed=("JULIA_PKG_OFFLINE","JULIA_PKG_SERVER","JULIA_PKG_PRECOMPILE_AUTO","JFEM_AUTO_INSTALL","JULIA_LOAD_PATH")
    oldenv=Dict(key=>get(ENV,key,nothing) for key in changed)
    try
        mktempdir() do work
            repo=joinpath(work,"source tree");app=joinpath(repo,"APPS","JFEM-Boxer")
            prepared=joinpath(work,"prepared metadata");depot=joinpath(work,"cached depot")
            mkpath(depot);empty!(DEPOT_PATH);push!(DEPOT_PATH,depot)
            rootuuid=uuid4();appuuid=uuid4();cacheuuid=uuid4();cachedhash=repeat("1",40)
            cache=joinpath(depot,"packages","CachedBuildFixture",Base.version_slug(cacheuuid,Base.SHA1(cachedhash)))
            build_fixture_toml(joinpath(cache,"Project.toml"),Dict("name"=>"CachedBuildFixture","uuid"=>string(cacheuuid),"version"=>"1.2.3"))
            mkpath(joinpath(cache,"src"));write(joinpath(cache,"src","CachedBuildFixture.jl"),"module CachedBuildFixture\nanswer()=42\nend\n")
            rootproject=Dict("name"=>"LocalSourceFixture","uuid"=>string(rootuuid),"version"=>"0.1.0",
                "deps"=>Dict("CachedBuildFixture"=>string(cacheuuid),"Dates"=>"ade2ca70-3891-5945-98fb-dc099432e06a","LocalAppFixture"=>string(appuuid)),
                "compat"=>Dict("CachedBuildFixture"=>"1.2","julia"=>"1.13"))
            build_fixture_toml(joinpath(repo,"Project.toml"),rootproject)
            appproject=Dict("name"=>"LocalAppFixture","uuid"=>string(appuuid),"version"=>"0.1.0","deps"=>Dict("CachedBuildFixture"=>string(cacheuuid)))
            build_fixture_toml(joinpath(app,"Project.toml"),appproject)
            for (path,name) in ((repo,"LocalSourceFixture"),(app,"LocalAppFixture"))
                mkpath(joinpath(path,"src"));write(joinpath(path,"src",name*".jl"),"module $name\nend\n")
            end
            project=Dict("deps"=>Dict("CachedBuildFixture"=>string(cacheuuid)))
            build_fixture_toml(joinpath(prepared,"Project.toml"),project)
            manifest=Dict("manifest_format"=>"2.0","julia_version"=>string(VERSION),"deps"=>Dict(
                "CachedBuildFixture"=>[Dict("uuid"=>string(cacheuuid),"version"=>"1.2.3","git-tree-sha1"=>cachedhash)]))
            build_fixture_toml(joinpath(prepared,"Manifest.toml"),manifest)
            paths=[joinpath(repo,"Project.toml"),joinpath(app,"Project.toml"),joinpath(prepared,"Project.toml"),joinpath(prepared,"Manifest.toml")]
            originals=Dict(path=>bytes2hex(sha256(read(path))) for path in paths)
            prefs=Dict("CachedBuildFixture"=>Dict("choice"=>"existing","nested"=>Dict("x"=>1)))
            dest=PreparedBuild.prepare_environment(repo,prepared,joinpath(work,"derived");preferences=prefs,preference_packages=Dict("CachedBuildFixture"=>string(cacheuuid)))
            @test isfile(joinpath(dest,"Project.toml"))
            @test isfile(joinpath(dest,"Manifest.toml"))
            derived=TOML.parsefile(joinpath(dest,"Manifest.toml"))
            @test only(derived["deps"]["CachedBuildFixture"])==only(manifest["deps"]["CachedBuildFixture"])
            @test only(derived["deps"]["LocalSourceFixture"])["path"]==abspath(repo)
            @test only(derived["deps"]["LocalAppFixture"])["path"]==abspath(app)
            @test haskey(derived["deps"],"Dates") && haskey(derived["deps"],"Printf") && haskey(derived["deps"],"Unicode")
            @test TOML.parsefile(joinpath(dest,"LocalPreferences.toml"))==prefs
            @test all(bytes2hex(sha256(read(path)))==hash for (path,hash) in originals)
            @test_throws ErrorException PreparedBuild.prepare_environment(repo,prepared,repo)
            @test_throws ErrorException PreparedBuild.prepare_environment(repo,prepared,prepared)
            @test_throws ErrorException PreparedBuild.prepare_environment(repo,prepared,dest)
            stats=PreparedBuild.cache_preflight(dest;io=devnull)
            @test stats["packages"]>=6 && stats["artifacts"]==0
            @test LOAD_PATH==[dest,"@stdlib"] && Base.active_project()==joinpath(dest,"Project.toml")
            @test Pkg.OFFLINE_MODE[] && ENV["JULIA_PKG_OFFLINE"]=="true" && ENV["JULIA_PKG_SERVER"]==""
            @test !isdir(joinpath(depot,"registries"))
            @test Base.get_preferences(cacheuuid)==prefs["CachedBuildFixture"]
            @test Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(joinpath(dest,"Project.toml")))
            # Exercise PackageCompiler's internal instantiate path against a fully
            # cached graph and an empty registry depot: it must return unchanged.
            derived_before=Dict(name=>read(joinpath(dest,name)) for name in ("Project.toml","Manifest.toml","LocalPreferences.toml"))
            Pkg.instantiate(;allow_autoprecomp=false,io=devnull)
            @test !isdir(joinpath(depot,"registries"))
            @test all(read(joinpath(dest,name))==bytes for (name,bytes) in derived_before)
            @test all(bytes2hex(sha256(read(path)))==hash for (path,hash) in originals)
            # Distinct absent second artifact must not be missed even if the first
            # installed artifact causes Pkg's own shortcut check to return true.
            hash=Pkg.Artifacts.create_artifact() do directory
                write(joinpath(directory,"content.txt"),"already cached")
            end
            absent=repeat("2",40)
            artifactfile=joinpath(cache,"Artifacts.toml")
            build_fixture_toml(artifactfile,Dict(
                "present"=>Dict("git-tree-sha1"=>string(hash),"download"=>[Dict("url"=>"https://must-not-download.invalid/present","sha256"=>repeat("0",64))]),
                "missing_second"=>Dict("git-tree-sha1"=>absent,"download"=>[Dict("url"=>"https://must-not-download.invalid/missing","sha256"=>repeat("0",64))])))
            failure=try PreparedBuild.cache_preflight(dest;io=devnull);nothing catch e;e end
            @test failure isa ErrorException
            @test occursin("missing_second",sprint(showerror,failure))
            @test !isdir(joinpath(depot,"artifacts",absent))
            build_fixture_toml(artifactfile,Dict("lazy_missing"=>Dict("git-tree-sha1"=>absent,"lazy"=>true,"download"=>[Dict("url"=>"https://must-not-download.invalid/lazy","sha256"=>repeat("0",64))])))
            failure=try PreparedBuild.cache_preflight(dest;io=devnull);nothing catch e;e end
            @test failure isa ErrorException && occursin("lazy_missing",sprint(showerror,failure))
            build_fixture_toml(artifactfile,Dict("local_only"=>Dict("git-tree-sha1"=>absent)))
            failure=try PreparedBuild.cache_preflight(dest;io=devnull);nothing catch e;e end
            @test failure isa ErrorException && occursin("local_only",sprint(showerror,failure))
            # A UUID/name override maps the recorded hash to an existing local
            # artifact directory and must be honored without any download.
            build_fixture_toml(joinpath(depot,"artifacts","Overrides.toml"),Dict(string(cacheuuid)=>Dict("local_only"=>Artifacts.artifact_path(hash))))
            @test PreparedBuild.cache_preflight(dest;io=devnull)["artifacts"]==1
            # Alter only a derived manifest to request an unavailable source tree.
            broken=deepcopy(derived);only(broken["deps"]["CachedBuildFixture"])["git-tree-sha1"]=repeat("3",40)
            bad=joinpath(work,"missing source");build_fixture_toml(joinpath(bad,"Project.toml"),TOML.parsefile(joinpath(dest,"Project.toml")));build_fixture_toml(joinpath(bad,"Manifest.toml"),broken)
            failure=try PreparedBuild.cache_preflight(bad;io=devnull);nothing catch e;e end
            @test failure isa ErrorException && occursin("package CachedBuildFixture",sprint(showerror,failure))
            # Julia's version-specific manifest is authoritative when present.
            versioned=joinpath(prepared,"Manifest-v$(VERSION.major).$(VERSION.minor).toml")
            adjusted=deepcopy(manifest);only(adjusted["deps"]["CachedBuildFixture"])["path"]=relpath(cache,prepared)
            build_fixture_toml(versioned,adjusted)
            selected=PreparedBuild.prepare_environment(repo,prepared,joinpath(work,"selected versioned"))
            selectedrecord=only(TOML.parsefile(joinpath(selected,"Manifest.toml"))["deps"]["CachedBuildFixture"])
            @test selectedrecord["path"]==abspath(cache)
            @test selectedrecord["version"]=="1.2.3" && selectedrecord["git-tree-sha1"]==cachedhash
            # Source contract failures are diagnosed before writing build metadata.
            incompatible=deepcopy(rootproject);incompatible["compat"]["CachedBuildFixture"]="2"
            build_fixture_toml(joinpath(repo,"Project.toml"),incompatible)
            failure=try PreparedBuild.prepare_environment(repo,prepared,joinpath(work,"incompatible"));nothing catch e;e end
            @test failure isa ErrorException && occursin("requires CachedBuildFixture",sprint(showerror,failure))
            @test !isdir(joinpath(work,"incompatible"))
            build_fixture_toml(joinpath(repo,"Project.toml"),rootproject)
            missingdep=deepcopy(rootproject);missingdep["deps"]["UnavailablePackage"]=string(uuid4())
            build_fixture_toml(joinpath(repo,"Project.toml"),missingdep)
            failure=try PreparedBuild.prepare_environment(repo,prepared,joinpath(work,"missing dependency"));nothing catch e;e end
            @test failure isa ErrorException && occursin("Prepared manifest lacks UnavailablePackage",sprint(showerror,failure))
        end
    finally
        empty!(LOAD_PATH);append!(LOAD_PATH,oldload);empty!(DEPOT_PATH);append!(DEPOT_PATH,olddepot)
        Pkg.offline(oldoffline)
        for (key,value) in oldenv
            value===nothing ? pop!(ENV,key,nothing) : (ENV[key]=value)
        end
        oldproject===nothing ? Pkg.activate(;io=devnull) : Pkg.activate(dirname(oldproject);io=devnull)
        Artifacts.load_overrides(;force=true)
    end
end
