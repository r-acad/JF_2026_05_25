# Keep process startup, Julia compilation and numerical work distinguishable.
# Julia's compile_time already includes recompile_time; never subtract both.
function _pipeline_measure!(f, phases::AbstractDict, name::String)
    # Keep cold compilation of the closure/callee inside the measured interval,
    # rather than allowing inference to move it into compilation of this helper.
    stats = @timed Base.invokelatest(f)
    compilation = Float64(stats.compile_time)
    wall = Float64(stats.time)
    phases[name] = Dict{String,Any}(
        "wall_seconds" => wall,
        "compilation_seconds" => compilation,
        "recompilation_seconds" => Float64(stats.recompile_time),
        "execution_seconds" => compilation <= wall ? wall - compilation : nothing,
        "gc_seconds" => Float64(stats.gctime))
    return stats.value
end

function _pipeline_timing_payload(phases)
    numerical = phases["solve"]
    Dict{String,Any}(
        "schema_version" => 1,
        "solution_seconds" => numerical["execution_seconds"],
        "compilation_seconds" => sum(p["compilation_seconds"] for p in values(phases)),
        "measured_wall_seconds" => sum(p["wall_seconds"] for p in values(phases)),
        "phases" => phases,
        "solution_scope" => "Assembly, constraints, equilibrium/eigenvalue solution and numerical recovery; excludes Julia compilation, deck parsing, model construction and export.",
        "compilation_scope" => "Julia compilation measured inside pipeline stages; includes recompilation. Package loading/precompilation before main is process startup.",
        "measurement" => "Julia @timed stage wall time minus compilation time; unavailable if overlapping compilation exceeds stage wall time.")
end
