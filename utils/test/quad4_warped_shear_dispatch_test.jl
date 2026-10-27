using Test
module WarpedShearDispatchFixture
using Test,OpenJFEM,LinearAlgebra
const S=OpenJFEM.Solver
function model(path,height,Q;rigid=false,coupled=false,mcid=false)
    xy=[-.6 -.3;.6 -.3;.8 .3;-.4 .3]
    X=hcat(xy,height*[1.,-1.,1.,-1.])*Q'
    open(path,"w") do io
        println(io,"SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,1.")
        for i in 1:4;println(io,"GRID,$i,,",join(X[i,:],','));end
        println(io,"CORD2R,501,,0.,0.,0.,",join(Q[:,3],','),"\n+,",join(Q[:,1],','))
        println(io,"CQUAD4,1,10,1,2,3,4,",mcid ? "501" : "0.")
        shear=rigid ? "0.,0." : "1.E20,1.E20"
        println(io,"MAT8,1,145000.,9000.,.28,4300.,",shear,",1.")
        if coupled
            println(io,"PCOMP,10\n+,1,.012,0.,YES,1,.008,67.,YES")
        else
            println(io,"PCOMP,10\n+,1,.005,0.,YES,1,.005,67.,YES\n+,1,.005,67.,YES,1,.005,0.,YES")
        end
        println(io,"ENDDATA")
    end
    m=OpenJFEM.bdf_to_model(path)
    K,ids,x,nd,R,_,map,normals,_=S.assemble_stiffness(m;sol105_context=true)
    (m=m,K=Matrix(K),ids=ids,X=x,nd=nd,R=R,map=map,normals=normals)
end
function geometric(p,u)
    S.assemble_geometric_stiffness(p.m,p.ids,p.X,p.R,p.nd,u,p.normals,p.map)
end
@testset "Projected warp retains the rigid shear limit and material axes" begin
    mktempdir() do dir
        I3=Matrix{Float64}(I,3,3);Q=[cos(.37) 0. sin(.37);0. 1. 0.;-sin(.37) 0. cos(.37)]
        T=kron(Matrix{Float64}(I,8,8),Q);u=1e-4sin.(collect(1.:24.))
        for height in (0.,-.09,.09),coupled in (false,true)
            base=model(joinpath(dir,"base.bdf"),height,I3;rigid=true,coupled=coupled)
            finite=model(joinpath(dir,"finite.bdf"),height,I3;coupled=coupled)
            axis=model(joinpath(dir,"axis.bdf"),height,I3;rigid=true,coupled=coupled,mcid=true)
            rotated=model(joinpath(dir,"rotated.bdf"),height,Q;rigid=true,coupled=coupled)
            @test isapprox(base.K,finite.K;rtol=2e-12,atol=1e-11)
            @test isapprox(base.K,axis.K;rtol=2e-12,atol=1e-11)
            @test isapprox(rotated.K,T*base.K*T';rtol=2e-12,atol=1e-11)
            @test dot(u,base.K*u)>=0
            G=geometric(base,u)
            @test isapprox(G,geometric(axis,u);rtol=2e-11,atol=1e-10)
            @test isapprox(geometric(rotated,T*u),T*G*T';rtol=2e-10,atol=1e-10)
            @test isapprox(geometric(base,-2u),-2G;rtol=2e-12,atol=1e-11)
        end
        # Every offset consumer uses the same explicit alternate-route guard.
        m=Dict("SOL"=>105)
        @test S.shell_projected_reference_offset_enabled(m)
        for setting in ("JFEM_Q4_KERNEL"=>"mitc4_3d",
            "JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ"=>"true",
            "JFEM_Q4_MARGUERRE_COUPLING"=>"true",
            "JFEM_Q4_STATIC_PCOMP_NODAL_GEOMNORMAL_TRANSFORM"=>"true",
            "JFEM_SOL101_LINE_NODE_DRILL_SCALE"=>".5")
            withenv(setting) do
                @test !S.shell_projected_reference_offset_enabled(m)
            end
        end
    end
end
end
