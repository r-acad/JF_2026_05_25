using Test, LinearAlgebra, JSON, OpenJFEM

@testset "Modal progress reports actual operator work and convergence" begin
    solver = OpenJFEM.Solver
    diagonal = collect(1.0:12.0)
    operator_calls = Ref(0)
    operator(x) = begin
        operator_calls[] += 1
        diagonal .* x
    end
    values = nothing
    vectors = nothing
    info = nothing
    output = mktemp() do path, io
        redirect_stdout(io) do
            values, vectors, info = solver._sol103_run_eigsolve(
                operator, normalize(collect(1.0:12.0)), 3, :LM;
                progress_label="Progress regression extraction",
                progress_interval_seconds=0.0, krylovdim=12,
                maxiter=10, tol=1e-11, ishermitian=true)
        end
        flush(io)
        read(path, String)
    end
    events = [JSON.parse(line[length("[JFEM_MODAL_PROGRESS] ")+1:end])
        for line in split(output, '\n')
        if startswith(line, "[JFEM_MODAL_PROGRESS] ")]
    @test !isempty(events)
    @test first(events)["state"] == "started"
    @test last(events)["state"] == "completed"
    running = filter(event -> event["state"] == "running", events)
    @test length(running) == operator_calls[]
    @test [event["operator_applications"] for event in running] == collect(1:operator_calls[])
    @test all(event -> !haskey(event, "converged") && !haskey(event, "iteration"), running)
    @test all(event -> event["schema_version"] == 1 && event["phase"] == "extraction", events)
    @test last(events)["operator_applications"] == operator_calls[] == info.numops
    @test last(events)["converged"] == info.converged
    @test last(events)["iteration"] == info.numiter
    @test last(events)["residual_kind"] == "transformed"
    @test last(events)["residual"] ≈ maximum(info.normres)
    @test sort(real.(values[1:3])) ≈ [10.0, 11.0, 12.0]
    @test all(j -> norm(diagonal .* vectors[j] - values[j] .* vectors[j]) < 1e-8, 1:3)
    @test occursin("verifying original-pencil residuals", output)
end
