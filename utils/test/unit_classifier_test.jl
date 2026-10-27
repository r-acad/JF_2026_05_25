module UnitClassifierTests
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
const square=[-.5 -.5;.5 -.5;.5 .5;-.5 .5]
tensor(A)=SVector{3,Float64}(A[1,1],A[2,2],A[1,2])
classify(k,xy=square)=S.q4_curvature_is_numerically_cylindrical(k,xy)
function curvature(points)
    p=Tuple(SVector{3,Float64}(points[i,:]) for i=1:4)
    v1,v2,v3=S.shell_element_frame_quad4(p...)
    center=sum(p)/4
    xy=[dot(p[i]-center,j==1 ? v1 : v2) for i=1:4,j=1:2]
    k=S.estimate_quad4_corner_curvature_membrane(xy,p...,v1,v2,v3)
    k,xy
end
@testset "Dimensionless cylindrical curvature numerical rank" begin
    for amplitude in (-.7,.03,2.),angle in (0.,.17,.63,1.14,2.3),scale in (1e-12,1e-6,1.,1e3,1e6,1e12)
        R=[cos(angle) -sin(angle);sin(angle) cos(angle)]
        for principal in ((amplitude,0.),(amplitude,amplitude),(amplitude,-amplitude),(amplitude,amplitude*1e-6))
            A=R*Diagonal(collect(principal))*R'
            @test classify(tensor(A)/scale,scale*square)==iszero(principal[2])
            @test classify(-tensor(A)/scale,scale*square)==iszero(principal[2])
        end
    end
    @test !classify(SVector(0.,0.,0.))
    @test !classify(SVector(1e-18,0.,0.))
    @test !classify(SVector(Inf,0.,0.))
    @test !classify(SVector(1.,0.,0.),zeros(4,2))
    @test classify(SVector(.5,0.,0.))
    # The same physical saddle must remain rank two in every length unit.
    saddle=[0. -.3 .025;.5 -.3 0.;.5 0. 0.;0. 0. 0.]
    axis=normalize([.3,-.7,.2]);W=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
    Q=I+sin(.8)*W+(1-cos(.8))*(W*W)
    for scale in (1e-3,1.,1e3,1e6,1e9),rotation in (Matrix{Float64}(I,3,3),Q),order in ([1,2,3,4],[2,3,4,1],[4,3,2,1])
        k,xy=curvature(scale*saddle[order,:]*rotation')
        @test !classify(k,xy)
        k1,k2=S.q4_curvature_principal_abs(k)
        @test k2/k1>.99
    end
    k,xy=curvature(saddle)
    @test abs(S.q4_curvature_gaussian(k))>1e-10
    k_large,xy_large=curvature(1e6*saddle)
    @test abs(S.q4_curvature_gaussian(k_large))<=1e-10
    @test first(S.q4_curvature_principal_abs(k_large))>1e-8
    @test !classify(k_large,xy_large)
    @test isapprox(S.q4_curvature_characteristic_length(xy)*k,
        S.q4_curvature_characteristic_length(xy_large)*k_large;rtol=3e-14,atol=0.)
    # An extruded cylindrical strip has planar facets; its zero corner
    # curvature stays on the existing flat-facet branch at every unit scale.
    for scale in (1e-6,1.,1e6),radius in (.5,2.),theta in (.05,.4,1.)
        p=[0. radius*cos(-theta) radius*sin(-theta);1. radius*cos(-theta) radius*sin(-theta);
           1. radius*cos(theta) radius*sin(theta);0. radius*cos(theta) radius*sin(theta)]
        k,xy=curvature(scale*p)
        @test !classify(k,xy)
    end
end
end
