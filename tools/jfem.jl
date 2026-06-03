# =============================================================================
# jfem.jl - dead-simple single-deck runner with good defaults.
#
#   julia --project=<JFEM> JFEM/tools/jfem.jl  <model.bdf>  [output_dir]
#
# but you normally never type that - use the `jfem` / `jfem.cmd` wrappers, which
# fill in julia, --project, --threads=auto, and the sysimage for you, so the call
# is just:
#
#   jfem  model.bdf
#   jfem  model.bdf  my_output_folder
#
# Behaviour:
#   * The solution sequence (SOL 101 / 103 / 105 / 106) is auto-detected from the
#     deck - you do not specify it.
#   * "Viewer-ready full results" by default: writes the binary .jfem (opens in
#     the POST 3D viewer), the markdown REPORT.md, and the results JSON, with mode
#     shapes stored for modal/buckling runs.
#   * If no output folder is given, results go in  <deck_dir>/<deckname>_out/ ,
#     right next to the input deck.
#   * Extra JFEM_* flags can still be appended as a 3rd argument
#     ("FLAG=val,FLAG2=val2") to override any default.
# =============================================================================

include(joinpath(@__DIR__, "testing", "run_manifest.jl"))
using OpenJFEM
using LinearAlgebra   # BLAS thread tuning for the dense solve/eigensolve phase

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

# Dense BLAS (Cholesky factor / eigensolve) is fastest at the PHYSICAL core count;
# OpenBLAS defaults to ~half the logical processors and all-logical (hyperthreads)
# is slower. Set it to physical cores so command-line runs use full throughput.
function _physical_cores()
    try
        if Sys.iswindows()
            out = read(`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum"`, String)
            n = tryparse(Int, strip(out)); n !== nothing && n > 0 && return n
        elseif Sys.islinux()
            pairs = Set{Tuple{String,String}}(); pid = ""; cid = ""
            for ln in eachline("/proc/cpuinfo")
                startswith(ln, "physical id") && (pid = strip(split(ln, ':')[end]))
                startswith(ln, "core id")     && (cid = strip(split(ln, ':')[end]))
                if isempty(strip(ln)) && !isempty(pid) && !isempty(cid)
                    push!(pairs, (pid, cid)); pid = ""; cid = ""
                end
            end
            !isempty(pairs) && return length(pairs)
        elseif Sys.isapple()
            out = read(`sysctl -n hw.physicalcpu`, String)
            n = tryparse(Int, strip(out)); n !== nothing && n > 0 && return n
        end
    catch
    end
    return Sys.CPU_THREADS
end
LinearAlgebra.BLAS.set_num_threads(clamp(_physical_cores(), 1, Sys.CPU_THREADS))

function _usage()
    println(stderr, """
    usage:  jfem  <model.bdf>  [output_dir]  [FLAG=val,FLAG2=val2]

      <model.bdf>   input deck (.bdf / .dat / .nas)
      [output_dir]  where to write results (default: <deck_dir>/<deckname>_out)
      [FLAGS]       optional JFEM_* overrides, comma-separated

    output formats (optional -letters BEFORE the deck; any order):
      j  .jfem binary (3D viewer)      v  VTK (ParaView)
      r  REPORT.md (markdown)          h  HDF5
      s  results JSON (summary)        m  model JSON dump
                                       c  card inventory
      Omit the -string for the default set:  -jrs  (.jfem + report + JSON).

    examples:
      jfem  model.bdf                 # default outputs (.jfem + report + JSON)
      jfem  model.bdf  results/run1   # custom output folder
      jfem  -rs  model.bdf            # only report + results JSON
      jfem  -jrsvh  model.bdf  out    # everything common, into out/
    """)
end

# --- output-format letters ---------------------------------------------------
# Map each letter to the OpenJFEM.main keyword it enables. Order is irrelevant.
const _FORMAT_LETTERS = Dict(
    'j' => :export_jfem_binary,   # .jfem binary (3D viewer)
    'r' => :export_report,        # REPORT.md
    's' => :export_json,          # results JSON (BUCKLING/JU/NONLINEAR per SOL)
    'v' => :export_vtk,           # VTK
    'h' => :export_hdf5,          # HDF5
    'm' => :export_model_json,    # model JSON dump
    'c' => :export_card_inventory,# card inventory
)
const _DEFAULT_LETTERS = "jrs"   # what you get when no -string is given

