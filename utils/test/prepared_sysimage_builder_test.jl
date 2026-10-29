using Test, Libdl
include(joinpath(@__DIR__,"..","julia_tools","prepared_sysimage_builder.jl"))
const Builder=JFEMPreparedSysimageBuilder

@testset "Prepared image command and failed publication preserve working files" begin
    mktempdir() do root
        default=Builder.options(String[],root)
        @test default.image==joinpath(root,"sysimage","OpenJFEM_sysimage."*Libdl.dlext)
        @test !default.check_only
        @test Builder.options(["--check-only"],root).check_only
        @test Builder.options(["--help"],root).help
        @test Builder.options(["--deck","deck with spaces.bdf","--manifest=batch.json","--flags","KEY=value"],root).workload==
            ["--deck","deck with spaces.bdf","--manifest=batch.json","--flags","KEY=value"]
        @test_throws ErrorException Builder.options(["--install-packagecompiler"],root)
        @test_throws ErrorException Builder.options(["--deck"],root)
        @test_throws ErrorException Builder.options(["--sysimage="],root)
        @test_throws ErrorException Builder.options(["--sysimage="*root],root)
        @test_throws ErrorException Builder.options(["--sysimage=test.invalid"],root)
        candidate=joinpath(root,"candidate", "candidate."*Libdl.dlext)
        destination=joinpath(root,"published", "image."*Libdl.dlext)
        mkpath(dirname(candidate));mkpath(dirname(destination))
        write(candidate,"new image fixture");write(candidate*".jfem.toml","new receipt fixture")
        write(destination,"old image fixture");write(destination*".jfem.toml","old receipt fixture")
        @test_throws ErrorException Builder.publish_image(candidate,destination;validator=()->error("invalid receipt"))
        @test read(destination,String)=="old image fixture"
        @test read(destination*".jfem.toml",String)=="old receipt fixture"
        @test isfile(candidate)
        @test Builder.publish_image(candidate,destination)==destination
        @test read(destination,String)=="new image fixture"
        @test read(destination*".jfem.toml",String)=="new receipt fixture"
        empty_destination=joinpath(root,"new destination", "image."*Libdl.dlext)
        @test_throws ErrorException Builder.publish_image(candidate,empty_destination;validator=()->error("failed"))
        @test !isfile(empty_destination)
        @test !isfile(empty_destination*".jfem.toml")
        @test_throws ErrorException Builder.publish_image(candidate,candidate)
        @test_throws ErrorException Builder.publish_image(joinpath(root,"absent"),destination)
    end
end
