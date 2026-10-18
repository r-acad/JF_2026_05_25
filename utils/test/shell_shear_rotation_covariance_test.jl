using Test

module ShellShearRotationCovarianceFixture
using Test, LinearAlgebra, OpenJFEM
const F = OpenJFEM.FEM

function checks()
    # Isotropic membrane/bending isolate the transverse-shear frame. A strongly
    # anisotropic shear tensor must rotate with the physical geometry and nodal
    # translations/rotations, rather than in the opposite material direction.
    nu, h, E = 0.27, 0.4, 150.0
    A = E*h/(1-nu^2) * [1.0 nu 0.0; nu 1.0 0.0; 0.0 0.0 (1-nu)/2]
    D = A*h^2/12
    shapes = ([0.0 0.0; 1.4 0.1; 0.2 0.9],
              [-1.0 -0.5; 1.0 -0.5; 1.0 0.5; -1.0 0.5],
              [-1.0 -0.5; 1.0 -0.4; 0.8 0.6; -0.7 0.4])
    for X in shapes, Cs in ([4.0 0.0; 0.0 4.0], [9.0 1.7; 1.7 2.0])
        n = size(X,1)
        function kernel(x,a,d,c)
            n == 3 && return F.stiffness_tria3_matrices(x,a,d,c,h,E/(2*(1+nu)))
            # Q4's local kernel expects a canonical shell frame. Reconstruct
            # that frame from the physical geometry, as assembly does, rather
            # than treating arbitrarily rotated global coordinates as local.
            phi = atan(x[2,2]-x[1,2],x[2,1]-x[1,1])
            cb,sb = cos(phi),sin(phi)
            q = [cb -sb; sb cb]
            r = Matrix{Float64}(I,6,6)
            r[1:2,1:2] = q
            r[4:5,4:5] = q
            t = kron(Matrix{Float64}(I,n,n),r)
            al = F.rotate_constitutive_3x3!(copy(a),-phi)
            dl = F.rotate_constitutive_3x3!(copy(d),-phi)
            cl = F.rotate_constitutive_2x2!(copy(c),-phi)
            kl = F.stiffness_quad4_matrices(x*q,al,dl,cl,h,E;
                kernel_mode="macneal",kernel_planar=true,
                membrane_incomp=false,bending_incomp=false)
            return t*kl*t'
        end
        K = kernel(X,A,D,Cs)
        # Include a nonzero transverse-displacement/rotation field; comparing
        # only the membrane norm would conceal this shear-frame defect.
        plate = vcat([6i .+ [-3,-2,-1] for i in 1:n]...)
        u = sin.(collect(1.0:6n))
        for beta in (-1.1,-0.35,0.43,1.4)
            c,s = cos(beta),sin(beta)
            Q = [c -s; s c]
            R = Matrix{Float64}(I,6,6)
            R[1:2,1:2] = Q
            R[4:5,4:5] = Q
            T = kron(Matrix{Float64}(I,n,n),R)
            Ar = F.rotate_constitutive_3x3!(copy(A),beta)
            Dr = F.rotate_constitutive_3x3!(copy(D),beta)
            # Independent physical rotation of the material tensor: using
            # the implementation helper here too would let two wrong signs
            # cancel in the Q4 global-to-local conversion above.
            Cr = Q*Cs*Q'
            Kr = kernel(X*Q',Ar,Dr,Cr)
            mapped = T'*Kr*T
            @test mapped ≈ K rtol=2e-11
            @test mapped[plate,plate] ≈ K[plate,plate] rtol=2e-11
            @test dot(T*u,Kr*(T*u)) ≈ dot(u,K*u) rtol=2e-11
            @test T'*(Kr*(T*u)) ≈ K*u rtol=2e-11
            @test F.rotate_constitutive_2x2!(copy(Cs),beta) ≈ Cr rtol=2e-14
        end
    end
end
end

@testset "Shell transverse-shear material-frame covariance" begin
    ShellShearRotationCovarianceFixture.checks()
end