# Parse a "-letters" token into the set of enabled export kwargs.
function _parse_format_letters(tok::AbstractString)
    letters = lowercase(strip(tok))
    startswith(letters, "-") && (letters = letters[2:end])
    enabled = Dict{Symbol,Bool}(v => false for v in values(_FORMAT_LETTERS))
    for ch in letters
        haskey(_FORMAT_LETTERS, ch) ||
            (println(stderr, "ERROR: unknown output-format letter '$ch' in \"$tok\". " *
                             "Valid: $(join(sort(collect(keys(_FORMAT_LETTERS)))))"); exit(2))
        enabled[_FORMAT_LETTERS[ch]] = true
    end
    return enabled
end

if isempty(ARGS) || ARGS[1] in ("-h", "--help", "help")
    _usage()
    exit(isempty(ARGS) ? 1 : 0)
end

# --- consume an optional leading "-letters" output-format token ---------------
# Any leading token that starts with '-' is taken as the output-format string
# (the only dashed argument jfem accepts, besides -h/--help handled above).
# _parse_format_letters validates it and errors clearly on an unknown letter,
# rather than silently treating "-rz" as a filename.
args = collect(ARGS)
fmt_token = ""
if !isempty(args) && startswith(args[1], "-")
    fmt_token = args[1]
    args = args[2:end]
end
const FORMATS = isempty(fmt_token) ?
    _parse_format_letters(_DEFAULT_LETTERS) : _parse_format_letters(fmt_token)

isempty(args) && (println(stderr, "ERROR: no input deck given."); _usage(); exit(1))

# --- resolve input deck ------------------------------------------------------
const BDF_PATH = abspath(args[1])
isfile(BDF_PATH) || (println(stderr, "ERROR: deck not found: $BDF_PATH"); exit(2))

# --- resolve output dir (default: <deck_dir>/<deckname>_out) ------------------
const STEM = replace(basename(BDF_PATH), r"(?i)\.(bdf|dat|nas)$" => "")
const OUT_DIR = (length(args) >= 2 && !occursin("=", args[2])) ?
    abspath(args[2]) :
    joinpath(dirname(BDF_PATH), STEM * "_out")

# --- extra JFEM_* overrides (optional trailing FLAG=val,... string) -----------
user_flags = ""
if length(args) >= 3
    user_flags = args[3]
elseif length(args) >= 2 && occursin("=", args[2])
    user_flags = args[2]
end

# Always-on run flags: store mode shapes (so SOL 103/105 modes reach the viewer
# when .jfem is written) and suppress the thread-hint banner. The actual file
# set is controlled by FORMATS above, not by these env flags.
const DEFAULT_FLAGS = "JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=true,JFEM_SUPPRESS_THREAD_HINT=1"
# Keep the legacy env flag consistent with whether the .jfem binary is requested.
ENV["JFEM_EXPORT_BINARY"] = FORMATS[:export_jfem_binary] ? "true" : "false"

apply_jfem_flags!(DEFAULT_FLAGS)
isempty(strip(user_flags)) || apply_jfem_flags!(user_flags)
const APPLIED_FLAGS = _manifest_jfem_environment()

# A user FLAG=val override of JFEM_EXPORT_BINARY still wins for the .jfem file.
const EXPORT_JFEM_BINARY = lowercase(strip(get(ENV, "JFEM_EXPORT_BINARY", "true"))) in
                           ("1", "true", "yes", "on")

mkpath(OUT_DIR)
const _ON = [string(k) for (k, v) in FORMATS if v]
println(stderr, "JFEM: $(basename(BDF_PATH))  ->  $OUT_DIR")
println(stderr, "JFEM: outputs = " *
    (isempty(fmt_token) ? "$_DEFAULT_LETTERS (default)" : strip(lowercase(fmt_token), '-')))

write_run_manifest(OUT_DIR;
    repo_root=_REPO_ROOT,
    bdf_path=BDF_PATH,
    script_path=@__FILE__,
    args=ARGS,
    applied_flags=APPLIED_FLAGS,
    extra=Dict{String,Any}(
        "flags_raw" => isempty(strip(user_flags)) ? DEFAULT_FLAGS : DEFAULT_FLAGS * "," * user_flags,
        "export_jfem_binary" => EXPORT_JFEM_BINARY,
        "output_formats" => isempty(fmt_token) ? _DEFAULT_LETTERS : strip(lowercase(fmt_token), '-'),
        "simple_runner" => true,
    ))

OpenJFEM.main(BDF_PATH;
    output_dir=OUT_DIR,
    export_jfem_binary=EXPORT_JFEM_BINARY,
    export_json=FORMATS[:export_json],
    export_report=FORMATS[:export_report],
    export_vtk=FORMATS[:export_vtk],
    export_hdf5=FORMATS[:export_hdf5],
    export_model_json=FORMATS[:export_model_json],
    export_card_inventory=FORMATS[:export_card_inventory])

println(stderr, "JFEM: done. Results in $OUT_DIR")
