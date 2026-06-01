# MacNeal & Harder (1985), Section 7 -- Scordelis-Lo roof.
#
# Cylindrical roof, radius R = 25, length L = 50, thickness t = 0.25,
# subtended angle 80 deg, supported on rigid diaphragms at the two ends.
# Self-weight load (gravity) per unit area g_density.
# Material: E = 4.32e8, nu = 0.0.
#
# Reference vertical displacement at the centre of the free (straight) edge:
#     midedge_vertical_disp = 0.3024
#
# Quoted by MacNeal & Harder and widely reproduced; this is the deep-shell
# extrapolated value.

midedge_vertical_disp() = -0.3024  # negative sign = downward; sign convention
                                   # depends on local DOF orientation. The
                                   # comparison driver compares magnitudes
                                   # when configured to do so.
