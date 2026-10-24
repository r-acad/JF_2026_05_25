using Test, OpenJFEM, LinearAlgebra

@testset "Bushing axes and physical spring point" begin
    S=OpenJFEM.Solver
    Id=Matrix{Float64}(I,3,3);X=[0. 0. 0.;.4 0. 0.]
    ids=Dict(1=>1,2=>2);Rs=[Id,Id]
    k=[1.e6,2.e6,3.e6,4.e3,5.e3,6.e3]
    bush=Dict{String,Any}("ID"=>1,"GA"=>1,"GB"=>2,"CID"=>0,"S"=>.3)
    prop=Dict("K"=>k);model=Dict("CORDs"=>Dict())
    dofs,K=S._cbush_stiffness_matrix(model,bush,prop,ids,X,Rs)
    @test dofs==collect(1:12)
    @test K≈K'
    @test minimum(eigvals(Symmetric(K))) > -1e-8
    @test count(>(1e-6),eigvals(Symmetric(K)))==6
    # Exact rigid-body rotations have zero relative motion at the spring.
    for j in 1:3
        u=zeros(12);u[j]=u[j+6]=1
        @test norm(K*u)<1e-8
        omega=Id[:,j];u=zeros(12)
        for i in 1:2
            u[(i-1)*6 .+ (1:3)]=cross(omega,X[i,:])
            u[(i-1)*6 .+ (4:6)]=omega
        end
        @test norm(K*u)<1e-8
    end
    # With GA fixed, a unit Y force at GB has spring translation and
    # rotational-arm compliance. This detects the old coincident-only law.
    f=[0.,1.,0.,0.,0.,0.];u=K[7:12,7:12]\f
    arm=.4*(1-.3)
    @test u[2]≈1/k[2]+arm^2/k[6] rtol=1e-13
    @test u[6]≈arm/k[6] rtol=1e-13
    a=.47;Q=[cos(a) -sin(a) 0.;sin(a) cos(a) 0.;0. 0. 1.]
    model["CORDs"]["50"]=Dict("U"=>Q[:,1],"V"=>Q[:,2],"W"=>Q[:,3])
    rot=copy(bush);rot["CID"]=50
    _,Kr=S._cbush_stiffness_matrix(model,rot,prop,ids,X*Q',[Q,Q])
    @test Kr≈K rtol=1e-13
    _,Kcd=S._cbush_stiffness_matrix(model,bush,prop,ids,X,[Q,Q])
    T=kron(Matrix{Float64}(I,4,4),Q)
    @test Kcd≈T'*K*T rtol=1e-13
    grounded=copy(bush);grounded["GB"]=0
    _,Kg=S._cbush_stiffness_matrix(model,grounded,prop,ids,X,Rs)
    @test Kg≈Diagonal(k)
    # Card parsing retains axes, default mid-point and an explicit S.
    mktempdir() do dir
        p=joinpath(dir,"bush.bdf")
        write(p,"""
        SOL 101
        CEND
        BEGIN BULK
        GRID,1,,0.,0.,0.
        GRID,2,,.4,0.,0.
        PBUSH,1,K,1.e6,2.e6,3.e6,4.e3,5.e3,6.e3
        CBUSH,1,1,1,2,,,,0
        CBUSH,2,1,1,2,0.,1.,0.
        +,.3
        ENDDATA
        """)
        m=OpenJFEM.bdf_to_model(p);b=m["CBUSHs"]
        @test b["1"]["CID"]==0
        @test b["1"]["S"]==.5
        @test b["2"]["CID"]==-1
        @test b["2"]["V"]==[0.,1.,0.]
        @test b["2"]["S"]==.3
    end
end
