# Package release gate uses only the already curated public suite.
using Test, LinearAlgebra
BLAS.set_num_threads(1)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

saved_args = copy(ARGS)
empty!(ARGS)
push!(ARGS, "--no-write")
suite_rows = try
    # The suite remains independently usable as a CLI and returns structured
    # rows here; a successful process exit alone does not establish parity.
    include(joinpath(@__DIR__, "..", "validation", "run_public_suite.jl"))
finally
    empty!(ARGS)
    append!(ARGS, saved_args)
end

@testset "Curated public release gate" begin
    @test length(suite_rows) == 19
    @test all(r -> r.jfem !== nothing && isfinite(r.jfem), suite_rows)
    @test all(r -> !startswith(r.verdict, "ERROR") && r.verdict != "JFEM_SKIPPED", suite_rows)
    parity_rows = filter(r -> r.parity_ref !== nothing, suite_rows)
    @test length(parity_rows) == 17
    @test all(r -> r.parity_verdict == "PARITY_PASS", parity_rows)

    # Existing coarse-mesh analytical limitations remain visible as FAIL
    # accuracy rows; reference parity never turns them into accuracy passes.
    # A new failing case or quantity must be reviewed explicitly.
    known_accuracy_limits = Set([
        ("MH_curved_beam_in_plane", "tip_disp_in_plane"),
        ("MH_pinched_cylinder", "radial_disp_under_load"),
    ])
    for row in suite_rows
        @test row.verdict == "PASS" ||
            (row.verdict == "FAIL" && (row.case_id, row.quantity) in known_accuracy_limits)
    end
end
