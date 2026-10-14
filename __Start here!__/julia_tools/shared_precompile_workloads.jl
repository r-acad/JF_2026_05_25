module JFEMSharedPrecompileWorkloads
using HTTP, MsgPack

const SHARED_PACKAGES = [:OpenJFEM, :HTTP, :MsgPack, :JSON, :WingFEGen, :Pkg]

function required_packages(; find_package=Base.find_package)
    for package in SHARED_PACKAGES
        find_package(String(package)) === nothing &&
            error("Shared sysimage requires $package; run setup in the complete repository")
    end
    return copy(SHARED_PACKAGES)
end

"""Warm the production request contract; failed routes or analyses abort the build."""
function exercise_pandeator(handler, decks)
    isempty(decks) && error("PANDEATOR warmup needs at least one deck")
    for target in ("/", "/health", "/vendor/msgpack.min.js")
        response = handler(HTTP.Request("GET", target))
        response.status == 200 || error("PANDEATOR warmup GET $target returned $(response.status)")
        isempty(response.body) && error("PANDEATOR warmup GET $target returned an empty body")
    end
    response = handler(HTTP.Request("OPTIONS", "/analyze"))
    response.status == 204 || error("PANDEATOR warmup OPTIONS returned $(response.status)")
    results = Dict{String,Any}[]
    for deck in decks
        payload = Dict("case_id" => "sysimg", "bdf_path" => abspath(deck))
        request = HTTP.Request("POST", "/analyze",
            ["Content-Type" => "application/msgpack"], MsgPack.pack(payload))
        response = handler(request)
        response.status == 200 || error("PANDEATOR warmup POST failed for $deck: HTTP $(response.status)")
        result = MsgPack.unpack(Vector{UInt8}(response.body))
        get(result, "ok", false) === true || error("PANDEATOR warmup analysis failed for $deck: $(get(result, "log", result))")
        isempty(get(result, "jfem_bytes", UInt8[])) && error("PANDEATOR warmup produced no viewer result for $deck")
        push!(results, Dict("deck" => abspath(deck), "sol" => result["sol"],
            "ok" => true, "viewer_bytes" => length(result["jfem_bytes"]),
            "elapsed_s" => result["elapsed_s"]))
    end
    return results
end

function run_pandeator(root, decks)
    server_path = joinpath(root, "APPS", "PANDEATOR_APP", "panel_server.jl")
    isfile(server_path) || error("Shared sysimage requires PANDEATOR: missing $server_path")
    # All service outputs belong to this owned temporary root and are cleaned
    # by mktempdir after the workload. Never derive deletion targets from a reply.
    return mktempdir(; prefix="openjfem_panel_precompile_") do output
        previous = get(ENV, "JFEM_PANEL_RUN_ROOT", nothing)
        ENV["JFEM_PANEL_RUN_ROOT"] = output
        try
            server = Module(:JFEMPandeatorImageWarmup)
            Core.eval(server, :(include(path) = Base.include(@__MODULE__, path)))
            Base.include(server, server_path)
            return Base.invokelatest() do
                exercise_pandeator(getfield(server, :handle), decks)
            end
        finally
            previous === nothing ? delete!(ENV, "JFEM_PANEL_RUN_ROOT") : (ENV["JFEM_PANEL_RUN_ROOT"] = previous)
        end
    end
end
end
