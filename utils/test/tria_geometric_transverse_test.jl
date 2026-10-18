using Test

module TriaGeometricTransverseFixture
using Test, LinearAlgebra, OpenJFEM, ForwardDiff
const F = OpenJFEM.Solver.FEM

# Independent constant-gradient expression for stress-linear transverse work.
# Initial stress parallel to a displacement gradient must not penalize motion
# along that same direction; the out-of-plane work retains the full stress.
function closed_form(coords, stress, h)
    x, y = coords[:, 1], coords[:, 2]
    area = abs(det(hcat(ones(3), coords))) / 2
    b = [y[2]-y[3], y[3]-y[1], y[1]-y[2]] / (2area)
    c = [x[3]-x[2], x[1]-x[3], x[2]-x[1]] / (2area)
    xx, yy, xy = stress
    K = zeros(promote_type(eltype(stress), typeof(h)), 18, 18)
    for i in 1:3, j in 1:3
        r, s = 6(i-1), 6(j-1)
        cross_term = b[i]*c[j] + c[i]*b[j]
        K[r+1, s+1] = h*area*(yy*c[i]*c[j] + xy*cross_term/2)
        K[r+2, s+2] = h*area*(xx*b[i]*b[j] + xy*cross_term/2)
        K[r+1, s+2] = K[r+2, s+1] = -h*area*xy*(b[i]*b[j]+c[i]*c[j])/2
        K[r+3, s+3] = h*area*(xx*b[i]*b[j] + yy*c[i]*c[j] + xy*cross_term)
    end
    K
end

function run_checks()
    geometries = ([0. 0.; 2. 0.; .3 .8], [0. 0.; 8. 0.; 7.97 .018],
                  [0. 0.; .12 0.; -2.4 3.1])
    isotropic = 70e9/(1-.3^2) * [1. .3 0.; .3 1. 0.; 0. 0. .35]
    orthotropic = OpenJFEM.laminate_plane_stress_qbar(135e9, 10e9, .3, 5e9, deg2rad(27.))
    stresses = ([1200., 0., 0.], [0., -900., 0.], [0., 0., 420.],
        isotropic*[2e-7, -1e-7, 3e-7], orthotropic*[-2e-7, 3e-7, -1e-7])
    h = .0025
    for coords in geometries, stress in stresses
        K = F.geometric_stiffness_tria3(coords, stress, h; trans_mode=:principal_transverse)
        expected = closed_form(coords, stress, h)
        @test K ≈ expected rtol=2e-13 atol=1e-12
        @test K ≈ K' rtol=1e-14
        @test K[collect(Iterators.flatten((6i+4:6i+6 for i in 0:2))), :] == zeros(9, 18)
        for d in 1:3
            rigid = zeros(18); rigid[d:6:end] .= 1
            @test norm(K*rigid) <= 2e-13*max(norm(K), 1.)
        end
        parts = sum(F.geometric_stiffness_tria3(coords,
            [j == k ? stress[j] : 0. for j in 1:3], h; trans_mode=:principal_transverse) for k in 1:3)
        @test K ≈ parts rtol=2e-13 atol=1e-12
        all_translations = F.geometric_stiffness_tria3(coords, stress, h; trans_mode=:all)
        @test K[3:6:end, 3:6:end] ≈ all_translations[3:6:end, 3:6:end] rtol=2e-13
    end
    for coords in geometries
        K = F.geometric_stiffness_tria3(coords, [1200., 0., 0.], h; trans_mode=:principal_transverse)
        axial = zeros(18); axial[1:6:end] .= coords[:, 1]
        @test abs(dot(axial, K*axial)) < 1e-12
        @test norm(K[2:6:end, 2:6:end]) > 0
        tangent = ForwardDiff.jacobian(s -> vec(F.geometric_stiffness_tria3(coords, s, h;
            trans_mode=:principal_transverse)), [-300., 180., 70.])
        expected = hcat((vec(closed_form(coords, [j == k ? 1. : 0. for j in 1:3], h)) for k in 1:3)...)
        @test tangent ≈ expected rtol=3e-13 atol=1e-12
    end
end
end

@testset "Triangle stress-linear transverse geometric stiffness" begin
    TriaGeometricTransverseFixture.run_checks()
end
