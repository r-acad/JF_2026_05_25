using Test, OpenJFEM, LinearAlgebra, ForwardDiff

const COUPLED_BEAM_FEM = OpenJFEM.FEM

function coupled_beam_kernel(L, D, shear_areas; E=1., G=1.)
    return COUPLED_BEAM_FEM.stiffness_frame3d(L, 2., D[2,2]/E, D[1,1]/E,
        0.7, E, G; I12=D[1,2]/E, As_y=shear_areas[1], As_z=shear_areas[2])
end

# Map a fixed-root tip displacement [v,w,theta_z,-theta_y] to native DOFs.
const COUPLED_BEAM_TIP = [8,9,12,11]
const COUPLED_BEAM_SIGNS = Diagonal([1.,1.,1.,-1.])
function coupled_beam_tip_compliance(k)
    return inv(Symmetric(COUPLED_BEAM_SIGNS *
        k[COUPLED_BEAM_TIP,COUPLED_BEAM_TIP] * COUPLED_BEAM_SIGNS))
end

@testset "Coupled Timoshenko beam integrates physical cantilever flexibility" begin
    # Independent Castigliano result: integrate bending moments from constant
    # tip forces/moments, and add transverse shear compliance. This verifies
    # all coupled coefficients instead of reproducing the stiffness formula.
    for L in (0.02, 0.4, 12.), product in (-0.8, 0., 0.8),
        shear_areas in ((Inf,Inf),(2.,2.),(0.3,4.),(Inf,0.5),(0.7,Inf))
        D = [3. product; product 1.2]
        k = coupled_beam_kernel(L,D,shear_areas)
        inverse_D = inv(D)
        shear_compliance = Diagonal([isinf(a) ? 0. : inv(a) for a in shear_areas])
        expected = [L^3/3*inverse_D+L*shear_compliance L^2/2*inverse_D;
                    L^2/2*inverse_D L*inverse_D]
        @test coupled_beam_tip_compliance(k) ≈ expected rtol=2e-10 atol=1e-12
        @test k ≈ k' rtol=1e-14
        eigenvalues = eigvals(Symmetric(k))
        @test minimum(eigenvalues) >= -1e-12*opnorm(k)
    end
end

@testset "Coupled frame has six rigid motions and rotates consistently" begin
    L = 0.23
    D = [3. 1.4; 1.4 1.2]
    k = coupled_beam_kernel(L,D,(0.3,0.3))
    rigid = zeros(12,6)
    rigid[1:3,1:3] .= Matrix{Float64}(I,3,3)
    rigid[7:9,1:3] .= Matrix{Float64}(I,3,3)
    rigid[4:6,4:6] .= Matrix{Float64}(I,3,3)
    rigid[10:12,4:6] .= Matrix{Float64}(I,3,3)
    rigid[8,6] = L
    rigid[9,5] = -L
    @test norm(k*rigid) <= 1e-13*opnorm(k)*norm(rigid)
    @test count(x->abs(x)<1e-10*opnorm(k),eigvals(Symmetric(k))) == 6
    for angle in (0.37,pi/2,-0.81), areas in ((0.3,0.3),(Inf,Inf))
        Q = [cos(angle) -sin(angle);sin(angle) cos(angle)]
        rotation = [1. 0. 0.; 0. Q[1,1] Q[1,2]; 0. Q[2,1] Q[2,2]]
        T = kron(Matrix{Float64}(I,4,4),rotation)
        @test coupled_beam_kernel(L,Q*D*Q',areas) ≈
            T*coupled_beam_kernel(L,D,areas)*T' rtol=1e-12 atol=1e-10
    end
    # Unequal shear areas transform with the section under a quarter turn.
    Q = [0. -1.;1. 0.]
    T = kron(Matrix{Float64}(I,4,4),[1. 0. 0.;0. 0. -1.;0. 1. 0.])
    @test coupled_beam_kernel(L,Q*D*Q',(0.8,0.3)) ≈
        T*coupled_beam_kernel(L,D,(0.3,0.8))*T' rtol=1e-12 atol=1e-10
end

@testset "Coupled frame derivatives include zero product and shear areas" begin
    function stiffness_parameters(p)
        area, inertia_product, shear_y, shear_z = p
        return vec(COUPLED_BEAM_FEM.stiffness_frame3d(0.35,area,1.2,3.,0.7,2.,0.8;
            I12=inertia_product,As_y=shear_y,As_z=shear_z))
    end
    p = [2.,0.,0.3,0.8]
    analytic = ForwardDiff.jacobian(stiffness_parameters,p)
    for column in 1:4
        step = 1e-5*max(abs(p[column]),1.)
        plus,minus = copy(p),copy(p)
        plus[column] += step
        minus[column] -= step
        numerical = (stiffness_parameters(plus)-stiffness_parameters(minus))/(2step)
        @test analytic[:,column] ≈ numerical rtol=1e-7 atol=1e-8
        @test norm(analytic[:,column]) > 0
    end
    # Only a shear area is dual here: promotion cannot rely on a dual axial
    # area, elastic modulus or product of inertia to select the matrix type.
    shear_only(a) = COUPLED_BEAM_FEM.stiffness_frame3d(0.35,2.,1.2,3.,0.7,2.,0.8;
        I12=0.4,As_y=a,As_z=0.8)[2,2]
    @test ForwardDiff.derivative(shear_only,0.3) ≈
        (shear_only(0.300001)-shear_only(0.299999))/0.000002 rtol=1e-7
    # Zero bending stiffness remains a supported degenerate section limit.
    k = COUPLED_BEAM_FEM.stiffness_frame3d(1.,1.,0.,0.,1.,1.,1.;As_y=1.,As_z=1.)
    @test all(isfinite,k)
    @test rank(k) == 2
end
