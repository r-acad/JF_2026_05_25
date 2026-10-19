# Weak-axis Euler buckling of the public one-CBAR cantilever.
# Pcr = pi^2 E I / (4 L^2); deck uses a unit compressive reference force.
# This is a continuum target. The one-element result has discretization error.
first_buckling_load() = pi^2 * 1.0e7 * (1.0 / 24.0) / (4.0 * 10.0^2)
