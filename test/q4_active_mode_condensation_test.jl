using Test, LinearAlgebra

module Q4ActiveModeTestHarness
using LinearAlgebra, Test
import ForwardDiff
include(joinpath(@__DIR__, "..", "src", "FEMKernels.jl"))
end
const Q4AM = Q4ActiveModeTestHarness.FEM

@testset "Internal-mode Schur complement is a restricted stationary energy" begin
    for n in (4, 8)
        F = [sin(i+2j) + (i==j ? 3. : 0.) for i in 1:n, j in 1:n]
        B = F'*F + Matrix{Float64}(I, n, n)
        C = [cos(2i+j)/3 for i in 1:5, j in 1:n]
        A = Matrix{Float64}(I, 5, 5) + C*(B\C')
        u = sin.(collect(1.:5.))
        for active in ([2, 3], collect(1:n), Int[])
            w = [i in active ? 1. : 0. for i in 1:n]
            H = Q4AM.q4_internal_mode_compliance(B, w)
            K = A-C*H*C'
            alpha = -H*C'*u
            @test H ≈ H' rtol=1e-14
            @test K ≈ K' rtol=1e-14
            @test minimum(eigvals(Symmetric(K))) > 0
            @test alpha[setdiff(1:n, active)] == zeros(n-length(active))
            @test norm((B*alpha+C'*u)[active]) < 2e-14
            # Condensed quadratic energy equals the unreduced augmented
            # energy evaluated at its stationary internal coordinates.
            @test dot(u,K*u) ≈ dot(u,A*u)+2dot(u,C*alpha)+dot(alpha,B*alpha) rtol=2e-14
            for j in active
                delta = zeros(n);delta[j]=.1
                energy = dot(u,A*u)+2dot(u,C*(alpha+delta))+dot(alpha+delta,B*(alpha+delta))
                @test energy > dot(u,K*u)
            end
        end
        @test Q4AM.q4_internal_mode_compliance(B, ones(n)) ≈ inv(B)
        @test Q4AM.q4_internal_mode_compliance(B, fill(.37,n)) ≈ .37inv(B)
        # Nonuniform fractions are a convex blend of nested active energies.
        w = [i==1 ? 0. : i==2 ? .2 : i==3 ? .7 : 1. for i in 1:n]
        H = Q4AM.q4_internal_mode_compliance(B,w)
        expected = .2Q4AM.q4_internal_mode_compliance(B,Float64.(w.>=.2)) +
                   .5Q4AM.q4_internal_mode_compliance(B,Float64.(w.>=.7)) +
                   .3Q4AM.q4_internal_mode_compliance(B,Float64.(w.>=1.))
        @test H ≈ expected
        @test minimum(eigvals(Symmetric(A-C*H*C'))) > 0
    end
    # An unused zero-energy mode must not make an otherwise valid active
    # condensation singular. The former full inverse fails this condition.
    B = Matrix(Diagonal([0., 2., 3., 0.]))
    @test Q4AM.q4_internal_mode_compliance(B,(0.,1.,1.,0.)) == Diagonal([0.,.5,1/3,0.])
    @test_throws ArgumentError Q4AM.q4_internal_mode_compliance(B,(0.,NaN,1.,0.))
end

@testset "Anisotropic Q4 active modes preserve reciprocal energy and AD" begin
    shapes = ([0. 0.; 2. 0.; 2. 1.; 0. 1.],
              [0. 0.; 2. 0.; 2.4 1.; .4 1.],
              [0. 0.; 2. 0.; 1.7 1.; .2 1.])
    Cm = [1.1e9 2e8 5e7; 2e8 7e8 3e7; 5e7 3e7 3e8]
    h=.01; E=1.1e11; w=(0.,1.,1.,0.)
    kw=(bend_ratio=0., k6rot=0., membrane_shear_center_row=true,
        membrane_incomp_center_jacobian=true, kernel_mode="macneal")
    for x in shapes
        kernel(C; weights=w, enabled=true) = Q4AM.stiffness_quad4_matrices(x,C,zeros(eltype(C),3,3),zeros(eltype(C),2,2),h,E;
            kw...,membrane_incomp=enabled,membrane_incomp_weights=weights)
        K = kernel(Cm)
        @test norm(K-K')/norm(K) < 1e-13
        @test minimum(eigvals(Symmetric(K)))/norm(K) > -1e-13
        @test norm(kernel(Cm;weights=(0.,0.,0.,0.))-kernel(Cm;enabled=false))/norm(K) < 1e-14
        for pattern in ([1.,0.,0.], [0.,1.,0.], [0.,0.,1.])
            q=zeros(24)
            for i in 1:4
                q[6(i-1)+1] = pattern[1]-pattern[3]*x[i,2]
                q[6(i-1)+2] = pattern[2]+pattern[3]*x[i,1]
            end
            @test norm(K*q)/norm(K) < 2e-14
        end
        # Constitutive AD must traverse the same active inverse as the primal.
        direction = [2e8 3e7 -1e7;3e7 -1e8 2e7;-1e7 2e7 4e7]
        q=sin.(collect(1.:24.))
        value(t)=dot(q,kernel(Cm+t*direction)*q)
        ad=Q4ActiveModeTestHarness.ForwardDiff.derivative(value,0.)
        fd=(value(1e-5)-value(-1e-5))/(2e-5)
        @test ad ≈ fd rtol=2e-8
        # Recovered internal modes produce the same physical nodal force.
        N,_,area=Q4AM.quad4_membrane_force_field(x,q,E,.3,h;Cm_override=Cm,
            membrane_shear_center_row=true,membrane_incomp_center_jacobian=true,mode_weights=w)
        f=zeros(24);g=inv(sqrt(3.)); points=((-g,-g),(g,-g),(g,g),(-g,g))
        dr0=[-.25,.25,.25,-.25];ds0=[-.25,-.25,.25,.25]
        center=([dr0';ds0']*x)\[dr0';ds0']
        for (j,(r,s)) in enumerate(points)
            dr=[-(1-s),(1-s),(1+s),-(1+s)]/4
            ds=[-(1-r),-(1+r),(1+r),(1-r)]/4
            d=([dr';ds']*x)\[dr';ds']
            B=zeros(3,24)
            for i in 1:4
                B[1,6(i-1)+1]=d[1,i];B[2,6(i-1)+2]=d[2,i]
                B[3,6(i-1)+1]=center[2,i];B[3,6(i-1)+2]=center[1,i]
            end
            f+=area[j]*B'*N[j,:]
        end
        @test norm(f-K*q)/norm(K*q) < 2e-12
    end
end
