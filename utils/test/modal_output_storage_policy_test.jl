using Test, LinearAlgebra, OpenJFEM

@testset "Modal mass coordinate transforms preserve physical frames" begin
    ids = Dict(101=>2, 3=>1, 999=>3)
    frames = [Matrix{Float64}(I, 3, 3),
        [0. -1. 0.; 1. 0. 0.; 0. 0. 1.],
        [1. 0. 0.; 0. 0. -1.; 0. 1. 0.]]
    original = reshape(collect(1.:36.), 18, 2)
    reference = copy(original)
    for index in values(ids), mode in 1:2, offset in (0, 3)
        rows = (6 * (index - 1) + offset) .+ (1:3)
        reference[rows, mode] = frames[index]' * original[rows, mode]
    end
    actual = OpenJFEM._sol103_global_to_analysis_modes(original, ids, frames)
    @test actual == reference
    @test original == reshape(collect(1.:36.), 18, 2)
    for direction in 1:3
        basis = Matrix{Float64}(I, 3, 3)[:, direction]
        translation = OpenJFEM._sol103_global_translation_vector(ids, frames, 18, direction)
        for index in values(ids)
            rows = (6 * (index - 1)) .+ (1:3)
            @test translation[rows] == frames[index]' * basis
            @test translation[rows .+ 3] == zeros(3)
        end
    end
    mass = Diagonal(collect(1.:18.))
    totals, participation = OpenJFEM._sol103_modal_mass_metrics(
        mass, actual, [1., 2.], ids, frames, 18)
    for direction in 1:3
        translation = OpenJFEM._sol103_global_translation_vector(ids, frames, 18, direction)
        @test totals[direction] ≈ dot(translation, mass * translation)
        for mode in 1:2
            phi = actual[:, mode]
            @test participation[mode]["generalized_mass"] ≈ dot(phi, mass * phi)
            key = ("meff_x", "meff_y", "meff_z")[direction]
            @test participation[mode][key] ≈ dot(translation, mass * phi)^2 / dot(phi, mass * phi)
        end
    end
end

@testset "SOL103 output policy preserves vectors without duplicate public tables" begin
    mktempdir() do dir
        path = joinpath(dir, "modal_storage.bdf")
        write(path, "SOL 103\nCEND\nSPC = 1\nMETHOD = 3\nSUBCASE 1\nBEGIN BULK\n" *
            "GRID,1,,0.,0.,0.\nCELAS2,1,200.,1,1,0,0\nCONM2,2,1,0,2.\n" *
            "SPC1,1,23456,1\nEIGRL,3,,,1\nENDDATA\n")
        model = OpenJFEM.bdf_to_model(path)
        public_result = OpenJFEM.solve_model(model)
        @test public_result["eigenvalues"] ≈ [100.]
        @test public_result["mode_shape_storage"]["public_list_stored"]
        @test length(public_result["mode_shapes"]) == 1
        @test public_result["mode_shapes"] === public_result["subcases"][1]["mode_shapes"]
        @test public_result["_raw_mode_shapes"] === public_result["subcases"][1]["_raw_mode_shapes"]

        model["_sol103_store_public_mode_shapes"] = false
        matrix_result = OpenJFEM.solve_model(model)
        @test matrix_result["eigenvalues"] ≈ public_result["eigenvalues"]
        @test matrix_result["_raw_mode_shapes"] ≈ public_result["_raw_mode_shapes"]
        @test isempty(matrix_result["mode_shapes"])
        @test isempty(matrix_result["subcases"][1]["mode_shapes"])
        @test matrix_result["mode_shape_storage"]["raw_matrix_stored"]
        @test !matrix_result["mode_shape_storage"]["public_list_stored"]

        # The selected -jr file policy must leave the viewer and report complete.
        file_result = OpenJFEM.main(path; output_dir=joinpath(dir, "binary"),
            export_json=false, export_jfem_binary=true, export_report=true)
        @test isempty(file_result["mode_shapes"])
        @test isfile(joinpath(dir, "binary", "modal_storage.jfem"))
        @test isfile(joinpath(dir, "binary", "modal_storage.REPORT.md"))
        @test file_result["_raw_mode_shapes"] ≈ public_result["_raw_mode_shapes"]

        # Several modal subcases share the same tables with the compatibility
        # view while preserving their individual case/mode ordering.
        delete!(model, "_sol103_store_public_mode_shapes")
        model["CASE_CONTROL"]["SUBCASES"][2] = deepcopy(model["CASE_CONTROL"]["SUBCASES"][1])
        multi = OpenJFEM.solve_model(model)
        @test multi["eigenvalues"] ≈ [100., 100.]
        @test length(multi["mode_shapes"]) == 2
        @test multi["mode_shapes"][1] === multi["subcases"][1]["mode_shapes"][1]
        @test multi["mode_shapes"][2] === multi["subcases"][2]["mode_shapes"][1]
        @test multi["_raw_mode_shapes"][:, 1] ≈ multi["subcases"][1]["_raw_mode_shapes"][:, 1]
        @test multi["_raw_mode_shapes"][:, 2] ≈ multi["subcases"][2]["_raw_mode_shapes"][:, 1]
    end
end
