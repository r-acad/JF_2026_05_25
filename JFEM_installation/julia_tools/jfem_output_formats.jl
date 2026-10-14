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
    'b' => :compact_buckling,      # SOL105 eigenvalues + peak GRID/PID only
    'e' => :export_element_energy, # SOL105 true element deformation energy
    'd' => :export_energy_density, # SOL105 element deformation energy / volume
)
const _DEFAULT_LETTERS = "jrs"   # what you get when no -string is given

# Parse a "-letters" token into the set of enabled export kwargs.
function _parse_format_letters(tok::AbstractString)
    letters = lowercase(strip(tok))
    startswith(letters, "-") && (letters = letters[2:end])
    enabled = Dict{Symbol,Bool}(v => false for v in values(_FORMAT_LETTERS))
    for ch in letters
        haskey(_FORMAT_LETTERS, ch) ||
            throw(ArgumentError("Unknown output-format letter '$ch' in \"$tok\". " *
                                "Valid: $(join(sort(collect(keys(_FORMAT_LETTERS)))))"))
        enabled[_FORMAT_LETTERS[ch]] = true
    end
    return enabled
end
