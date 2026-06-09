# MacNeal & Harder (1985), Section 3 -- curved cantilever beam.
#
# 90-deg arc cantilever in the XY plane, inner radius 4.12, outer radius 4.32,
# thickness (out-of-plane) 0.1. One end clamped, opposite end loaded with a
# unit force.
#
# MacNeal-Harder cite, from their Table 2:
#     in-plane (Fy) tip displacement    = 0.08734
#     out-of-plane (Fz) tip displacement = 0.5022
#
# These reference values are from the cited paper and are the deep-shell /
# Bernoulli-Euler analytical results MacNeal & Harder used to score
# finite elements.

tip_disp_in_plane()     = 0.08734
tip_disp_out_of_plane() = 0.5022
