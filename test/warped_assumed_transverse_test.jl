using Test

module WarpedAssumedTransverseFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM
const AD=S.ForwardDiff

function local_geometry(xyz)
    pts=[SVector{3}(xyz[i,:]) for i=1:4]
    basis=S.shell_element_frame_quad4(pts...,:bisector)
    center=sum(pts)/4
    local3=[dot(pts[i]-center,basis[j]) for i=1:4,j=1:3]
    local3[:,1:2],local3
end

function mapped_kernel(xy,xyz,u,E,nu,h;assumed=true)
    W=F.quad4_finite_warp_displacement_map(xy,xyz)
    up=W===nothing ? u : W*u
    kg=F.geometric_stiffness_quad4_nastran_kdjj_iso(xy,up,E,nu,h;assumed_transverse=assumed)
    W===nothing ? kg : W'*kg*W
end

# Independent scalar prestress energy: shape derivatives come from AD of
# the bilinear interpolation, rather than the production gradient routines.
function transverse_energy(xy,u,w,E,nu,h)
    diagonal1=xy[3,:]-xy[1,:];diagonal2=xy[2,:]-xy[4,:]
    e1=normalize(normalize(diagonal1)+normalize(diagonal2));Q=hcat(e1,[-e1[2],e1[1]])
    xp=xy*Q;up=permutedims(reshape(u,6,4))[1:4,1:2]*Q
    shape(q)=[(1-q[1])*(1-q[2]),(1+q[1])*(1-q[2]),
              (1+q[1])*(1+q[2]),(1-q[1])*(1+q[2])]/4
    function gradient(r,s)
        natural=AD.jacobian(shape,[r,s]);J=xp'*natural
        natural/J,abs(det(J))
    end
    dc,_=gradient(0.,0.)
    shear=dot(dc[:,2],up[:,1])+dot(dc[:,1],up[:,2])
    D=E/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    energy=zero(E*nu*h);g=inv(sqrt(3.))
    for r in (-g,g),s in (-g,g)
        d,jac=gradient(r,s)
        stress=D*[dot(d[:,1],up[:,1]),dot(d[:,2],up[:,2]),shear]
        dx,_=gradient(0.,s);dy,_=gradient(r,0.)
        slope=[dot(dx[:,1],w),dot(dy[:,2],w)]
        energy+=h*jac*dot(slope,[stress[1] stress[3];stress[3] stress[2]]*slope)
    end
    energy
end

function checks()
    prop=Dict("TYPE"=>"PSHELL","MID4"=>0);material=Dict("TYPE"=>"MAT1")
    @test S.kg_quad4_iso_assumed_transverse_enabled(0.,prop,material)
    @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,prop,material)
    @test S.kg_quad4_iso_assumed_transverse_enabled(.01,prop,material;finite_warp_projection=true)
    for warp in (-.01,Inf,NaN)
        @test !S.kg_quad4_iso_assumed_transverse_enabled(warp,prop,material;finite_warp_projection=true)
    end
    for exclusions in ((normal_transform=true,),(curvature=zeros(3),),(slope=zeros(2),))
        @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,prop,material;finite_warp_projection=true,exclusions...)
    end
    @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,merge(prop,Dict("MID4"=>1)),material;finite_warp_projection=true)
    @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,merge(prop,Dict("Bmb"=>ones(3,3))),material;finite_warp_projection=true)
    @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,prop,Dict("TYPE"=>"MAT8");finite_warp_projection=true)
    iso=Dict("TYPE"=>"PCOMP_CLT","Cm"=>[1. .3 0.;.3 1. 0.;0. 0. .35])
    @test S.kg_quad4_iso_assumed_transverse_enabled(.01,iso,material;finite_warp_projection=true)
    anisotropic=merge(iso,Dict("Cm"=>[1. .3 0.;.3 2. 0.;0. 0. .35]))
    @test !S.kg_quad4_iso_assumed_transverse_enabled(.01,anisotropic,material;finite_warp_projection=true)
    shapes=([0. 0.;1.8 0.;1.8 .3;0. .3],
            [0. 0.;2. 0.;2.55 .4;.55 .4],
            [0. 0.;1.5 .05;1.8 .6;.1 .5])
    E=71e9;nu=.29;h=.003
    for shape in shapes
        xyz=hcat(shape,[.012,-.012,.012,-.012]);xy,local3=local_geometry(xyz)
        W=F.quad4_finite_warp_displacement_map(xy,local3)
        @test W !== nothing
        u=1e-3sin.(collect(1.:24.));K=mapped_kernel(xy,local3,u,E,nu,h)
        @test norm(K-K')/norm(K)<2e-13
        for w in ([.2,-.5,.8,.1],[.7,.3,-.2,-.8])
            projected=zeros(24);projected[3:6:24]=w;physical=W\projected
            expected=transverse_energy(xy,W*u,w,E,nu,h)
            @test isapprox(dot(physical,K*physical),expected;rtol=3e-12,atol=1e-12)
        end
        for shift=1:3
            p=circshift(collect(1:4),-shift);dofs=[6(i-1)+j for i in p for j=1:6]
            @test isapprox(mapped_kernel(xy[p,:],local3[p,:],u[dofs],E,nu,h),K[dofs,dofs];rtol=3e-12)
        end
        for axis=1:3
            unit=zeros(3);unit[axis]=1.;translation=zeros(24);rotation=zeros(24)
            for i=1:4
                translation[6i-5:6i-3]=unit
                rotation[6i-5:6i-3]=cross(unit,local3[i,:]);rotation[6i-2:6i]=unit
            end
            @test norm(K*translation)<2e-12norm(K)
            @test norm(mapped_kernel(xy,local3,translation,E,nu,h))<1e-10E*h
            @test norm(mapped_kernel(xy,local3,rotation,E,nu,h))<1e-10E*h
        end
        # The composition approaches the planar assumed-gradient operator
        # continuously from either sign of warp; it does not change formulas
        # when the broad shell-routing flatness tolerance is crossed.
        flat3=hcat(xy,zeros(4));flat=mapped_kernel(xy,flat3,u,E,nu,h)
        for sign in (-1.,1.)
            errors=Float64[]
            for scale in (1e-3,1e-5,1e-7)
                warped=hcat(xy,sign*scale*local3[:,3])
                push!(errors,norm(mapped_kernel(xy,warped,u,E,nu,h)-flat)/norm(flat))
            end
            @test errors[2]<.011errors[1]
            @test errors[3]<.011errors[2]
            @test errors[3]<1e-7
        end
        v=cos.(collect(1.:24.));du=1e-4cos.(collect(1.:24.));step=2e-5
        energy(t)=dot(v,mapped_kernel(xy,local3,u+t*du,E*(1+.2t),nu+.03t,h*(1+.4t))*v)
        derivative=AD.derivative(energy,0.)
        fd=(energy(step)-energy(-step))/(2step)
        @test isapprox(derivative,fd;rtol=2e-8)
    end
end
end

@testset "Warped isotropic assumed transverse energy" begin
    WarpedAssumedTransverseFixture.checks()
end
