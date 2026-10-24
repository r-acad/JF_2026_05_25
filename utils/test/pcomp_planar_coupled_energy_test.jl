using Test

module PcompPlanarCoupledEnergyFixture
using Test, LinearAlgebra, OpenJFEM
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

function checks()
    A=[30. 4. 1.;4. 12. -.5;1. -.5 5.]
    D=[.7 .08 .03;.08 .3 -.02;.03 -.02 .15]
    B=.007A;Cs=[9. 1.2;1.2 4.];h=.2
    shapes=([-1. -.5;1. -.5;1. .5;-1. .5],
            [-1. -.5;1. -.5;1.3 .5;-.7 .5],
            [-1. -.5;1. -.5;.7 .5;-.8 .5])
    kernel(X,A,B,D,Cs)=F.stiffness_quad4_matrices(X,A,D,Cs,h,150.;
        Bmb=B,coupled_projected=true,kernel_mode="macneal",k6rot=100.)
    for X in shapes
        @test F.quad4_has_positive_jacobians(X)
        @test S.coupled_pcomp_projected_enabled(X,B;is_pcomp=true)
        @test !S.coupled_pcomp_projected_enabled(X,nothing;is_pcomp=true)
        K=kernel(X,A,B,D,Cs); ev=eigvals(Symmetric(K))
        @test minimum(ev) > -1e-12*maximum(abs,ev)
        @test norm(K-K') < 1e-13*norm(K)
        area=abs(sum(X[i,1]*X[mod1(i+1,4),2]-X[i,2]*X[mod1(i+1,4),1] for i in 1:4))/2
        for axis in 1:3, rotation in (false,true)
            u=zeros(24);e=zeros(3);e[axis]=1.
            for i in 1:4
                u[6i-5:6i-3]=rotation ? cross(e,[X[i,1],X[i,2],0.]) : e
                rotation && (u[6i-2:6i]=e)
            end
            @test norm(K*u) < 1e-12*norm(K)*norm(u)
        end
        for eps in ([1.,0.,0.],[0.,1.,0.],[0.,0.,1.],[.3,-.7,.4])
            u=zeros(24)
            for i in 1:4
                x,y=X[i,:];u[6i-5]=eps[1]*x+eps[3]*y/2;u[6i-4]=eps[2]*y+eps[3]*x/2
            end
            @test isapprox(dot(u,K*u),area*dot(eps,A*eps);rtol=2e-13)
        end
        # Renumbering must commute with changing the element/material basis.
        for shift in 1:3
            perm=circshift(collect(1:4),shift);dofs=vcat([collect(6i-5:6i) for i in perm]...)
            c=round(cos(-shift*pi/2));s=round(sin(-shift*pi/2));Q=[c -s;s c]
            C=[c^2 s^2 -c*s;s^2 c^2 c*s;2c*s -2c*s c^2-s^2]
            R=zeros(6,6);R[1:2,1:2]=Q;R[3,3]=1;R[4:5,4:5]=Q;R[6,6]=1
            T=kron(Matrix{Float64}(I,4,4),R)
            kp=kernel(X[perm,:]*Q,C'*A*C,C'*B*C,C'*D*C,Q'*Cs*Q)
            @test isapprox(kp,T'*K[dofs,dofs]*T;rtol=1e-12)
        end
        u=.01sin.(collect(1.:24.))
        recovered=F.stress_strain_quad4(X,u,150.,.3,h,h;
            Cm_override=A,Cb_override=D,Bmb_override=B,Cs_override=Cs,coupled_projected=true)
        @test recovered[3] ≈ F.quad4_macneal_mean_shear_resultant(X,u,D,Cs,h;Cm=A,Bmb=B)
        fields=F.quad4_coupled_projected_fields(X,u,A,B,D)
        @test recovered[1] ≈ fields.N_center
        @test recovered[2] ≈ -fields.M_center
    end
    folded=[-1. -.5;1. -.5;-.8 .5;.7 .5]
    @test !F.quad4_has_positive_jacobians(folded)
    @test_throws ArgumentError kernel(folded,A,B,D,Cs)
    xyz=hcat(shapes[3],zeros(4));xyz[3,3]=.01
    @test S.coupled_pcomp_projected_enabled(shapes[3],B;is_pcomp=true,coords_3d=xyz)

    mktempdir() do dir
        deck=joinpath(dir,"coupled_trapezoid.bdf")
        write(deck,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,.7,.5,0.
GRID,4,,-.7,.5,0.
CQUAD4,1,10,1,2,3,4
MAT8,1,1.0E7,7.0E6,.25,3.0E6,2.0E6,1.3E6,1000.
PCOMP,10
+,1,.05,0.,YES,1,.05,45.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(deck);ids=Dict(i=>i for i in 1:4)
        xy=[-1. -.5;1. -.5;.7 .5;-.7 .5];X=hcat(xy,zeros(4))
        R=[Matrix{Float64}(I,3,3) for _ in 1:4];normals=S.compute_snorm_normals(model,ids,X)
        u=.001sin.(collect(1.:24.)); output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[])
            for key in ("forces","forces_bilin","stresses","strains"))
        S.recover_shell_stresses!(model,ids,X,R,u,normals,Dict{Int,Float64}(),output)
        @test output["recovery_diagnostics"]["area_mean_transverse_shear_eids"] == [1]
        prop=model["PSHELLs"]["10"]
        q=F.quad4_macneal_mean_shear_resultant(xy,u,prop["Cb"],prop["Cs"],prop["T"];Cm=prop["Cm"],Bmb=prop["Bmb"])
        row=only(output["forces"]["quad4"])
        @test [row["qx"],row["qy"]] ≈ q rtol=1e-10
    end
end
end

@testset "Flat convex coupled laminate energy and recovery" begin
    # This test exercises the optional projected formulation explicitly.
    withenv("JFEM_PCOMP_COUPLED_PROJECTED"=>"true",
            "JFEM_SOL105_PCOMP_MEMBRANE_SELC"=>"true") do
        PcompPlanarCoupledEnergyFixture.checks()
    end
end
