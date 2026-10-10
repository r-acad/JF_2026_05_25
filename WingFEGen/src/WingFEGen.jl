# ===========================================================================
#  WingFEGen - finite element model generator for a wing torsion box
#
#  Reads a TOML input file describing a trapezoidal wing (NACA sections at the
#  root and the tip, area, aspect ratio, taper, twist, sweep, dihedral), the
#  torsion box layout (spar positions, rib pitch, stringer pitch) and the mesh
#  density, then builds a fully congruent finite element model made of
#
#    * upper and lower skin shells,
#    * front and rear spar web shells,
#    * rib web shells,
#    * stringer and spar cap bars,
#    * one RBE3 per rib station, with the independent node on the chord line,
#    * root supports in 1, 2 and 3,
#
#  plus a quadrilateral mesh of the aerodynamic surface. The model is shown in
#  a Babylon.js web app, can be written as a NASTRAN deck, and can be solved
#  in place by the JFEM solver, whose results come straight back into the
#  viewer as mode shapes or a deformed static shape.
#
#  Entry points:
#     run_app(input)          start the web application
#     build_model(params)     generate the model in process
#     write_nastran(m, path)  write the NASTRAN deck
#     start_jfem_job(...)     solve the deck in JFEM
# ===========================================================================
module WingFEGen

"""Report real startup stages when the command-line launcher installs a listener."""
function _startup_stage(message::AbstractString)
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :wingfegen_startup_progress) || return nothing
    Base.invokelatest(getfield(parent, :wingfegen_startup_progress), String(message))
    return nothing
end

const _startup_package_started = Ref(time())
function _startup_begin_package(name::String)
    _startup_stage("Loading package $name")
    _startup_package_started[] = time()
end
function _startup_end_package(package::Module, name::String)
    version = try Base.pkgversion(package) catch; nothing end
    suffix = version === nothing ? "" : " v$version"
    _startup_stage("Loaded $name$suffix in $(round(time()-_startup_package_started[];digits=2)) s")
end

_startup_begin_package("Printf")
using Printf
_startup_end_package(Printf, "Printf")
_startup_begin_package("Dates")
using Dates
_startup_end_package(Dates, "Dates")
_startup_begin_package("TOML")
using TOML
_startup_end_package(TOML, "TOML")
_startup_begin_package("HTTP")
import HTTP
_startup_end_package(HTTP, "HTTP")
_startup_begin_package("JSON")
import JSON
_startup_end_package(JSON, "JSON")
_startup_begin_package("MsgPack")
import MsgPack
_startup_end_package(MsgPack, "MsgPack")
_startup_begin_package("VortexLattice")
import VortexLattice
_startup_end_package(VortexLattice, "VortexLattice")
_startup_begin_package("SHA")
import SHA
_startup_end_package(SHA, "SHA")

_startup_stage("Loading input definitions, airfoils, materials and reference geometry")
include("runtime_bootstrap.jl")
include("airfoil.jl")
include("airfoil_database.jl")
include("reference_assets.jl")
include("plan_view_state.jl")
include("materials.jl")
include("params.jl")
_startup_stage("Loading wing geometry, rib layout and structural meshing code")
include("geometry.jl")
include("rib_layout.jl")
include("mesh.jl")
include("component_properties.jl")
include("stiffened_panels.jl")
include("panel_properties.jl")
include("supports.jl")
include("rib_mesh.jl")
include("leading_edge_orientation.jl")
_startup_stage("Loading fuel, mass properties and element coordinate frames")
include("fuel.jl")
include("fuel_masses.jl")
include("shell_frames.jl")
include("coordinate_payload.jl")
include("sections.jl")
include("weights.jl")
include("structure_loads.jl")
include("load_cases.jl")
_startup_stage("Loading Nastran output and aerodynamic load transfer code")
include("nastran.jl")
include("aerodynamics.jl")
include("load_moments.jl")
include("load_plots.jl")
include("payload.jl")
_startup_stage("Loading JFEM job management and sensitivity analysis code")
include("jfem_run.jl")
include("sensitivity.jl")
include("sensitivity_compute.jl")
include("sensitivity_operators.jl")
include("sensitivity_eigen_adjoint.jl")
include("sensitivity_analytic_beams.jl")
include("sensitivity_analytic_loads.jl")
include("sensitivity_analytic_geometric.jl")
include("sensitivity_analytic.jl")
_startup_stage("Loading Nastran import and imported-property sensitivity code")
include("nastran_import.jl")
include("nastran_import_sensitivity.jl")
_startup_stage("Loading HTTP routes, study storage and local file operations")
include("server.jl")
include("nastran_import_server.jl")
_startup_stage("Application code loaded; no FEM or analysis has been created")

