using Test, LinearAlgebra, OpenJFEM

@testset "Concentrated-mass CBAR modes agree with full-space extraction" begin
    solver = OpenJFEM.Solver
    path = joinpath(@__DIR__, "..", "examples", "precompile",
        "sol103_concentrated_mass_beam.bdf")
    model = OpenJFEM.bdf_to_model(path)
    K, ids, coordinates, ndof, frames, element_scale, constraints, _, original_diagonal =
        solver.assemble_stiffness(model)
    M = solver.assemble_mass(model, ids, coordinates, frames, ndof;
        constraint_map=constraints)
    function modes(maximum_support)
        withenv("JFEM_SOL103_DENSE_MAX_DOF" => "0",
                "JFEM_SOL103_MASS_SUPPORT_MAX_DOF" => string(maximum_support)) do
            solver.solve_modes(K, M, ndof, model, ids, coordinates, 1, frames, 4;
                rbe3_map=constraints, max_elem_stiff=element_scale,
                orig_diag=original_diagonal, return_diagnostics=true)
        end
    end
    reduced_values, reduced_frequency, reduced_shapes, reduced = modes(4096)
    full_values, full_frequency, full_shapes, full = modes(0)
    @test reduced["mass_support_reduction"]["used"]
    @test reduced["mass_support_reduction"]["full_dofs"] == 234
    @test reduced["mass_support_reduction"]["supported_dofs"] == 12
    @test !full["mass_support_reduction"]["used"]
    @test length(reduced_values) == length(full_values) == 4
    @test reduced_values ≈ full_values rtol=1e-7
    @test reduced_frequency ≈ full_frequency rtol=1e-7
    # Equal bending inertias create repeated pairs. Compare the mass-weighted
    # subspaces so a rotated/reordered repeated basis remains equivalent.
    @test reduced_values[1] ≈ reduced_values[2] rtol=1e-7
    @test reduced_values[3] ≈ reduced_values[4] rtol=1e-7
    @test svdvals(full_shapes' * M * reduced_shapes) ≈ ones(4) atol=1e-7
    @test maximum(reduced["eigenpair_relative_residuals"]) < 1e-6
    @test maximum(full["eigenpair_relative_residuals"]) < 1e-6
    @test norm(reduced_shapes[7:12, :]) > 0.0
    @test all(iszero, reduced_shapes[1:6, :])
    @test reduced_shapes' * M * reduced_shapes ≈ Matrix{Float64}(I, 4, 4) atol=1e-7
end
