# Import-only worker context. Reuse the actual source definitions and module
# name so Serialization restores the identical Model/Blob types in the server.
# Loading the full application here also initialized the aerodynamic library,
# HTTP server and every analysis path, despite this worker only reading a deck.
module WingFEGen
using Printf, Dates, TOML, LinearAlgebra
import JSON, MsgPack, SHA, Serialization
include("airfoil.jl")
include("materials.jl")
include("params.jl")
include("geometry.jl")
include("mesh.jl")
include("shell_frames.jl")
include("sensitivity_analytic_beams.jl")
include("payload.jl")
include("nastran_import.jl")
include("nastran_import_sensitivity.jl")
end
