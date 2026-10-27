using Test
module OffsetReferenceWorkFixture
using Test,LinearAlgebra,Random,ForwardDiff,OpenJFEM
const F=OpenJFEM.FEM; const S=OpenJFEM.Solver
const GP=((-1/sqrt(3.),-1/sqrt(3.)),(1/sqrt(3.),-1/sqrt(3.)),
          (1/sqrt(3.),1/sqrt(3.)),(-1/sqrt(3.),1/sqrt(3.)))

function gradient(x,r,s)
    d=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]./4
    J=d*x
    return J\d,abs(det(J))
end

function strain_curvature(x,v)
    d0,_=gradient(x,0.,0.)
    shear=dot(d0[2,:],v[1:6:24])+dot(d0[1,:],v[2:6:24])
    twist0=dot(d0[2,:],v[5:6:24])-dot(d0[1,:],v[4:6:24])
    eps=zeros(eltype(v),4,3);kap=similar(eps);twists=zeros(eltype(v),4);weights=zeros(4)
    for (i,(r,s)) in enumerate(GP)
        d,weights[i]=gradient(x,r,s)
        eps[i,:]=[dot(d[1,:],v[1:6:24]),dot(d[2,:],v[2:6:24]),shear]
        twists[i]=dot(d[2,:],v[5:6:24])-dot(d[1,:],v[4:6:24])
        kap[i,:]=[dot(d[1,:],v[5:6:24]),-dot(d[2,:],v[4:6:24]),2twists[i]-twist0]
    end
    return eps,kap,weights,twists,twist0
end

# Independent initial-stress energy, using the ordinary in-plane component
# strings and tied transverse slopes. No production geometric matrix is used.
function geometric_energy(x,N,v)
    total=zero(eltype(v))
    for (i,(r,s)) in enumerate(GP)
        d,w=gradient(x,r,s);dx,_=gradient(x,0.,s);dy,_=gradient(x,r,0.)
        ux=dot(d[1,:],v[1:6:24]);uy=dot(d[2,:],v[1:6:24])
        vx=dot(d[1,:],v[2:6:24]);vy=dot(d[2,:],v[2:6:24])
        wx=dot(dx[1,:],v[3:6:24]);wy=dot(dy[2,:],v[3:6:24])
        nxx,nyy,nxy=N[i,:]
        total+=w*(nyy*uy^2+nxx*vx^2+nxy*(ux*uy+vx*vy-ux*vx-uy*vy)+
                  nxx*wx^2+nyy*wy^2+2nxy*wx*wy)
    end
    total
end

