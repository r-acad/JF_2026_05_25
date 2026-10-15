using Test

module PcompWarpedCoupledEnergyFixture
using Test, LinearAlgebra, OpenJFEM, StaticArrays
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

function checks()
    A=[30. 4. 1.;4. 12. -.5;1. -.5 5.]
    D=[.7 .08 .03;.08 .3 -.02;.03 -.02 .15]
    B=.007A;Cs=[9. 1.2;1.2 4.];h=.2
    for xyz in ([-1. -.5 .006;1. -.5 -.006;1. .5 .006;-1. .5 -.006],
                [-1. -.5 .002;1. -.5 -.004;.7 .5 .007;-.8 .5 -.003])
        pts=[SVector{3}(xyz[i,:]) for i=1:4]
        v1,v2,v3=S.shell_element_frame_quad4(pts...,:bisector)
        center=sum(pts)/4
        X=[dot(pts[i]-center,v) for i=1:4,v in (v1,v2)]
        local3d=[dot(pts[i]-center,v) for i=1:4,v in (v1,v2,v3)]
        W=F.quad4_finite_warp_displacement_map(X,xyz)
        @test W !== nothing
        @test S.coupled_pcomp_projected_enabled(X,B;is_pcomp=true,coords_3d=xyz)
        @test !S.coupled_pcomp_projected_enabled(X,nothing;is_pcomp=true,coords_3d=xyz,require_coupling=false)
        @test !S.coupled_pcomp_projected_enabled(X,B;is_pcomp=true,coords_3d=xyz,snorm_pq=ones(4,2))
        @test !withenv("JFEM_Q4_MACNEAL_WARP_TOL"=>"1e-8") do
            S.coupled_pcomp_projected_enabled(X,B;is_pcomp=true,coords_3d=xyz)
        end
        @test !withenv("JFEM_Q4_MACNEAL_ASPECT_MAX"=>"1") do
            S.coupled_pcomp_projected_enabled(X,B;is_pcomp=true,coords_3d=xyz)
        end
        kernel(X,A,B,D,Cs;kw...)=F.stiffness_quad4_matrices(X,A,D,Cs,h,150.;
            Bmb=B,coupled_projected=true,kernel_mode="macneal",k6rot=100.,kw...)
        flat=kernel(X,A,B,D,Cs)
        K=kernel(X,A,B,D,Cs;coords_3d=xyz)
        @test K ≈ W'*flat*W rtol=3e-13
        ev=eigvals(Symmetric(K))
        @test minimum(ev)>-1e-12maximum(abs,ev)
        for axis=1:3,rotation in (false,true)
            e=zeros(3);e[axis]=1;u=zeros(24)
            for i=1:4
                u[6i-5:6i-3]=rotation ? cross(e,local3d[i,:]) : e
                rotation && (u[6i-2:6i]=e)
            end
            @test norm(K*u)<2e-12norm(K)*norm(u)
        end
        # Cyclic numbering with the corresponding in-plane material basis
        # must commute with the same physical finite-warp congruence.
        for shift=1:3
            perm=circshift(collect(1:4),shift);dofs=vcat([collect(6i-5:6i) for i in perm]...)
            c=round(cos(-shift*pi/2));s=round(sin(-shift*pi/2));Q=[c -s;s c]
            C=[c^2 s^2 -c*s;s^2 c^2 c*s;2c*s -2c*s c^2-s^2]
            R=zeros(6,6);R[1:2,1:2]=Q;R[3,3]=1;R[4:5,4:5]=Q;R[6,6]=1
            T=kron(Matrix{Float64}(I,4,4),R)
            kp=kernel(X[perm,:]*Q,C'*A*C,C'*B*C,C'*D*C,Q'*Cs*Q;coords_3d=xyz[perm,:])
            @test kp ≈ T'*K[dofs,dofs]*T rtol=2e-12
        end
        u=.01sin.(collect(1.:24.));up=W*u
        physical=F.quad4_coupled_projected_fields(X,u,A,B,D;coords_3d=xyz)
        projected=F.quad4_coupled_projected_fields(X,up,A,B,D)
        @test physical.N_geometric ≈ projected.N_geometric
        @test physical.N_work ≈ projected.N_work
        @test physical.M_work ≈ projected.M_work
        @test physical.projected_displacement ≈ up
        recovered=F.stress_strain_quad4(X,u,150.,.3,h,h;Cm_override=A,Cb_override=D,
            Bmb_override=B,Cs_override=Cs,coupled_projected=true,coords_3d=xyz)
        @test recovered[1] ≈ projected.N_center
        @test recovered[2] ≈ -projected.M_center
        @test recovered[3] ≈ F.quad4_macneal_mean_shear_resultant(X,up,D,Cs,h;Cm=A,Bmb=B)
        # A coupled MAT8 property remains outside the analytic shell material
        # domain; this primal extension must not silently enable its tangent.
        model=Dict("PSHELLs"=>Dict("1"=>Dict("TYPE"=>"PCOMP_CLT","BEND_RATIO"=>1.,
            "PLY_DATA"=>Any[],"IS_ISOTROPIC"=>false)))
        @test_throws ArgumentError S.analytic_shell_constitutive(model,1)
    end
end
end

@testset "Warped coupled laminate work-dual energy and recovery" begin
    PcompWarpedCoupledEnergyFixture.checks()
end
