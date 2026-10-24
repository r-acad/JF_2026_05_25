using Test

module CoupledQuad4InternalPolicyFixture
using Test, LinearAlgebra, OpenJFEM, JSON, ForwardDiff
const F=OpenJFEM.FEM

matrix(rows)=Float64.(reduce(vcat,permutedims.(rows)))

# Independent integration of the enlarged quadratic sectional energy. These
# polynomial fields are evaluated directly, without the production B builders
# or its internal-mode blocks, before taking the stationary Schur complement.
function energy_reference(x,A,B,D; membrane=false,bending=false)
    derivatives(r,s)=[-(1-s) (1-s) (1+s) -(1+s);
                      -(1-r) -(1+r) (1+r) (1-r)]/4
    dc=derivatives(0.,0.);jc=dc*x;gc=jc\dc
    indices=vcat(collect(1:24),membrane ? collect(25:28) : Int[],bending ? collect(29:32) : Int[])
    H=zeros(32,32);section=[A B;B' D];g=inv(sqrt(3.))
    for r in (-g,g),s in (-g,g)
        dn=derivatives(r,s);jac=dn*x;grad=jac\dn
        fields=zeros(6,32)
        for k in 1:4
            p=6(k-1)
            fields[1,p+1]=grad[1,k];fields[2,p+2]=grad[2,k]
            fields[3,p+1]=grad[2,k];fields[3,p+2]=grad[1,k]
            fields[4,p+5]=grad[1,k];fields[5,p+4]=-grad[2,k]
            fields[6,p+5]=gc[2,k];fields[6,p+4]=-gc[1,k]
        end
        gp=(jc\[-2r 0.;0. -2s])*(det(jc)/det(jac))
        fields[1,25]=gp[1,1];fields[3,25]=gp[2,1]
        fields[2,26]=gp[2,1];fields[3,26]=gp[1,1]
        fields[1,27]=gp[1,2];fields[3,27]=gp[2,2]
        fields[2,28]=gp[2,2];fields[3,28]=gp[1,2]
        bp=(jc\[-2r 0.;0. -2s])*(det(jc)/det(jac))
        fields[5,29]=-bp[2,1];fields[6,29]=-bp[1,1]
        fields[5,30]=-bp[2,2];fields[6,30]=-bp[1,2]
        fields[4,31]=bp[1,1];fields[6,31]=bp[2,1]
        fields[4,32]=bp[1,2];fields[6,32]=bp[2,2]
        H+=abs(det(jac))*fields'*section*fields
    end
    active=indices[25:end]
    isempty(active) ? H[1:24,1:24] :
        H[1:24,1:24]-H[1:24,active]*(H[active,active]\H[active,1:24])
end

function checks()
    fixture=get(ENV,"JFEM_COUPLED_ENERGY_FIXTURE",joinpath(@__DIR__,"..","..","validation","cases","CRM_uCRM9_published","diagnostics","element_energy_fixture.json"))
    data=JSON.parsefile(fixture)
    x=matrix(data["local_coords"]);A=matrix(data["A"]);B=matrix(data["B"])
    D=matrix(data["D"]);S=matrix(data["S"]);h=data["thickness_m"]
    @test minimum(eigvals(Symmetric([A B;B' D])))>0
    # The previous uncoupled D12 surgery turns this rotated section negative.
    altered=copy(D);altered[1,2]=altered[2,1]=0.
    @test minimum(eigvals(Symmetric(altered)))<0
    withenv("JFEM_Q4_BENDING_INCOMP_JAC"=>"qm6",
            "JFEM_Q4_BENDING_INCOMP_DECOUPLE_D12"=>"true",
            "JFEM_Q4_BENDING_INCOMP_DECOUPLE_D16"=>"false",
            "JFEM_Q4_MACNEAL_TWIST_MODE"=>"center") do
        for membrane in (false,true),bending in (false,true)
            kernel(a,b,d; shear=S,drill=1.)=F.stiffness_quad4_matrices(x,a,d,shear,h,1e11;
                Bmb=b,k6rot=drill,kernel_mode="macneal",membrane_incomp=membrane,
                bending_incomp=bending,selective_shear=true,macneal_rigid_shear=false,
                bmb_incomp_coupling_mode=:full)
            K=kernel(A,B,D)
            @test norm(K-K')/norm(K)<1e-13
            @test minimum(eigvals(Symmetric(K)))/opnorm(K)>-1e-12
            # Disable shear/drilling to compare only the independently
            # integrated enlarged [A B; B' D] sectional energy.
            pure=F.stiffness_quad4_matrices(x,A,D,zeros(2,2),h,1e11;
                Bmb=B,k6rot=0.,kernel_mode="macneal",membrane_incomp=membrane,
                bending_incomp=bending,shear_center_only=true,
                bmb_incomp_coupling_mode=:full)
            reference=energy_reference(x,A,B,D;membrane=membrane,bending=bending)
            @test norm(pure-reference)/norm(reference)<2e-12
            q=sin.(collect(1.:24.))
            energy(t)=dot(q,kernel((1+t)*A,(1+t)*B,(1+t)*D)*q)
            ad=ForwardDiff.derivative(energy,0.)
            fd=(energy(1e-5)-energy(-1e-5))/(2e-5)
            @test ad≈fd rtol=2e-7
        end
        # Supplying a zero B matrix must honor both false flags just as
        # omitting the coupling law does: no hidden bending condensation.
        kw=(k6rot=1.,kernel_mode="macneal",membrane_incomp=false,bending_incomp=false,selective_shear=true)
        without=F.stiffness_quad4_matrices(x,A,D,S,h,1e11;kw...)
        zero=F.stiffness_quad4_matrices(x,A,D,S,h,1e11;Bmb=zeros(3,3),kw...)
        @test norm(without-zero)/norm(without)<1e-14
    end
end

function shear_quadrature_checks()
    # MITC tying fields on an affine cell are linear only in their other
    # natural coordinate, so the 1x2/2x1 rules must equal the full 2x2 rule.
    # The analytic constant-shear work also fixes their absolute normalization.
    C=[2. 1.8;1.8 2.]
    for x in ([0. 0.;2. 0.;2. 1.;0. 1.],
              [0. 0.;2. 0.;2.7 1.;.7 1.])
        kernel(;selective=false,mode=:all)=F.stiffness_quad4_matrices(x,zeros(3,3),zeros(3,3),C,.2,1.;
            k6rot=0.,membrane_incomp=false,bending_incomp=false,no_phi2=true,
            kernel_mode="default",selective_shear=selective,selective_shear_mode=mode)
        full=kernel()
        for mode in (:all,:sx_only,:sy_only)
            K=kernel(selective=true,mode=mode)
            @test norm(K-full)/norm(full)<1e-13
            @test minimum(eigvals(Symmetric(K)))/opnorm(K)>-1e-13
            for gradient in ([1.,0.],[0.,1.],[1.,1.])
                q=zeros(24)
                for k in 1:4; q[6(k-1)+3]=dot(x[k,:],gradient); end
                @test dot(q,K*q)≈2dot(gradient,C*gradient) rtol=2e-14
            end
        end
    end
end
end

@testset "Explicit stationary quadrilateral internal-mode policy" begin
    # Retain independent coverage of the optional D/ABD-stationary policy.
    # Production uses A-derived kinematic maps; its physical energy, patch,
    # derivatives and recovery have separate independent tests.
    withenv("JFEM_Q4_SECTION_KINEMATIC_ENRICHMENT"=>"false") do
        CoupledQuad4InternalPolicyFixture.checks()
        CoupledQuad4InternalPolicyFixture.shear_quadrature_checks()
    end
end
