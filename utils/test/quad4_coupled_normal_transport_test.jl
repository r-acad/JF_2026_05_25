using Test
module CoupledNormalWorkFixture
using Test, OpenJFEM, LinearAlgebra
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver
const CORNERS=((-1.0,-1.0),(1.0,-1.0),(1.0,1.0),(-1.0,1.0))

function gradients(xy,r,s)
    dr=0.25 .* [-(1-s),1-s,1+s,-(1+s)]
    ds=0.25 .* [-(1-r),-(1+r),1+r,1-r]
    natural=permutedims(hcat(dr,ds))
    J=natural*xy
    return J\natural,abs(det(J))
end

# Scalar surface and virtual-spin equations, independent of production maps.
function physical_action(xy,xyz,pq,u)
    normal=cross(xyz[3,:]-xyz[1,:],xyz[4,:]-xyz[2,:])
    normal/=norm(normal)
    heights=(xyz.-sum(xyz,dims=1)/4)*normal
    v=copy(u)
    for i in 1:4
        b=6(i-1);d,_=gradients(xy,CORNERS[i]...)
        v[b+1]+=heights[i]*dot(d[1,:],u[3:6:24])
        v[b+2]+=heights[i]*dot(d[2,:],u[3:6:24])
        if pq[i,3]<=0
            a,c=isodd(i) ? (1,3) : (2,4)
            dx,dy=xy[c,:]-xy[a,:]
            spin=(dx*(u[6c-4]-u[6a-4])-dy*(u[6c-5]-u[6a-5]))/(dx^2+dy^2)
            gx,gy=d*heights
            v[b+4]+=gx*(u[b+6]-spin)
            v[b+5]+=gy*(u[b+6]-spin)
        end
    end
    result=copy(v)
    for i in 1:4
        pq[i,3]>0 || continue
        b=6(i-1);d,_=gradients(xy,CORNERS[i]...)
        p,q=pq[i,1:2]
        spin=(dot(d[1,:],v[2:6:24])-dot(d[2,:],v[1:6:24]))/2
        result[b+4]-=p*(v[b+6]-spin)
        result[b+5]-=q*(v[b+6]-spin)
        result[b+6]+=p*(v[b+4]-dot(d[2,:],v[3:6:24]))+
                     q*(v[b+5]+dot(d[1,:],v[3:6:24]))
    end
    return result
end

