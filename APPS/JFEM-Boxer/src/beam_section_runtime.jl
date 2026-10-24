# Share the small section-equilibrium implementation with the solver parser.
# This imports only standard-library algebra, not the numerical solver runtime.
module BeamSectionWarping
using LinearAlgebra, SparseArrays
include(joinpath(@__DIR__,"..","..","..","src","parsing","beam_section_warping.jl"))
end
