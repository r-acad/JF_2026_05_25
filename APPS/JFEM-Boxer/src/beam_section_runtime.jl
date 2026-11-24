# Share the section implementations with the solver parser: the finite-element section conversion
# that the solver applies to PBARL/PBEAML sections, and the converged T-section solution whose
# analytic gradients the sensitivities use.
# This imports only standard-library algebra, not the numerical solver runtime.
module BeamSectionWarping
using LinearAlgebra, SparseArrays
include(joinpath(@__DIR__,"..","..","..","src","parsing","beam_section_warping.jl"))
include(joinpath(@__DIR__,"..","..","..","src","parsing","section_fe.jl"))
end
