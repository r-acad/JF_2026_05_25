using Test,OpenJFEM,LinearAlgebra,Random,StaticArrays,ForwardDiff
module CornerNormalPhysicsFixture
using Test,OpenJFEM,LinearAlgebra,Random,StaticArrays,ForwardDiff
const F=OpenJFEM.FEM;const S=OpenJFEM.Solver
const C=((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))
shape(r,s)=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]/4
function gradients(xy,r,s)
    natural=ForwardDiff.jacobian(v->shape(v...),[r,s])'
    (natural*xy)\natural
end
# Direct virtual-displacement equations, independent of the production maps.
function oracle(xy,xyz,pq,u)
    n=cross(xyz[3,:]-xyz[1,:],xyz[4,:]-xyz[2,:]);n/=norm(n)
    z=(xyz.-sum(xyz,dims=1)/4)*n;v=copy(u)
    for i=1:4
        b=6(i-1);g=gradients(xy,C[i]...);w=u[3:6:24]
        v[b+1]+=z[i]*dot(g[1,:],w);v[b+2]+=z[i]*dot(g[2,:],w)
        if pq[i,3]<=0
            a,c=isodd(i) ? (1,3) : (2,4);dx,dy=xy[c,:]-xy[a,:]
            spin=(dx*(u[6c-4]-u[6a-4])-dy*(u[6c-5]-u[6a-5]))/(dx^2+dy^2)
            gx,gy=g*z;v[b+4]+=gx*(u[b+6]-spin);v[b+5]+=gy*(u[b+6]-spin)
        end
    end
    result=copy(v)
    for i=1:4
        pq[i,3]>0 || continue
        b=6(i-1);g=gradients(xy,C[i]...);p,q=pq[i,1:2]
        spin=(dot(g[1,:],v[2:6:24])-dot(g[2,:],v[1:6:24]))/2
        result[b+4]-=p*(v[b+6]-spin);result[b+5]-=q*(v[b+6]-spin)
        result[b+6]+=p*(v[b+4]-dot(g[2,:],v[3:6:24]))+q*(v[b+5]+dot(g[1,:],v[3:6:24]))
    end
    result
end
function checks()
    rng=MersenneTwister(428617);I24=Matrix{Float64}(I,24,24)
    A=[30. 4. 1.;4. 12. -.5;1. -.5 5.];D=[.7 .08 .03;.08 .3 -.02;.03 -.02 .15]
    B=.015A;Cs=[9. 1.2;1.2 4.];h=.2
    for sample=1:20
        xy=[-1. -.6;1. -.6;1. .6;-1. .6]+.1randn(rng,4,2)
        xyz=hcat(xy,(.002+.03rand(rng))*[1.,-1.,1.,-1.])
        pq=hcat(.05randn(rng,4,2),ones(4))
        sample%3==0 && (pq[2,3]=0.)
        sample%4==0 && (pq[:,1:2].=0.) # Accepted aligned rows remain meaningful.
        P=F.quad4_snorm_corner_warp_map(xy,xyz,pq)
        expected=hcat([oracle(xy,xyz,pq,I24[:,j]) for j=1:24]...)
        @test isapprox(P,expected;rtol=2e-13,atol=2e-14)
        @test F.quad4_snorm_corner_warp_map(xy,xyz,pq[:,1:2])===nothing
        @test F.quad4_snorm_corner_warp_map(xy,xyz,zeros(4,3))===nothing
        @test F.quad4_snorm_corner_warp_map(xy,hcat(xy,zeros(4)),pq)===nothing
        K0=F.stiffness_quad4_matrices(xy,A,D,Cs,h,150.;Bmb=B,kernel_mode="macneal",k6rot=0.,bending_incomp=true)
        K=F.stiffness_quad4_matrices(xy,A,D,Cs,h,150.;Bmb=B,kernel_mode="macneal",k6rot=0.,bending_incomp=true,coords_3d=xyz,snorm_pq=pq)
        @test isapprox(K,expected'*K0*expected;rtol=5e-12,atol=2e-12)
        @test norm(K-K')<2e-12norm(K)
        @test minimum(eigvals(Symmetric(K)))>-1e-12norm(K)
        for axis in eachcol(Matrix{Float64}(I,3,3))
            u=vcat([vcat(cross(axis,xyz[i,:]),axis) for i=1:4]...)
            @test norm(K*u)<3e-12norm(K)*norm(u)
        end
        u=.01randn(rng,24);v=randn(rng,24)
        @test isapprox(dot(v,K*u),dot(expected*v,K0*(expected*u));rtol=3e-12,atol=3e-12)
        fields=F.quad4_condensed_section_fields(xy,u,A,B,D,Cs,h,150.;coords_3d=xyz,snorm_pq=pq,kernel_mode="macneal",k6rot=0.)
        flat=F.quad4_condensed_section_fields(xy,expected*u,A,B,D,Cs,h,150.;kernel_mode="macneal",k6rot=0.)
        @test isapprox(fields.N,flat.N;rtol=2e-12,atol=2e-13)
        @test isapprox(fields.M,flat.M;rtol=2e-12,atol=2e-13)
        @test isapprox(fields.section_force,expected'*flat.section_force;rtol=3e-12,atol=2e-13)
        @test isapprox(fields.projected_displacement,expected*u;rtol=2e-12,atol=2e-13)
        offset=.02
        Cmap=S.shell_projected_reference_offset_map(xy,xyz,offset;snorm_pq=pq)
        Z=S.shell_reference_offset_transform!(copy(I24),offset)
        @test isapprox(P*Cmap,Z*P;rtol=3e-12,atol=3e-12)
        derivative=ForwardDiff.derivative(t->begin
            k=F.stiffness_quad4_matrices(xy,A*(1+.2t),D*(1+.3t),Cs*(1+.4t),h,150.;Bmb=B*(1+.1t),kernel_mode="macneal",k6rot=0.,coords_3d=xyz,snorm_pq=pq)
            dot(v,k*u)
        end,0.)
        response(t)=dot(v,F.stiffness_quad4_matrices(xy,A*(1+.2t),D*(1+.3t),Cs*(1+.4t),h,150.;Bmb=B*(1+.1t),kernel_mode="macneal",k6rot=0.,coords_3d=xyz,snorm_pq=pq)*u)
        @test isapprox(derivative,(response(1e-5)-response(-1e-5))/2e-5;rtol=2e-7,atol=1e-9)
    end
    # Corner geometry is an exact tangent of the bilinear graph, covariant
    # under rigid rotations and independent of the mean-plane approximation.
    xyz=[0. 0. .02;1. 0. -.02;1. 1. .02;0. 1. -.02]
    model=Dict("CSHELLs"=>Dict("1"=>Dict("NODES"=>[1,2,3,4])),"PARAM_SNORM"=>20.)
    ids=Dict(i=>i for i=1:4);normals=S.compute_snorm_normals(model,ids,xyz)
    Q=Matrix(qr(randn(rng,3,3)).Q);det(Q)<0 && (Q[:,1].*=-1)
    rotated=S.compute_snorm_normals(model,ids,xyz*Q')
    for i=1:4
        tangent=cross(xyz[mod1(i+1,4),:]-xyz[i,:],xyz[mod1(i-1,4),:]-xyz[i,:]);tangent/=norm(tangent)
        @test isapprox(normals[i],tangent;rtol=2e-14,atol=2e-14)
        @test isapprox(rotated[i],Q*normals[i];rtol=2e-14,atol=2e-14)
    end
end
end
@testset "Corner surface normals preserve shell virtual work" begin
    CornerNormalPhysicsFixture.checks()
end
