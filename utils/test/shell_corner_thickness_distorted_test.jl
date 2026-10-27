using Test

module ShellCornerThicknessDistortedFixture
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM
const E=70e9
const NU=.31
const RHO=2700.
const NSM=.8
const C=E/(1-NU^2)*[1. NU 0.;NU 1. 0.;0. 0. (1-NU)/2]
const TI=[.0017,.0031,.0044,.0023]

function model(path,xy;rotation=Matrix{Float64}(I,3,3),cyclic=0,ti=TI,h=.003)
    xyz=hcat(xy,zeros(4))*rotation'
    order=circshift(collect(1:4),-cyclic)
    lines=["SOL 105","CEND","SUBCASE 1"," SPC=1"," LOAD=1",
        "SUBCASE 2"," METHOD=2"," SPC=1"," STATSUB(BUCKLING)=1","BEGIN BULK",
        "PARAM,SNORM,0.","PARAM,K6ROT,1.","PARAM,COUPMASS,1",
        "MAT1,1,$E,,$NU,$RHO","PSHELL,1,1,$h,1,,1,,$NSM"]
    for i=1:4;push!(lines,"GRID,$i,,$(join(xyz[i,:],','))");end
    push!(lines,"CQUAD4,1,1,$(join(order,','))")
    ti===nothing || push!(lines,"+,,0,$(join(ti[order],','))")
    append!(lines,["SPC1,1,123456,1,4","FORCE,1,2,0,1.,-1.,0.,0.","EIGRL,2,0.,,2","ENDDATA"])
    write(path,join(lines,'\n')*"\n")
    OpenJFEM.bdf_to_model(path)
end

function assembly(m)
    K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(m;snorm_angle_override=0.,sol105_context=true)
    M=S.assemble_modal_mass(m,ids,X,R,nd)
    (K=Matrix(K),M=Matrix(M),ids=ids,X=X,nd=nd,R=R,mapping=mapping,normals=normals)
end

function physical_volume(xy,ti)
    # An independent 3x3 rule exactly integrates the bilinear thickness times
    # the affine determinant of a convex bilinear map. No element helpers.
    points=(-sqrt(3/5),0.,sqrt(3/5));weights=(5/9,8/9,5/9)
    volume=0.
    for (r,wr) in zip(points,weights),(s,ws) in zip(points,weights)
        n=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]/4
        dr=[-(1-s),(1-s),(1+s),-(1+s)]/4
        ds=[-(1-r),-(1+r),(1+r),(1-r)]/4
        xr,yr=dot(dr,xy[:,1]),dot(dr,xy[:,2])
        xs,ys=dot(ds,xy[:,1]),dot(ds,xy[:,2])
        volume+=wr*ws*(xr*ys-yr*xs)*dot(n,ti)
    end
    volume
end

function polygon_area(xy)
    sum(xy[i,1]*xy[mod1(i+1,4),2]-xy[mod1(i+1,4),1]*xy[i,2] for i=1:4)/2
end

function affine_membrane(xy,e)
    u=zeros(24)
    for i=1:4
        x,y=xy[i,:]
        u[6i-5]=e[1]*x+e[3]*y/2
        u[6i-4]=e[2]*y+e[3]*x/2
    end
    u
end