export Airfoil, naca_airfoil, Wing, make_wing, Model, BoxGrid
export default_params, read_input, validate_params, params_to_toml
export build_model, write_nastran, mesh_payload, run_app
export aerodynamic_loads
export all_checks_pass
export find_jfem, start_jfem_job, jfem_results_payload

"""
    default_input_path(root = ...)

Location of the input file shipped with the application.
"""
default_input_path(root::AbstractString = dirname(@__DIR__)) =
    joinpath(root, "input", "wing_input.toml")

function ensure_default_input(root::AbstractString=dirname(@__DIR__))
    path=default_input_path(root)
    isfile(path)&&return path
    example=joinpath(root,"examples","wing_default.toml")
    isfile(example)||error("Factory example not found: $example; provide an input TOML filename")
    mkpath(dirname(path));cp(example,path;force=false)
    return path
end

"""
    print_report(m; io = stdout)

Print the model summary and the congruency checks.
"""
function print_report(m::Model; io::IO = stdout)
    println(io)
    println(io, "  Model summary")
    println(io, "  ", "-"^58)
    for (k, v) in m.info
        println(io, "  ", rpad(k, 28), v)
    end
    println(io)
    println(io, "  Congruency checks")
    println(io, "  ", "-"^58)
    for (name, detail, ok) in m.checks
        println(io, "  ", ok ? "[ ok ]" : "[FAIL]", " ", rpad(name, 32), detail)
    end
    println(io)
    println(io, all_checks_pass(m) ? "  all congruency checks passed" :
                                     "  CONGRUENCY CHECKS FAILED")
    println(io)
    return nothing
end

"""
    main(args = ARGS)

Command line entry point.

    julia --project=. run.jl                       serve the web app
    julia --project=. run.jl my_wing.toml          serve with another input
    julia --project=. run.jl --nastran             generate and write, no browser
    julia --project=. run.jl --port 9000
    julia --project=. run.jl --no-browser
"""
function main(args::AbstractVector{<:AbstractString} = ARGS; on_ready::Function = () -> nothing)
    root = dirname(@__DIR__)
    input = ""
    port = 8080
    headless = false
    launch = true

    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--nastran"
            headless = true
        elseif a == "--no-browser"
            launch = false
        elseif a == "--port"
            i += 1
            i <= length(args) || error("--port needs a value")
            port = parse(Int, args[i])
        elseif a in ("-h", "--help")
            println(strip(string(@doc main)))
            return 0
        elseif startswith(a, "--")
            error("unknown option $a")
        else
            input = a
        end
        i += 1
    end

    _startup_stage("Resolving the input definition and command-line options")
    isempty(input) && (input = ensure_default_input(root))
    isfile(input) || error("input file not found: $input")

    if headless
        on_ready()
        params = read_input(input)
        model = build_model(params)
        print_report(model)
        path = isabspath(params["output.nastran_file"]) ?
               params["output.nastran_file"] :
               normpath(joinpath(root, params["output.nastran_file"]))
        result = write_nastran(model, path)
        println("  NASTRAN deck: ", result["path"])
        println("  ", result["lines"], " lines, ", result["bytes"], " bytes")
        println()
        return all_checks_pass(model) ? 0 : 1
    end

    run_app(input; port = port, root = root, launch_browser = launch, on_ready)
    return 0
end

end # module WingFEGen
