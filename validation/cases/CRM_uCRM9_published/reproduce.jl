# From the shared JFEM repository environment:
# julia --startup-file=no --project=. validation/cases/CRM_uCRM9_published/reproduce.jl
using OpenJFEM, JSON, Dates

# Unbounded EIGRL limits occur in otherwise valid modal diagnostics. Preserve
# them explicitly without asking the JSON writer to emit invalid JSON numbers.
json_safe(x::AbstractFloat) = isfinite(x) ? x : string(x)
json_safe(x::AbstractDict) = Dict(string(k)=>json_safe(v) for (k,v) in x)
json_safe(x::AbstractArray) = map(json_safe, x)
json_safe(x) = x

output = isempty(ARGS) ? joinpath(@__DIR__, "reruns", Dates.format(now(), "yyyymmdd_HHMMSS")) : abspath(ARGS[1])
mkpath(output)
records = Any[]
for (sol, name) in ((101, "run_uCRM-9_static_cruise_coarse"), (103, "run_uCRM-9_modal_coarse"))
    target = joinpath(output, "SOL$sol")
    mkpath(target)
    result = OpenJFEM.main(joinpath(@__DIR__, name * ".bdf");
        output_dir=target, export_json=true, export_jfem_binary=true, export_report=false)
    if sol == 103
        frequency = get(result, "frequencies", Float64[])
        diagnostics = get(result, "solver_diagnostics", Dict())
        open(joinpath(target, "modal_diagnostics.json"), "w") do io
            JSON.print(io, json_safe(diagnostics), 2)
        end
        length(frequency) >= 20 || error("uCRM9 requires 20 modes; returned $(length(frequency)). See modal_diagnostics.json and the solver log.")
        push!(records, Dict("solution"=>sol, "frequencies_Hz"=>frequency[1:20],
            "angular_eigenvalues_rad2_s2"=>result["eigenvalues"][1:20]))
    else
        idmap = result["id_map"]
        coordinates = result["node_coords"]
        tip = sort([id for (id, index) in idmap if abs(coordinates[index, 2] - 29.3815136) <= 1e-3])
        for subcase in result["subcases"]
            u = subcase["raw_displacement"]
            point(id) = Dict("node_id"=>id, "xyz_m"=>collect(coordinates[idmap[id], :]),
                "translation_m"=>collect(u[6 * (idmap[id] - 1) .+ (1:3)]))
            push!(records, Dict("solution"=>sol, "subcase"=>get(subcase, "sid", 1),
                "inferred_observation"=>point(833), "tip_rib"=>point.(tip),
                "selector_note"=>"The published workbook does not name its tip observation point; GRID833 and the complete 21-node tip rib are reported without choosing the closest match."))
        end
    end
    open(joinpath(output, "responses.json"), "w") do io
        JSON.print(io, json_safe(records), 2)
    end
end
println("uCRM9 runs retained in ", output)
