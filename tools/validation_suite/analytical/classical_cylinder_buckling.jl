# Classical thin cylindrical shell -- uniform axial compression.
#
# Brush & Almroth, "Buckling of Bars, Plates and Shells" (1975), Ch. 5,
# gives the classical critical axial stress for an isotropic thin cylinder
# (perfect, no imperfections) as
#
#     sigma_cr = E * t / (R * sqrt(3 (1 - nu^2)))
#
# This formula is known to over-predict experimental capacity by a factor
# of ~2 to 5 due to imperfection sensitivity. The reference is included
# here to score JFEM's bifurcation eigenvalue against the *classical
# theory*, not against experiment. The tolerance in the manifest is
# accordingly wide.
#
# Canonical deck: R = 100, L = 200, t = 1, E = 210e9, nu = 0.3.
# Unit axial compressive stress applied uniformly at the two ends -- so
# the SOL 105 eigenvalue equals sigma_cr.

const _DECK_R   = 100.0   # m, midsurface radius
const _DECK_L   = 200.0   # m, length
const _DECK_T   = 1.0     # m, thickness
const _DECK_E   = 210e9   # Pa
const _DECK_NU  = 0.3

function thin_cylinder_axial_critical()
    return _DECK_E * _DECK_T / (_DECK_R * sqrt(3.0 * (1.0 - _DECK_NU^2)))
end
