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

"""Tiny authored solids, independent of downloaded meshes or user studies."""
function abaqus_solid_inputs()
    # Two independently clamped bodies: one complete quadratic tetrahedron and
    # one full-integration hexahedron. All midside IDs are distinct and retained.
    mesh="""
    *HEADING
    Shared-image synthetic solid workload; m, N, kg
    *NODE
    101,0,0,0
    102,1,0,0
    103,0,1,0
    104,0,0,1
    105,0.5,0,0
    106,0.5,0.5,0
    107,0,0.5,0
    108,0,0,0.5
    109,0.5,0,0.5
    110,0,0.5,0.5
    201,2,0,0
    202,3,0,0
    203,3,1,0
    204,2,1,0
    205,2,0,1
    206,3,0,1
    207,3,1,1
    208,2,1,1
    *ELEMENT,TYPE=C3D10,ELSET=BODY
    1001,101,102,103,104,105,106,107,108,109,110
    *ELEMENT,TYPE=C3D8,ELSET=BODY
    2001,201,202,203,204,205,206,207,208
    *NSET,NSET=FIXED
    101,102,103,105,106,107,201,202,203,204
    *NSET,NSET=HEX_TOP
    205,206,207,208
    *MATERIAL,NAME=ISOTROPIC
    *ELASTIC
    7.0E10,0.3
    *DENSITY
    2700
    *SOLID SECTION,ELSET=BODY,MATERIAL=ISOTROPIC
    *BOUNDARY
    FIXED,1,3,0
    """
    static=mesh*"*STEP,NAME=Static solid warmup\n*STATIC\n*CLOAD\n104,3,-1\nHEX_TOP,3,-0.25\n*END STEP\n"
    modal=mesh*"*STEP,NAME=Modal solid warmup\n*FREQUENCY\n3\n*END STEP\n"
    [(name="abaqus_solids_static.inp",sol=101,text=static),
     (name="abaqus_solids_modal.inp.gz",sol=103,text=modal)]
end

function _exercise_abaqus_solids(native,on_case)
    mktempdir(;prefix="openjfem_abaqus_precompile_") do folder
        records=Dict{String,Any}[]
        for input in abaqus_solid_inputs()
            path=joinpath(folder,input.name);output=joinpath(folder,"sol$(input.sol)")
            if endswith(input.name,".gz")
                open(path,"w") do io
                    compressed=native.CodecZlib.GzipCompressorStream(io)
                    try write(compressed,input.text) finally close(compressed) end
                end
            else;write(path,input.text);end
            println("Shared warmup: Abaqus SOL$(input.sol), C3D10 and C3D8");flush(stdout)
            result=native.main(path;output_dir=output,export_jfem_binary=true,
                export_json=true,export_report=true)
            model=result["model"]
            get(model["abaqus_import"],"analysis_ready",false)||error("Abaqus solid warmup has incomplete physics")
            Int(result["sol_type"])==input.sol||error("Abaqus solid warmup ran the wrong solution")
            solids=model["CSOLIDs"]
            length(solids)==2&&length(solids["1001"]["NODES"])==10&&
                solids["2001"]["ABAQUS_TYPE"]=="C3D8"||error("Abaqus solid warmup lost original topology/formulations")
            roots=get(result,"eigenvalues",Float64[])
            input.sol==103&&(length(roots)!=3||!all(v->isfinite(v)&&v>0,roots))&&error("Abaqus modal warmup did not return three positive roots")
            archives=filter(endswith(".jfem"),readdir(output;join=true))
            length(archives)==1||error("Abaqus solid warmup must export one viewer archive")
            version=open(only(archives)) do io
                read(io,4)==UInt8[0x4a,0x46,0x45,0x4d]||error("Abaqus solid warmup produced invalid viewer output")
                read(io,UInt32)
            end
            version==6||error("Abaqus solid warmup discarded quadratic tetrahedron connectivity")
            push!(records,Dict("sol"=>input.sol,"ok"=>true,"input_gzip"=>endswith(input.name,".gz"),
                "elements"=>2,"tetra_nodes"=>10,"element_types"=>["C3D10","C3D8"],
                "modal_roots"=>length(roots),"viewer_version"=>Int(version),"viewer_bytes"=>filesize(only(archives))))
            on_case(path,output)
        end
        records
    end
end

"""Warm real input, stiffness/mass, solve, recovery and quadratic binary paths."""
function run_abaqus_solids(;on_case=(_,_)->nothing)
    isdefined(@__MODULE__,:OpenJFEM)||Core.eval(@__MODULE__,:(import OpenJFEM))
    native=getfield(@__MODULE__,:OpenJFEM)
    Base.invokelatest(_exercise_abaqus_solids,native,on_case)
end
end
