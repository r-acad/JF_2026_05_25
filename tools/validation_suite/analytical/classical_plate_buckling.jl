# Classical Kirchhoff plate -- uniaxial in-plane compression.
#
# Simply-supported rectangular plate, side lengths a (loaded) and b (free
# unloaded), thickness t. Material isotropic with E, nu. Uniform uniaxial
# in-plane stress sigma_x applied on the two edges normal to the x-axis.
#
# The classical critical stress (Timoshenko & Gere, "Theory of Elastic
# Stability", 1961, Ch. 9, Eq. (9-7)) is:
#
#     sigma_cr = (k * pi^2 * E * t^2) / (12 (1 - nu^2) * b^2)
#
# with
#
#     k = (m * b/a + a/(m * b))^2
#
# and m the half-wave number along the loaded direction. For an
# aspect ratio a/b = 1.0 the minimum is k = 4 at m = 1.
#
# For the canonical square plate a = b = 1, t = 0.01, E = 210e9, nu = 0.3:
#     sigma_cr = 4 * pi^2 * 210e9 * (0.01)^2 / (12 * (1 - 0.09) * 1^2)
#              ~= 7.591e7  Pa
#
# The deck applies sigma_x = 1.0 Pa as a unit reference load on the
# compressed edges, so the SOL 105 eigenvalue lambda equals sigma_cr
# directly.

const _DECK_A   = 1.0     # m, plate side along loading
const _DECK_B   = 1.0     # m, plate side transverse
const _DECK_T   = 0.01    # m, thickness
const _DECK_E   = 210e9   # Pa, Young's modulus
const _DECK_NU  = 0.3     # Poisson's ratio

function simply_supported_uniaxial_first_mode()
    # k = 4 for square plate, m = 1.
    k = 4.0
    sigma_cr = (k * pi^2 * _DECK_E * _DECK_T^2) /
               (12.0 * (1.0 - _DECK_NU^2) * _DECK_B^2)
    return sigma_cr
end
