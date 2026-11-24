using Test, LinearAlgebra, OpenJFEM

@testset "CQUAD8/CTRIA6 consistent mass" begin
    F = OpenJFEM.FEM
    quad = [0. 0. 0.; 2. 0. 0.; 2. 1. 0.; 0. 1. 0.; 1. 0. 0.; 2. .5 0.; 1. 1. 0.; 0. .5 0.]
    tria = [0. 0. 0.; 2. 0. 0.; 0. 1. 0.; 1. 0. 0.; 1. .5 0.; 0. .5 0.]
    m0, m1, m2 = 3.0, 0.2, 0.05
    for (xyz, area) in ((quad, 2.0), (tria, 1.0))
        n = size(xyz, 1)
        M = F.consistent_mass_shell_higher_order(xyz, (m0, m1, m2))
        @test M ≈ M'
        @test minimum(eigvals(Symmetric(M))) > -1e-12
        # Partition of unity: a rigid translation carries the exact mass.
        for c in 1:3
            d = zeros(6n); d[c:6:end] .= 1
            @test d' * M * d ≈ m0 * area
        end
        # Uniform u_x with uniform theta_y moves a point at height z by (1+z).
        d = zeros(6n); d[1:6:end] .= 1; d[5:6:end] .= 1
        @test d' * M * d ≈ area * (m0 + 2m1 + m2)
        # Uniform u_y with uniform theta_x moves it by (1-z).
        d = zeros(6n); d[2:6:end] .= 1; d[4:6:end] .= 1
        @test d' * M * d ≈ area * (m0 - 2m1 + m2)
        # Rotation about the normal carries no mass.
        d = zeros(6n); d[6:6:end] .= 1
        @test abs(d' * M * d) < 1e-14
        # Diagonal mass: on the midside nodes only, exact total mass, no rotary terms.
        L = F.consistent_mass_shell_higher_order(xyz, (m0, m1, m2); lumped=true)
        @test isdiag(L)
        @test all(L[6(k-1)+1, 6(k-1)+1] == 0 for k in 1:div(n, 2))
        @test all(L[6(k-1)+1, 6(k-1)+1] > 0 for k in div(n, 2)+1:n)
        @test sum(L[6(k-1)+3, 6(k-1)+3] for k in 1:n) ≈ m0 * area
        @test all(iszero, [L[6(k-1)+r, 6(k-1)+r] for k in 1:n for r in 4:6])
    end
    # A curved element carries the mass of its interpolated surface. A quadratic
    # edge through three points of a 90 degree arc is 0.56 % shorter than the arc,
    # so the quarter-cylinder patch (radius 1, length 2, area pi) is met to 1 %.
    angle(t) = (cos(t), sin(t))
    c0, c1, cm = angle(0.), angle(pi/2), angle(pi/4)
    curved = [c0[1] c0[2] 0.; c1[1] c1[2] 0.; c1[1] c1[2] 2.; c0[1] c0[2] 2.;
              cm[1] cm[2] 0.; c1[1] c1[2] 1.; cm[1] cm[2] 2.; c0[1] c0[2] 1.]
    M = F.consistent_mass_shell_higher_order(curved, (1.0, 0.0, 0.0))
    d = zeros(48); d[3:6:end] .= 1
    @test isapprox(d' * M * d, pi; rtol=1e-2)
    @test d' * M * d < pi
end
