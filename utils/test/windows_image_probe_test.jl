module WindowsImageProbeTests

using Test
include(joinpath(@__DIR__, "..", "julia_tools", "runtime_images.jl"))
const Images = JFEMRuntimeImages

@testset "Windows image candidates are loaded silently inside a bare Julia probe" begin
    if Sys.iswindows()
        mktempdir() do directory
            previous_mode = ccall((:GetErrorMode, "kernel32"), UInt32, ())
            system_image = unsafe_string(Base.JLOptions().image_file)
            @test Images.image_loadable(system_image)
            @test ccall((:GetErrorMode, "kernel32"), UInt32, ()) == previous_mode

            # A real Windows library must also have Julia's image data exports.
            library = joinpath(ENV["SystemRoot"], "System32", "kernel32.dll")
            @test !Images.image_loadable(library)
            @test ccall((:GetErrorMode, "kernel32"), UInt32, ()) == previous_mode

            # This file passes the simple native-header check. The production
            # child configures its error mode before loading the invalid DLL.
            image = joinpath(directory, "invalid image.dll")
            write(image, vcat(UInt8[0x4d, 0x5a], zeros(UInt8, 126)))
            child = Ref{Any}(nothing)
            observed = Ref{Any}(nothing)
            function capture(command)
                observed[] = command
                child[] = Images._start_image_probe(command)
            end
            started = time()
            @test !Images.image_loadable(image; timeout=5., runner=capture)
            @test child[] !== nothing
            @test process_exited(child[])
            @test child[].exitcode == 1
            @test child[].termsignal == 0
            @test time() - started < 10.
            @test last(observed[].exec) == image
            @test !any(startswith("--sysimage="), observed[].exec)
            @test ccall((:GetErrorMode, "kernel32"), UInt32, ()) == previous_mode
        end
    else
        @test true
    end
end

@testset "Windows launcher continues after a corrupt image passes its receipt check" begin
    if Sys.iswindows()
        mktempdir() do directory
            root = joinpath(directory, "checkout with spaces !")
            helpers = joinpath(root, "utils", "julia_tools")
            mkpath(helpers)
            mkpath(joinpath(root, "src"))
            for file in ("launch.jl", "runtime_images.jl", "sysimage_provenance.jl", "compilation_defaults.jl")
                cp(joinpath(@__DIR__, "..", "julia_tools", file), joinpath(helpers, file))
            end
            write(joinpath(root, "Project.toml"), "[deps]\n")
            write(joinpath(root, "Manifest.toml"), "julia_version = \"$(VERSION)\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(root, "src", "OpenJFEM.jl"), "# synthetic receipt input\n")
            image = Images.image_path(root)
            mkpath(dirname(image))
            write(image, vcat(UInt8[0x4d, 0x5a], zeros(UInt8, 126)))
            receipt = Images.JFEMSysimageProvenance
            receipt.write_sidecar(root, image, receipt.input_hashes(root), receipt.workload_hashes(String[], "fixture"))
            marker = joinpath(root, "target_count.txt")
            target = joinpath(root, "capture.jl")
            write(target, "open(" * repr(marker) * ", \"a\") do io\nprintln(io, \"once\")\nend\nexit(7)\n")
            command = `$(Images.bare_julia()) --startup-file=no --threads=1 $(joinpath(helpers, "launch.jl")) solver $root $target`
            command = Cmd(addenv(command, "JFEM_NO_SYSIMAGE" => nothing); windows_hide=true)
            output = IOBuffer()
            result = run(pipeline(ignorestatus(command); stdout=output, stderr=output))
            message = String(take!(output))
            @test result.exitcode == 7
            @test occursin("image_load_failed", message)
            @test occursin("normal Julia package loading", message)
            @test readlines(marker) == ["once"]
        end
    else
        @test true
    end
end

end
