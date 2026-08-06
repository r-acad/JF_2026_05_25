# MacNeal & Harder (1985), Section 9 -- pinched hemispherical shell.
#
# Hemispherical shell, radius R = 10, thickness t = 0.04, E = 6.825e7,
# nu = 0.3. Free along the equator. Two pairs of opposite radial point loads
# P = 2.0 on the equator, 90 deg apart (two pulling outward, two inward).
#
# TWO VARIANTS, TWO DIFFERENT REFERENCE VALUES -- do not interchange them:
#
#   * closed hemisphere (MacNeal & Harder's original, no hole at the pole):
#         radial displacement at the load = 0.0924
#   * 18-deg cut-out at the pole (the Belytschko/Simo variant, theta in
#     [18,90]), which is the variant this suite's deck models:
#         radial displacement at the load = 0.0930
#
# Both are restated together with their problem constants (including P = 2.0)
# in Y. Ko, P.-S. Lee and K.-J. Bathe, "Performance of the MITC3+ and MITC4+
# shell elements in widely-used benchmark problems", Computers & Structures
# 193 (2017) 187--206: Sec. 3.7 / Table 15 for the cut-out variant
# (u_ref = 9.3000e-2) and Sec. 3.8 / Table 17 for the closed one
# (u_ref = 9.2400e-2).
#
# cases/macneal_harder/hemispherical_shell.bdf is the CUT-OUT variant, so
# radial_disp_at_load() returns the cut-out value.

radial_disp_at_load()             = 0.0930
radial_disp_at_load_closed_pole() = 0.0924
