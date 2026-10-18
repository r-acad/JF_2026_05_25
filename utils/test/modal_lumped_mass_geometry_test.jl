using Test, LinearAlgebra, OpenJFEM

module LumpedMassGeometryFixture
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver
const F=S.FEM

function checks()
    # Exact area and first moments of x∈[0,2-y], y∈[0,1]. Equal
    # corner masses preserve area but fail both centroid coordinates.
    xy=[0. 0.;2. 0.;1. 1.;0. 1.]
    M=F.reference_lumped_mass_quad4(xy,2.0,.5)
    nodal=diag(M)[1:6:end]
    @test nodal≈[5/12,5/12,1/3,1/3] rtol=1e-14
    @test sum(nodal)≈1.5 rtol=1e-14
    @test vec(xy'*nodal)/sum(nodal)≈[7/9,4/9] rtol=1e-14
    @test isdiag(M)
    @test all(iszero,diag(M)[[6i+d for i in 0:3 for d in 4:6]])
    for order in ([2,3,4,1],[4,3,2,1])
        @test diag(F.reference_lumped_mass_quad4(xy[order,:],2.,.5))[1:6:end]≈nodal[order] rtol=1e-14
    end
    a=.63;Q=[cos(a) -sin(a);sin(a) cos(a)]
    @test F.reference_lumped_mass_quad4(xy*Q',2.,.5)≈M rtol=1e-14
    @test diag(F.reference_lumped_mass_quad4([0. 0.;2. 0.;2. 1.;0. 1.],2.,.5))[1:6:end]≈fill(.5,4)

    mktempdir() do dir
        path=joinpath(dir,"offset.bdf")
        write(path,"""
SOL 103
CEND
BEGIN BULK
PARAM,COUPMASS,-1
GRID,1,,0.,0.,0.
GRID,2,,2.,.3,.2
CBAR,10,20,1,2,0.,1.,0.
,0,0,.1,-.2,.3,-.05,.15,-.1
PBAR,20,30,.02,.0003,.0004,.0002,.7
MAT1,30,7.1E10,,.3,2700.
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(path)
        ids=Dict(1=>1,2=>2);X=[0. 0. 0.;2. .3 .2];R=[Matrix{Float64}(I,3,3) for _ in 1:2]
        el=model["CBARs"]["10"]
        wa=Float64.(el["WA"]);wb=Float64.(el["WB"])
        @test wa==[.1,-.2,.3] && wb==[-.05,.15,-.1]
        endpoints=[X[1,:]+wa,X[2,:]+wb]
        mass=(2700*.02+.7)*norm(endpoints[2]-endpoints[1])
        expected=zeros(12,12)
        for (i,w) in enumerate((wa,wb))
            B=hcat(Matrix{Float64}(I,3,3),-S.skew3(w))
            d=6i-5:6i
            expected[d,d].=mass/2*(B'*B)
        end
        actual=S.assemble_modal_mass(model,ids,X,R,12)
        @test actual≈expected rtol=1e-13 atol=1e-15
        @test S.assemble_mass(model,ids,X,R,12)≈expected rtol=1e-13 atol=1e-15
        @test minimum(eigvals(Symmetric(Matrix(actual)))) > -1e-12*mass
        # A global rigid-body velocity must carry the two endpoint lumped
        # masses, including their centroid and parallel-axis inertia.
        rigid=zeros(12,6)
        for i in 1:2
            rigid[6i-5:6i-3,1:3].=I(3)
            rigid[6i-5:6i-3,4:6].=-S.skew3(X[i,:])
            rigid[6i-2:6i,4:6].=I(3)
        end
        body=rigid'*actual*rigid;cg=(endpoints[1]+endpoints[2])/2
        inertia=sum(mass/2*(dot(p,p)*I(3)-p*p') for p in endpoints)
        @test body[1:3,1:3]≈mass*I(3) rtol=1e-13
        @test body[1:3,4:6]≈-mass*S.skew3(cg) rtol=1e-13
        @test body[4:6,4:6]≈inertia rtol=1e-13
        # Uniform acceleration includes the offset moment r×F, also needed
        # by static/nonlinear body-load assembly using the same mass operator.
        acceleration=zeros(12);acceleration[3:6:end].=-9.81
        force=actual*acceleration
        @test force[4:6]≈cross(wa,[0.,0.,-9.81mass/2]) rtol=1e-13
        @test force[10:12]≈cross(wb,[0.,0.,-9.81mass/2]) rtol=1e-13
        theta=.41;C=[cos(theta) 0. sin(theta);0. 1. 0.;-sin(theta) 0. cos(theta)]
        T=kron(I(4),C)
        @test S.assemble_modal_mass(model,ids,X,[C,C],12)≈T'*actual*T rtol=1e-13 atol=1e-15
        zerooffset=deepcopy(model);zerooffset["CBARs"]["10"]["WA"].=0.;zerooffset["CBARs"]["10"]["WB"].=0.
        z=S.assemble_modal_mass(zerooffset,ids,X,R,12)
        @test isdiag(Matrix(z)) || norm(Matrix(z)-Diagonal(diag(z)))<1e-13
        @test diag(z)[[1,2,3,7,8,9]]≈fill((2700*.02+.7)*norm(X[2,:]-X[1,:])/2,6) rtol=1e-13
    end
end
end

@testset "Lumped mass preserves tapered-shell centroid and bar offsets" begin
    LumpedMassGeometryFixture.checks()
end
