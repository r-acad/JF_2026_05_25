module SysimagePublicationTests

using Test, Libdl
include(joinpath(@__DIR__, "..", "julia_tools", "deploy_fast.jl"))

@testset "A late-loaded image compiler resolves its entry point in the latest world" begin
    function load_fixture(_)
        Core.eval(@__MODULE__, :(module LateImageCompilerFixture
            function create_sysimage(packages; sysimage_path, precompile_execution_file)
                (packages=packages, image=sysimage_path, script=precompile_execution_file,
                 threads=ENV["JULIA_NUM_THREADS"])
            end
        end))
    end
    previous = get(ENV, "JULIA_NUM_THREADS", nothing)
    result = _compile_shared_sysimage([:Fixture], "candidate", "workload", false;
        compiler_loader=load_fixture)
    @test result.packages == [:Fixture]
    @test result.image == "candidate"
    @test result.script == "workload"
    @test result.threads == string(Threads.nthreads())
    @test get(ENV, "JULIA_NUM_THREADS", nothing) == previous
end

@testset "Ordinary image compilation stages failures before replacing the current pair" begin
    mktempdir() do directory
        destination = joinpath(directory, "shared image." * Libdl.dlext)
        receipt = destination * ".jfem.toml"
        write(destination, "previous image fixture")
        write(receipt, "previous receipt fixture")
        root = normpath(joinpath(@__DIR__, "..", ".."))
        deck = joinpath(root, "utils", "examples", "precompile", "sol101_quad_static.bdf")
        captured = Dict{String,String}()
        function incomplete_compiler(packages, candidate, script, install)
            @test candidate != destination
            @test dirname(dirname(candidate)) == joinpath(directory, "builds")
            @test isfile(script)
            @test read(destination, String) == "previous image fixture"
            @test read(receipt, String) == "previous receipt fixture"
            captured["candidate"] = candidate
            write(candidate, "incomplete build fixture")
            throw(OutOfMemoryError())
        end
        # Metadata-only fixtures never enter an operating-system DLL loader.
        forbidden_probe = (path; project=nothing) -> error("Failed compilation must not probe or publish")
        @test_throws OutOfMemoryError _maybe_build_sysimage(destination, [deck], "", false;
            compiler=incomplete_compiler, library_probe=forbidden_probe)
        @test read(destination, String) == "previous image fixture"
        @test read(receipt, String) == "previous receipt fixture"
        @test read(captured["candidate"], String) == "incomplete build fixture"
        @test isfile(joinpath(dirname(captured["candidate"]), "failure.txt"))

        function completed_fixture(packages, candidate, script, install)
            @test candidate != destination
            @test read(destination, String) == "previous image fixture"
            write(candidate, "complete metadata fixture, never loaded")
        end
        @test_throws ErrorException _maybe_build_sysimage(destination, [deck], "", false;
            compiler=completed_fixture, library_probe=(path; project=nothing)->false)
        @test read(destination, String) == "previous image fixture"
        @test read(receipt, String) == "previous receipt fixture"

        probes = Ref(0)
        function metadata_fixture_probe(path; project=nothing)
            @test project == root
            @test read(path, String) == "complete metadata fixture, never loaded"
            probes[] += 1
            true
        end
        result = _maybe_build_sysimage(destination, [deck], "", false;
            compiler=completed_fixture, library_probe=metadata_fixture_probe)
        @test result == destination
        @test probes[] == 1
        @test read(destination, String) == "complete metadata fixture, never loaded"
        @test JFEMSysimageProvenance.check_sysimage(root, destination) == (true, "current")

        @test _maybe_build_sysimage("", [deck], "", false;
            compiler=(args...)->error("No image was requested"), library_probe=forbidden_probe) === nothing
    end
end

@testset "Windows in-use image preserves its previous matching receipt" begin
    if Sys.iswindows()
        mktempdir() do directory
            candidate = joinpath(directory, "candidate", "image.dll")
            destination = joinpath(directory, "published", "image.dll")
            mkpath(dirname(candidate))
            mkpath(dirname(destination))
            write(candidate, "new image fixture")
            write(candidate * ".jfem.toml", "new receipt fixture")
            write(destination, "old image fixture")
            write(destination * ".jfem.toml", "old receipt fixture")
            # A read handle without FILE_SHARE_DELETE reproduces an in-use DLL
            # rename failure. No fixture is passed to a native library loader.
            wide_path = transcode(UInt16, destination * "\0")
            handle = ccall((:CreateFileW, "kernel32"), Ptr{Cvoid},
                (Ptr{UInt16}, UInt32, UInt32, Ptr{Cvoid}, UInt32, UInt32, Ptr{Cvoid}),
                wide_path, 0x80000000, 0x00000001, C_NULL, 3, 0x80, C_NULL)
            @test handle != Ptr{Cvoid}(typemax(UInt))
            try
                @test_throws Base.IOError JFEMSysimagePublication.publish_image(candidate, destination)
                @test read(destination, String) == "old image fixture"
                @test read(destination * ".jfem.toml", String) == "old receipt fixture"
            finally
                ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), handle)
            end
            @test JFEMSysimagePublication.publish_image(candidate, destination) == destination
            @test read(destination, String) == "new image fixture"
            @test read(destination * ".jfem.toml", String) == "new receipt fixture"
        end
    else
        @test true
    end
end

end
