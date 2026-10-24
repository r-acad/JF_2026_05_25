using Test
module Hexa8ReducedShearFixture
using Test,LinearAlgebra,OpenJFEM
const HX=OpenJFEM.FEM

function hexa8_full_integration_K(x,E,nu)
    signs=[-1.0 -1 -1;1 -1 -1;1 1 -1;-1 1 -1;-1 -1 1;1 -1 1;1 1 1;-1 1 1]
    C=HX.iso_3d_constitutive(E,nu);K=zeros(24,24)
    for row in eachrow(signs/sqrt(3))
        r,s,t=row
        dN=zeros(3,8)
        for i in 1:8
            ri,si,ti=signs[i,:]
            dN[1,i]=ri*(1+si*s)*(1+ti*t)/8
            dN[2,i]=si*(1+ri*r)*(1+ti*t)/8
            dN[3,i]=ti*(1+ri*r)*(1+si*s)/8
        end
        J=dN*x;G=J\dN;B=zeros(6,24)
        for i in 1:8
            c=3(i-1);dx,dy,dz=G[:,i]
            B[1,c+1]=dx;B[2,c+2]=dy;B[3,c+3]=dz
            B[4,c+1]=dy;B[4,c+2]=dx
            B[5,c+2]=dz;B[5,c+3]=dy
            B[6,c+1]=dz;B[6,c+3]=dx
        end
        K .+= abs(det(J)).*(B'*C*B)
    end
    K
end

@testset "Reduced shear solid invariants" begin
    cube=[0.0 0 0;1 0 0;1 1 0;0 1 0;0 0 1;1 0 1;1 1 1;0 1 1]
    skew=copy(cube);skew[:,1].+=0.5.*skew[:,2]
    thin=copy(skew);thin[:,3].*=0.05
    tapered=copy(skew);tapered[7,:].+=[.2,-.1,.15];tapered[5,:].+=[-.05,.07,.1]
    warped=copy(cube);warped[7,:].+=[.17,.13,.2];warped[3,:].+=[.03,.02,-.08]
    E=70e9
    a=normalize([.2,-.4,.7]);theta=.61
    X=[0.0 -a[3] a[2];a[3] 0 -a[1];-a[2] a[1] 0.0]
    R=I+sin(theta)*X+(1-cos(theta))*(X*X)
    Urot=kron(Matrix{Float64}(I,8,8),R)
    for nu in (.3,.499), x in (cube,skew,thin,tapered,warped)
        K=HX._stiffness_hexa8_reduced_shear_bubble(x,E,nu)
        Kfull=hexa8_full_integration_K(x,E,nu)
        scale=opnorm(K)
        @test all(isfinite,K)
        @test norm(K-K')/scale < 1e-13
        @test minimum(eigvals(Symmetric(K)))/scale > -2e-12
        @test count(v->v>2e-10*scale,eigvals(Symmetric(K)))==18
        rigid=zeros(24,6)
        for i in 1:8
            rigid[3i-2:3i,1:3].=Matrix{Float64}(I,3,3)
            for j in 1:3
                rigid[3i-2:3i,3+j].=cross(Matrix{Float64}(I,3,3)[:,j],x[i,:])
            end
        end
        @test norm(K*rigid)/(scale*norm(rigid)) < 3e-12
        # Each constant strain is represented exactly, and its nodal work is
        # identical to the integrated unmodified physical gradient matrix.
        for component in 1:6
            S=zeros(3,3);i,j=HX._HEXA8_VOIGT_IJ[component]
            S[i,j]=S[j,i]=i==j ? 1.0 : .5
            u=vec((x*S')')
            @test norm((K-Kfull)*u)/(opnorm(Kfull)*norm(u)) < 3e-12
        end
        xr=x*R'.+reshape([1.2,-.6,.8],1,3)
        Kr=HX._stiffness_hexa8_reduced_shear_bubble(xr,E,nu)
        @test norm(Kr-Urot*K*Urot')/scale < 1e-10
    end
    for dims in ((1.,1.,1.),(1.,1.,.05),(.4,2.,.13)), nu in (.0,.3,.499)
        x=cube*Diagonal(collect(dims))
        K=HX._stiffness_hexa8_reduced_shear_bubble(x,E,nu)
        Keas=HX._stiffness_hexa8_eas(x,E,nu)
        @test norm(K-Keas)/norm(K) < 5e-12
    end
end

end # module
