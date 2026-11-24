using Test, LinearAlgebra, OpenJFEM

# FORCE/MOMENT magnitudes and direction components are held in single precision,
# as in the reference solver. A seven-digit direction is not exactly in the
# plane of a rotated panel; the cancellation residue must be the reference one.
@testset "FORCE/MOMENT real fields are single precision" begin
    P = OpenJFEM.ReferenceParser
    @test P.load_single_precision(0.9063078) === Float64(Float32(0.9063078))
    @test P.load_single_precision(0.25) === 0.25
    @test P.load_single_precision(1.0e300) === 1.0e300          # outside Float32: unchanged
    @test P.load_single_precision(0) === 0.0
    normal = normalize(cross([0.9063077870366499, 0.42261826174069944, 0.0],
                             [-0.32374437096706, 0.69427204401488, 0.64278760968654]))
    typed = [0.9063078, 0.4226183, 0.0]
    single = P.load_single_precision.(typed)
    @test abs(dot(typed, normal)) > 1e-9                         # the typed direction leaves the plane
    @test isapprox(dot(typed, normal) / dot(single, normal), 1.32895; atol=2e-4)
    mktempdir() do dir
        path = joinpath(dir, "load.bdf")
        write(path, "SOL 101\nCEND\nBEGIN BULK\nGRID,1,,0.,0.,0.\n" *
            "FORCE,7,1,,.25,.9063078,.4226183,0.\nMOMENT,8,1,,.3333333,.1,.2,.7\nENDDATA\n")
        model = OpenJFEM.bdf_to_model(path)
        force = only(model["FORCEs"]); moment = only(model["MOMENTs"])
        @test force["Dir"] == Float64.(Float32.([0.9063078, 0.4226183, 0.0]))
        @test force["Mag"] === 0.25
        @test moment["Mag"] === Float64(Float32(0.3333333))
        @test moment["Dir"] == Float64.(Float32.([0.1, 0.2, 0.7]))
    end
end
