using Test, LinearAlgebra, OpenJFEM

@testset "Reference offsets precede projected shell equilibrium maps" begin
    fk=OpenJFEM.FEM
    solver=OpenJFEM.Solver
    xy=[-.5 -.3; .5 -.3; .5 .3; -.5 .3]
    I24=Matrix{Float64}(I,24,24)
    Z(z)=solver.shell_reference_offset_transform!(copy(I24),z)
    function projected(xy,xyz,pq)
        W=fk.quad4_finite_warp_displacement_map(xy,xyz)
        W===nothing && (W=copy(I24))
        relative=pq===nothing ? nothing : fk.quad4_snorm_relative_to_finite_warp_pq(pq,W)
        S=relative===nothing ? nothing : fk.quad4_snorm_normal_moment_displacement_map(xy,relative)
        return S===nothing ? W : S*W
    end
    rigid=zeros(24,6)
    for i in 1:4
        x,y=xy[i,:];b=6(i-1)
        rigid[b+1:b+3,1:3]=Matrix{Float64}(I,3,3)
        rigid[b+1:b+3,4:6]=[0. 0. -y;0. 0. x;y -x 0.]
        rigid[b+4:b+6,4:6]=Matrix{Float64}(I,3,3)
    end
    L=I24-rigid*pinv(rigid)
    A=reshape(sin.(collect(1.:576.)),24,24)+3I
    K0=L'*(A'*A)*L
    u=cos.(collect(1.:24.));v=sin.(collect(1.:24.))
    pq=[.02 -.01;-.01 .015;.01 .025;-.02 -.015]
    for height in (0.,.006,-.006), director in (nothing,pq), offset in (.002,-.003)
        xyz=hcat(xy,height.*[1.,-1.,1.,-1.])
        P=projected(xy,xyz,director)
        C=solver.shell_projected_reference_offset_map(xy,xyz,offset;snorm_pq=director)
        @test C!==nothing
        @test P*C ≈ Z(offset)*P rtol=2e-13 atol=2e-13
        K=P'*K0*P
        expected=P'*Z(offset)'*K0*Z(offset)*P
        @test C'*K*C ≈ expected rtol=2e-13 atol=2e-13
        @test dot(C*v,K*(C*u)) ≈ dot(v,expected*u) rtol=2e-13 atol=2e-13
        @test dot(u,C'*K*C*u) >= -1e-12
        opposite=solver.shell_projected_reference_offset_map(xy,xyz,-offset;snorm_pq=director)
        @test C*opposite ≈ I24 rtol=2e-13 atol=2e-13
        @test solver.shell_projected_reference_offset_map(xy,xyz,0.;snorm_pq=director)===nothing
        if height==0. && director===nothing
            @test C ≈ Z(offset) rtol=2e-14 atol=2e-14
        end
        # Rigid rotations at the actual GRID surface remain zero energy.
        actual=copy(rigid)
        for i in 1:4
            z=xyz[i,3];b=6(i-1)
            actual[b+1,5]=z
            actual[b+2,4]=-z
        end
        @test norm(C'*K*C*actual) <= 2e-12*norm(K)*norm(actual)
        # A common change of physical units preserves the dimensionless map
        # under the corresponding translation/rotation DOF congruence.
        scale=7.3;units=Diagonal(repeat([scale,scale,scale,1.,1.,1.],4))
        scaled=solver.shell_projected_reference_offset_map(scale*xy,scale*xyz,scale*offset;snorm_pq=director)
        @test scaled ≈ units*C/units rtol=2e-13 atol=2e-13
        angle=.43;Q=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]*
                    [cos(.31) 0. sin(.31);0. 1. 0.;-sin(.31) 0. cos(.31)]
        transformed=xyz*Q'.+permutedims([3.,-7.,2.])
        shifted=solver.shell_projected_reference_offset_map(xy,transformed,offset;snorm_pq=director)
        @test shifted ≈ C rtol=2e-13 atol=2e-13
    end
end