function checks()
    x=[-.7 -.3;.6 -.4;.8 .5;-.5 .6]
    A=[170. 23. 7.;23. 121. -4.;7. -4. 48.]
    B=[.23 -.11 .03;-.11 .37 -.02;.03 -.02 .08]
    rng=MersenneTwister(208451)
    u=randn(rng,24);v=randn(rng,24);I24=Matrix{Float64}(I,24,24)
    for height in (0.,.031,-.027), b in (nothing,zeros(3,3),B), z in (-.019,.014)
        xyz=hcat(x,height.*[1.,-1.,1.,-1.])
        W=F.quad4_finite_warp_displacement_map(x,xyz)
        W===nothing && (W=copy(I24))
        p=W*u;eps,kap,weights,twists,twist0=strain_curvature(x,p)
        b0=b===nothing ? zeros(3,3) : b
        expected=eps*A'+kap*(b0+z*A)'
        N,meanN,w=F.quad4_reference_section_membrane_force_field(x,u,A,b,z;coords_3d=xyz)
        @test N≈expected rtol=4e-13 atol=4e-12
        @test meanN≈vec(expected'*weights/sum(weights)) rtol=4e-13 atol=4e-12
        @test w≈weights rtol=3e-14
        # Exact zero leaves every prior output bit unchanged, including B=nothing.
        zeroed=F.quad4_reference_section_membrane_force_field(x,u,A,b,0.;coords_3d=xyz)
        prior=F.quad4_differential_membrane_force_field(x,u,A,b;coords_3d=xyz)
        @test all(isequal(zeroed[i],prior[i]) for i=1:3)

        # Changing section origin and nodal offset in opposite directions
        # preserves the GRID-reference section, without tuning a factor.
        shift=.043
        rebased=F.quad4_reference_section_membrane_force_field(x,u,A,b0-shift*A,z+shift;coords_3d=xyz)
        @test rebased[1]≈N rtol=4e-13 atol=4e-12
        Z=S.shell_reference_offset_transform!(copy(I24),z)
        old=F.quad4_differential_membrane_force_field(x,Z*p,A,b)
        exact_difference=(2*z).*(twist0 .- twists)*permutedims(A[:,3])
        @test old[1]-N≈exact_difference rtol=2e-12 atol=3e-12
        @test norm(exact_difference)>1e-5

        G=F.geometric_stiffness_quad4(x,N,1.;trans_mode=:principal_transverse)
        F.add_quad4_assumed_transverse_gradient_delta!(G,x,N,1.)
        physical=W'*G*W
        @test physical≈physical' rtol=3e-14 atol=3e-12
        expected_work=(geometric_energy(x,N,W*(u+v))-geometric_energy(x,N,W*(u-v)))/4
        @test dot(v,physical*u)≈expected_work rtol=6e-13 atol=2e-10
        rotations=[6i+d for i=0:3 for d=4:6]
        @test all(iszero,physical[rotations,:]) && all(iszero,physical[:,rotations])

        scale=4.7;D=Diagonal(repeat([scale,scale,scale,1.,1.,1.],4))
        scaled=F.quad4_reference_section_membrane_force_field(scale*x,D*u,scale*A,
            b===nothing ? nothing : scale^2*b,scale*z;coords_3d=scale*xyz)
        @test scaled[1]≈scale*N rtol=5e-13 atol=2e-11
        angle=.38;Q=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]*
                   [1. 0. 0.;0. cos(.29) -sin(.29);0. sin(.29) cos(.29)]
        transformed=xyz*Q'.+permutedims([2.,-3.,5.])
        covariant=F.quad4_reference_section_membrane_force_field(x,u,A,b,z;coords_3d=transformed)
        @test covariant[1]≈N rtol=8e-13 atol=2e-11
        for omega in eachcol(Matrix{Float64}(I,3,3))
            rigid=zeros(24)
            for i=1:4
                rigid[6i-5:6i-3]=cross(omega,vec(xyz[i,:]))
                rigid[6i-2:6i]=omega
            end
            rigidN=first(F.quad4_reference_section_membrane_force_field(x,rigid,A,b,z;coords_3d=xyz))
            @test norm(rigidN)<=3e-12*norm(A)
        end
        # The new constitutive shift has an exact scalar derivative. Include
        # z=0 so a primal-zero fast path cannot silently erase its tangent.
        for z0 in (0.,z)
            derivative=ForwardDiff.derivative(t->sum(first(
                F.quad4_reference_section_membrane_force_field(x,u,A,b,t;coords_3d=xyz))),z0)
            @test derivative≈sum(kap*A') rtol=4e-13 atol=2e-11
        end
    end

    enabled(;kwargs...)=S.q4_reference_offset_differential_enabled(105,.02;
        merge((projected_offset=true,),(;kwargs...))...)
    @test enabled()
    @test !S.q4_reference_offset_differential_enabled(105,0.;projected_offset=true)
    @test !S.q4_reference_offset_differential_enabled(101,.02;projected_offset=true)
    @test !S.q4_reference_offset_differential_enabled(105,NaN;projected_offset=true)
    for exclusion in ((projected_offset=false,),(finite_warp=false,),(snorm_pq=zeros(4,3),),
        (normal_transform=true,),(curvature=zeros(3),),(slope=zeros(9),),(kernel_mode="mitc4",),
        (alternate_plate=true,),(mid4=true,),(variable_thickness=true,),
        (compatible_membrane=true,),(membrane_selc=true,),(surface_operator=:covariant,),
        (recovery_mode=:covariant,),(trans_mode=:all,),(material_frame=false,),(research=true,))
        @test !enabled(;exclusion...)
    end
end
end
@testset "GRID-reference shell initial-stress work and offset covariance" begin
    OffsetReferenceWorkFixture.checks()
end
