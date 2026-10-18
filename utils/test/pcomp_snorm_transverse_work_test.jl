using Test
module PcompSnormTransverseWorkFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver;const F=S.FEM;const AD=S.ForwardDiff
const WD=[3,9,15,21]
shape(rs)=[(1-rs[1])*(1-rs[2]),(1+rs[1])*(1-rs[2]),(1+rs[1])*(1+rs[2]),(1-rs[1])*(1+rs[2])]/4
function gradient(xy,w,r,s)
    J=AD.jacobian(t->xy'*shape(t),[r,s]);dn=AD.jacobian(shape,[r,s])
    J'\(dn'*w)
end
function energy(w,xy,stress,h;tied=true)
    p=1/sqrt(3.);value=zero(w[1])
    for(q,(r,s)) in enumerate(((-p,-p),(p,-p),(p,p),(-p,p)))
        J=AD.jacobian(t->xy'*shape(t),[r,s])
        gx=gradient(xy,w,tied ? 0. : r,s)[1]
        gy=gradient(xy,w,r,tied ? 0. : s)[2]
        value+=h*abs(det(J))/2*(stress[q,1]*gx^2+stress[q,2]*gy^2+2stress[q,3]*gx*gy)
    end
    value
end
function fixture(dir,Q;warp=1.,snorm=20.)
    xyz=zeros(16,3);text="SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,$snorm\nPARAM,K6ROT,1.\n"
    for j=0:3,i=0:3
        n=4j+i+1;x=.6i+.15j+.02i*j;y=.5j+.025i
        xyz[n,:]=[x,y,warp*(.003x*x+.002x*y)]
        text*="GRID,$n,,"*join(Q*xyz[n,:],",")*"\n"
    end
    for j=0:2,i=0:2
        n=4j+i+1;e=3j+i+1;text*="CQUAD4,$e,10,$n,$(n+1),$(n+5),$(n+4),17.\n"
    end
    text*="MAT8,1,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.\nPCOMP,10,-.001\n+,1,.002,0.,YES\nENDDATA\n"
    path=joinpath(dir,"synthetic_snorm.bdf");write(path,text);m=OpenJFEM.bdf_to_model(path)
    ids=Dict(i=>i for i=1:16);X=xyz*Q';R=[Matrix{Float64}(I,3,3) for _=1:16]
    normals=S.compute_snorm_normals(m,ids,X)
    mapping=S.assemble_constraints(m,ids,X,R,Int[],Int[],Float64[])[1]
    u=zeros(96)
    for i=1:16
        x,y=xyz[i,1:2];u[6(i-1)+1:6(i-1)+3]=Q*[-1e-4x+.6e-4y,.3e-4y,0.]
    end
    captured=Dict{Int,Any}()
    callback=function(e,c)
        names=(:Kg_global,:T_buf,:lc_buf4,:coords3d_local_buf4,:snorm_pq_kg,:warp_map_for_snorm_kg,
            :sigma_mem_input,:h,:kg_flat_uncoupled_pcomp_assumed,:kg_trans_mode_eff,:elem_is_flat_kg,
            :curvature_membrane,:slope_membrane_kg,:kg_curvature,:apply_finite_warp_kg,:elem_mitc4_3d_kg_recovery,
            :snorm_completion_active_kg,:elem_snorm_curvature_kg,:use_geom_snorm_kg)
        captured[e]=Dict(k=>deepcopy(c[k]) for k in names if haskey(c,k))
    end
    G=S.assemble_geometric_stiffness(m,ids,X,R,96,u,normals,mapping;geometric_capture=callback)
    G,captured
end
function work_checks(c;normals=true)
    @test c[:elem_is_flat_kg]
    @test normals ? c[:snorm_pq_kg]!==nothing && norm(c[:snorm_pq_kg])>1e-5 : c[:snorm_pq_kg]===nothing
    @test c[:kg_flat_uncoupled_pcomp_assumed]
    @test c[:kg_trans_mode_eff]===:principal_transverse
    @test c[:curvature_membrane]===nothing && c[:slope_membrane_kg]===nothing
    xy=c[:lc_buf4];stress=c[:sigma_mem_input];h=c[:h]
    stress=stress isa AbstractVector ? repeat(stress',4,1) : stress
    W=F.quad4_finite_warp_displacement_map(xy,c[:coords3d_local_buf4])
    W=W===nothing ? Matrix{Float64}(I,24,24) : W
    P=W*c[:T_buf]
    if c[:snorm_pq_kg]!==nothing
        pq=F.quad4_snorm_relative_to_finite_warp_pq(c[:snorm_pq_kg],c[:warp_map_for_snorm_kg])
        P=F.quad4_snorm_normal_moment_displacement_map(xy,pq)*P
    end
    V=Matrix{Float64}(I,24,24)[:,WD];physical=P\V
    actual=physical'*c[:Kg_global]*physical
    expected=AD.hessian(w->energy(w,xy,stress,h),zeros(4))
    bilinear=AD.hessian(w->energy(w,xy,stress,h;tied=false),zeros(4))
    @test actual≈expected rtol=2e-10 atol=2e-9
    @test norm(expected-bilinear)>1e-5norm(expected) # The old skipped branch fails this fixture.
    w=[.3,-.2,.6,.1];q=physical*w
    @test dot(q,c[:Kg_global]*q)/2≈energy(w,xy,stress,h) rtol=2e-10 atol=2e-9
    @test norm(actual-actual')<2e-12norm(actual)
    @test norm(actual*ones(4))<2e-11norm(actual)
end
function checks()
    mktempdir() do dir
        base,cells=fixture(dir,Matrix{Float64}(I,3,3));work_checks(cells[5])
        ax=.37;az=.61;Q=[cos(az) -sin(az) 0.;sin(az) cos(az) 0.;0. 0. 1.]*[1. 0. 0.;0. cos(ax) -sin(ax);0. sin(ax) cos(ax)]
        rotated,rcells=fixture(dir,Q);work_checks(rcells[5]);Qall=kron(Matrix{Float64}(I,32,32),Q)
        @test norm(rotated-Qall*base*Qall')<3e-10norm(base)
        _,zero=fixture(dir,Matrix{Float64}(I,3,3);snorm=0.)
        work_checks(zero[5];normals=false)
        # These research paths retain their earlier eligibility; the new
        # normal-moment extension must not silently enable them.
        for setting in ("JFEM_SNORM_DIRECTOR"=>"true","JFEM_Q4_SNORM_TRANSFORM_ONLY"=>"true")
            withenv(setting) do
                _,c=fixture(dir,Matrix{Float64}(I,3,3))
                t=c[5]
                prior=t[:elem_is_flat_kg] && t[:snorm_pq_kg]===nothing &&
                    !t[:snorm_completion_active_kg] && !t[:elem_snorm_curvature_kg] &&
                    !t[:use_geom_snorm_kg] && t[:curvature_membrane]===nothing && t[:slope_membrane_kg]===nothing
                @test t[:kg_flat_uncoupled_pcomp_assumed]==prior
            end
        end
        withenv("JFEM_Q4_MARGUERRE_COUPLING"=>"true") do
            _,c=fixture(dir,Matrix{Float64}(I,3,3))
            @test c[5][:slope_membrane_kg]!==nothing
            @test !c[5][:kg_flat_uncoupled_pcomp_assumed]
        end
        withenv("JFEM_KG_SHELL_TRANS_DOF_MODE"=>"curvature") do
            _,c=fixture(dir,Matrix{Float64}(I,3,3))
            @test c[5][:kg_trans_mode_eff]!==:principal_transverse
        end
        _,strong=fixture(dir,Matrix{Float64}(I,3,3);warp=100.)
        @test !strong[5][:elem_is_flat_kg]
        @test !strong[5][:kg_flat_uncoupled_pcomp_assumed]
    end
end
@testset "Anisotropic projected SNORM transverse work" begin
    checks()
end
end