# The ordinary differential field has compatible normal strains, center
# membrane shear and the MacNeal compatible-twist correction. Elastic
# enrichment is deliberately absent from this independent prestress oracle.
function differential_oracle(xy,u,A,B)
    d0,_=gradients(xy,0.0,0.0)
    gamma=dot(d0[2,:],u[1:6:24])+dot(d0[1,:],u[2:6:24])
    twist0=dot(d0[2,:],u[5:6:24])-dot(d0[1,:],u[4:6:24])
    q=inv(sqrt(3.0));N=zeros(4,3);weights=zeros(4)
    for (j,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
        d,weights[j]=gradients(xy,r,s)
        epsilon=[dot(d[1,:],u[1:6:24]),dot(d[2,:],u[2:6:24]),gamma]
        kappa=[dot(d[1,:],u[5:6:24]),-dot(d[2,:],u[4:6:24]),
               2*(dot(d[2,:],u[5:6:24])-dot(d[1,:],u[4:6:24]))-twist0]
        N[j,:]=A*epsilon+B*kappa
    end
    return N,vec(N'*weights/sum(weights)),weights
end

function checks()
    A=[30.0 4.0 1.0;4.0 12.0 -0.5;1.0 -0.5 5.0]
    B=[0.4 -0.12 0.06;-0.12 -0.22 0.03;0.06 0.03 0.13]
    D=[0.7 0.08 0.03;0.08 0.3 -0.02;0.03 -0.02 0.15]
    Cs=zeros(2,2);h=0.2;E=150.0
    @test minimum(eigvals(Symmetric([A B;B' D])))>0
    I24=Matrix{Float64}(I,24,24)
    shapes=([-1.0 -0.6;1.0 -0.6;1.0 0.6;-1.0 0.6],
            [-1.1 -0.5;0.9 -0.5;1.1 0.5;-0.9 0.5])
    for xy in shapes,field in (:tilted,:aligned,:mixed)
        xyz=hcat(xy,0.023 .* [1.0,-1.0,1.0,-1.0])
        pq=hcat([0.17 -0.08;-0.12 0.09;0.04 0.13;-0.07 -0.11],ones(4))
        field===:aligned && (pq[:,1:2].=0.0)
        field===:mixed && (pq[2,3]=0.0)
        P=hcat([physical_action(xy,xyz,pq,I24[:,j]) for j in 1:24]...)
        @test isapprox(F.quad4_physical_displacement_map(xy,xyz,pq),P;rtol=3e-13,atol=2e-14)
        u=0.003 .* sin.(collect(1.0:24.0));v=0.002 .* cos.(collect(1.0:24.0))
        for offset in (0.0,0.017)
            Z=S.shell_reference_offset_transform!(copy(I24),offset)
            C=P\(Z*P)
            production_offset=S.shell_projected_reference_offset_map(xy,xyz,offset;snorm_pq=pq)
            if iszero(offset)
                @test production_offset===nothing
                C=copy(I24)
            else
                @test isapprox(production_offset,C;rtol=3e-12,atol=3e-14)
            end
            preload=C*u
            oracle=differential_oracle(xy,physical_action(xy,xyz,pq,preload),A,B)
            actual=F.quad4_differential_membrane_force_field(xy,preload,A,B;coords_3d=xyz,snorm_pq=pq)
            @test isapprox(actual[1],oracle[1];rtol=3e-12,atol=2e-14)
            @test isapprox(actual[2],oracle[2];rtol=3e-12,atol=2e-14)
            @test isapprox(actual[3],oracle[3];rtol=3e-14,atol=2e-14)
            # A second application of P is a different physical displacement.
            wrong=differential_oracle(xy,P*(P*preload),A,B)[1]
            @test norm(actual[1]-wrong)>1e-8
        end
        old=F.quad4_differential_membrane_force_field(xy,u,A,B;coords_3d=xyz)
        no_normal=F.quad4_differential_membrane_force_field(xy,u,A,B;coords_3d=xyz,snorm_pq=nothing)
        @test old==no_normal
        for Bzero in (nothing,zeros(3,3))
            ordinary=F.quad4_differential_membrane_force_field(xy,u,A,Bzero;coords_3d=xyz)
            normal=F.quad4_differential_membrane_force_field(xy,u,A,Bzero;coords_3d=xyz,snorm_pq=pq)
            @test ordinary==normal
        end
        # Isolate section energy with zero transverse/drilling penalties.
        options=(coords_3d=xyz,snorm_pq=pq,kernel_mode="macneal",k6rot=0.0,drill_scale=0.0,
                 bending_incomp=true,membrane_incomp=true)
        K=F.stiffness_quad4_matrices(xy,A,D,Cs,h,E;Bmb=B,options...)
        fields=F.quad4_condensed_section_fields(xy,u,A,B,D,Cs,h,E;options...)
        variation=F.quad4_condensed_section_fields(xy,v,A,B,D,Cs,h,E;options...)
        @test isapprox(fields.projected_displacement,P*u;rtol=3e-13,atol=2e-14)
        @test isapprox(fields.N,fields.eps*A'+fields.kappa*B';rtol=2e-13,atol=2e-14)
        @test isapprox(fields.M,fields.eps*B+fields.kappa*D';rtol=2e-13,atol=2e-14)
        @test isapprox(fields.section_force,K*u;rtol=3e-10,atol=2e-12)
        work=sum(fields.weights[i]*(dot(variation.eps[i,:],fields.N[i,:])+
                 dot(variation.kappa[i,:],fields.M[i,:])) for i in 1:4)
        energy=sum(fields.weights[i]*(dot(fields.eps[i,:],fields.N[i,:])+
                   dot(fields.kappa[i,:],fields.M[i,:])) for i in 1:4)
        @test isapprox(work,dot(v,K*u);rtol=3e-10,atol=2e-12)
        @test isapprox(energy,dot(u,K*u);rtol=3e-10,atol=2e-12)
        @test dot(u,K*u)>0
        for omega in eachcol(Matrix{Float64}(I,3,3))
            rigid=vcat([vcat(cross(omega,xyz[i,:]),omega) for i in 1:4]...)
            force=F.quad4_differential_membrane_force_field(xy,rigid,A,B;coords_3d=xyz,snorm_pq=pq)[1]
            @test norm(force)<2e-11*norm(A)*norm(rigid)
            @test norm(K*rigid)<2e-11*norm(K)*norm(rigid)
        end
        # Same mechanics in another length unit (force unit held fixed).
        base=F.quad4_differential_membrane_force_field(xy,u,A,B;coords_3d=xyz,snorm_pq=pq)[1]
        for scale in (0.07,130.0)
            us=copy(u)
            for i in 1:4;us[(6i-5):(6i-3)].*=scale;end
            scaled=F.quad4_differential_membrane_force_field(scale*xy,us,A/scale,B;coords_3d=scale*xyz,snorm_pq=pq)[1]
            @test isapprox(scale*scaled,base;rtol=3e-12,atol=2e-14)
        end
        # Rotate the entire physical frame and pull basic translations,
        # rotations and prescribed normals back to the transported local axes.
        angle=0.63
        Q=[cos(angle) 0.0 sin(angle);0.0 1.0 0.0;-sin(angle) 0.0 cos(angle)]
        rotated_xyz=xyz*Q'
        basic=vcat([vcat(Q*u[(6i-5):(6i-3)],Q*u[(6i-2):6i]) for i in 1:4]...)
        local_u=vcat([vcat(Q'*basic[(6i-5):(6i-3)],Q'*basic[(6i-2):6i]) for i in 1:4]...)
        local_xyz=rotated_xyz*Q
        local_pq=copy(pq)
        for i in 1:4
            basic_normal=Q*[pq[i,1],pq[i,2],1.0]
            local_normal=Q'*basic_normal
            local_pq[i,1:2]=local_normal[1:2]/local_normal[3]
        end
        rotated=F.quad4_differential_membrane_force_field(local_xyz[:,1:2],local_u,A,B;coords_3d=local_xyz,snorm_pq=local_pq)[1]
        @test isapprox(rotated,base;rtol=3e-12,atol=2e-14)
        translated_xy=xy.+[2.7 -1.9]
        translated_xyz=xyz.+[2.7 -1.9 4.3]
        shifted=F.quad4_differential_membrane_force_field(translated_xy,u,A,B;coords_3d=translated_xyz,snorm_pq=pq)[1]
        @test isapprox(shifted,base;rtol=3e-12,atol=2e-14)
    end
end
end
@testset "Coupled normal transport preserves section and differential work" begin
    CoupledNormalWorkFixture.checks()
end
