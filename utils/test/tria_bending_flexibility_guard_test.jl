using Test

module TriaBendingFlexibilityGuardFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F = OpenJFEM.FEM

function checks()
    # Inactive bounds preserve the operator exactly. Active bounds preserve
    # the third channel and the second orthogonal Schur diagonal; their
    # congruence can change several edge-coordinate entries.
    ordinary = [2.0 0.1 0.2; 0.1 3.0 -0.1; 0.2 -0.1 1.0]
    saved = copy(ordinary)
    @test !F.tria3_guard_bending_flexibility!(ordinary,1.0,1.0,0.6,0.8,4.0)
    @test isequal(ordinary,saved)
    slender = [1e-8 2e-5 0.0; 2e-5 2.0 0.0; 0.0 0.0 1.0]
    before = copy(slender)
    @test F.tria3_guard_bending_flexibility!(slender,0.004,1.0,0.8,0.6,3.0)
    @test slender[3,:] == before[3,:]
    @test slender[:,3] == before[:,3]
    @test minimum(eigvals(Symmetric(slender))) > 0

    for ratio in (1.0,2.0,5.0), angle in (0.0,0.43,1.07),
        X in ([0.0 0.0; 0.0042 0.0; 0.803 0.596],
              [0.0 0.0; 0.005 0.0; 0.0 1.0])
        E2,nu,h = 7e10,0.3,0.0025
        E1 = ratio*E2
        g12 = sqrt(E1*E2)/(2*(1+nu))
        den = 1-nu^2*E2/E1
        Q = [E1/den nu*E2/den 0.0; nu*E2/den E2/den 0.0; 0.0 0.0 g12]
        C = [E1/(2*(1+nu)) 0.0; 0.0 E2/(2*(1+nu))]
        F.rotate_constitutive_3x3!(Q,angle)
        F.rotate_constitutive_2x2!(C,angle)
        kernel(x,t; material_scale=1.0) = F.stiffness_tria3_matrices_generic(
            x,material_scale.*Q.*t,material_scale.*Q.*(t^3/12),
            material_scale.*C.*(5t/6),t,material_scale*E1;k6rot=100.)
        K = kernel(X,h)
        @test K ≈ K' rtol=1e-13
        @test minimum(eigvals(Symmetric(K))) >= -2e-12*opnorm(K)
        for axis in 1:3, rotation in (false,true)
            direction = zeros(3); direction[axis] = 1
            u = zeros(18)
            for i in 1:3
                p = [X[i,1],X[i,2],0.0]
                u[6i-5:6i-3] = rotation ? cross(direction,p) : direction
                rotation && (u[6i-2:6i] = direction)
            end
            @test norm(K*u) <= 2e-11*opnorm(K)*norm(u)
        end
        # Material units and geometric units cannot alter which physical
        # deformation this guard penalizes. Translational DOFs scale with
        # length; rotations do not. Strain energy scales with volume.
        @test kernel(X,h;material_scale=7.3) ≈ 7.3K rtol=2e-9
        scale = 9.0
        L = Diagonal(repeat([scale,scale,scale,1.0,1.0,1.0],3))
        @test L'*kernel(scale.*X,scale*h)*L ≈ scale^3*K rtol=2e-9
        u = 0.001.*sin.(collect(1.0:18.0))
        energy(t) = dot(u,kernel(X,t)*u)
        exact = ForwardDiff.derivative(energy,h)
        step = h*1e-4
        finite = (energy(h+step)-energy(h-step))/(2step)
        @test isfinite(exact) && exact > 0
        @test exact ≈ finite rtol=3e-6
    end
end
end

@testset "Triangle ordered bending-flexibility safeguard" begin
    TriaBendingFlexibilityGuardFixture.checks()
end