function checks()
    shapes=(
        [-.4 -.2;.3 -.2;.46 .2;-.24 .2],
        [-.4 -.2;.4 -.2;.22 .2;-.31 .2],
        [-.42 -.21;.37 -.16;.24 .24;-.29 .16])
    axis=normalize([.3,-.4,.5]);angle=.73
    crossmat=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
    Q=Matrix{Float64}(I,3,3)+sin(angle)*crossmat+(1-cos(angle))*crossmat^2
    T=kron(Matrix{Float64}(I,8,8),Q)
    mktempdir() do dir
        for (shape,xy0) in enumerate(shapes),scale in (.4,2.3)
            xy=scale*xy0
            m=model(joinpath(dir,"shape$(shape)_$scale.bdf"),xy)
            a=assembly(m)
            area=polygon_area(xy);volume=physical_volume(xy,TI)
            @test area>0 && volume>0
            @test norm(a.K-a.K')<=2e-12norm(a.K)
            @test minimum(eigvals(Symmetric(a.K)))>=-2e-12opnorm(a.K)
            @test minimum(eigvals(Symmetric(a.M)))>=-2e-13opnorm(a.M)
            for dof=1:6
                rigid=zeros(24);translation=zeros(3);rotation=zeros(3)
                dof<=3 ? (translation[dof]=1.) : (rotation[dof-3]=1.)
                for i=1:4
                    rigid[6i-5:6i-3]=translation+cross(rotation,[xy[i,1],xy[i,2],0.])
                    rigid[6i-2:6i]=rotation
                end
                @test norm(a.K*rigid)<=4e-12norm(a.K)*max(norm(rigid),1.)
            end
            for e in ([.0007,-.0002,.0003],[-.0004,.0006,-.0002])
                u=affine_membrane(xy,e)
                @test dot(u,a.K*u)≈volume*dot(e,C*e) rtol=5e-12
                kg=Matrix(S.assemble_geometric_stiffness(m,a.ids,a.X,a.R,a.nd,u,a.normals,a.mapping;
                    snorm_angle_override=0.,buckling_subcase=2,static_load_id=1))
                gradient=[.4,-.7];w=zeros(24)
                for i=1:4;w[6i-3]=dot(gradient,xy[i,:]);end
                stress=C*e
                expected=volume*(gradient[1]^2*stress[1]+gradient[2]^2*stress[2]+2prod(gradient)*stress[3])
                @test dot(w,kg*w)≈expected rtol=8e-12
            end
            # Independently integrate the cubic bilinear section polynomial
            # t=a+b*r+c*s+d*r*s over the reference square: odd powers vanish,
            # <r^2>=<s^2>=1/3 and <r^2*s^2>=1/9.
            ta=sum(TI)/4;tb=(-TI[1]+TI[2]+TI[3]-TI[4])/4
            tc=(-TI[1]-TI[2]+TI[3]+TI[4])/4;td=(TI[1]-TI[2]+TI[3]-TI[4])/4
            cube=ta^3+ta*(tb^2+tc^2+td^2/3)+2tb*tc*td/3
            h=.003;G=E/(2(1+NU))
            packet=F.quad4_variable_thickness_packet(xy,h*C,h^3*C/12,
                Matrix{Float64}(I,2,2)*G*h*5/6,h,E,TI;k6rot=1.)
            e=[.0007,-.0002,.0003];curvature=[.002,-.0007,.0011]
            u=affine_membrane(xy,e)
            for i=1:4
                x,y=xy[i,:]
                u[6i-2]=-curvature[2]*y-curvature[3]*x/2
                u[6i-1]=curvature[1]*x+curvature[3]*y/2
            end
            fields=F.quad4_variable_thickness_fields(packet,u)
            @test packet.mean_thickness≈volume/area rtol=4e-13
            @test packet.reported_thickness≈ta rtol=4eps(Float64)
            @test packet.reported_cube≈cube rtol=5e-15
            @test abs(cube-ta^3)>1e-3ta^3
            @test fields.N_reported≈ta*C*e rtol=4e-12
            @test fields.M_reported≈cube/12*C*curvature rtol=4e-12
            @test fields.reported_thickness≈ta rtol=4eps(Float64)
            for dof=1:3
                translation=zeros(24);translation[dof:6:end].=1.
                @test dot(translation,a.M*translation)≈RHO*volume+NSM*area rtol=3e-13
            end
            for cyclic=1:3
                ac=assembly(model(joinpath(dir,"cyclic.bdf"),xy;cyclic=cyclic))
                @test ac.K≈a.K rtol=8e-12
                @test ac.M≈a.M rtol=8e-12
            end
            ar=assembly(model(joinpath(dir,"rotated.bdf"),xy;rotation=Q))
            @test ar.K≈T*a.K*T' rtol=8e-12
            @test ar.M≈T*a.M*T' rtol=8e-12
            for uniform in (.0019,.0052)
                au=assembly(model(joinpath(dir,"uniform.bdf"),xy;ti=fill(uniform,4)))
                ap=assembly(model(joinpath(dir,"property.bdf"),xy;ti=nothing,h=uniform))
                @test au.K≈ap.K rtol=3e-12
                @test au.M≈ap.M rtol=3e-12
            end
        end
    end
end
end

@testset "Convex distorted corner-thickness physical invariants" begin
    ShellCornerThicknessDistortedFixture.checks()
end
