using Test

module ShellGeometricFrameInvarianceFixture
using Test,OpenJFEM,LinearAlgebra
const S=OpenJFEM.Solver

rx(a)=[1. 0. 0.;0. cosd(a) -sind(a);0. sind(a) cosd(a)]
ry(a)=[cosd(a) 0. sind(a);0. 1. 0.;-sind(a) 0. cosd(a)]

function fixture(dir,n,offset,warp,Q,mixed_cd)
    coordinates=[[0.,0.,warp],[2.,0.,-warp],[2.,1.,warp],[0.,1.,-warp]][1:n]
    frames=[ry(17.),rx(42.),ry(-31.)*rx(23.),rx(-57.)]
    transform=zeros(6n,6n)
    deck=joinpath(dir,"geometric_frame.bdf")
    open(deck,"w") do io
        println(io,"SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,1.")
        for i in 1:n
            H=mixed_cd ? Q*frames[i] : Matrix{Float64}(I,3,3)
            cid=mixed_cd ? 100+i : 0
            if mixed_cd
                println(io,"CORD2R,$cid,0,0.,0.,0.,",join(H[:,3],','))
                println(io,"+,",join(H[:,1],','))
            end
            p=Q*coordinates[i]
            println(io,"GRID,$i,,",join(p,','),",$cid")
            T=H'*Q
            for d in (0,3)
                ix=(6(i-1)+d+1):(6(i-1)+d+3)
                transform[ix,ix]=T
            end
        end
        println(io,n==4 ? "CQUAD4,1,1,1,2,3,4,0.0,$offset" : "CTRIA3,1,1,1,2,3,0.0,$offset")
        println(io,"PSHELL,1,1,.02,1,,1\nMAT1,1,7.E10,,.3,2700.\nENDDATA")
    end
    model=OpenJFEM.bdf_to_model(deck)
    model,transform,coordinates
end

function geometric(model,u;capture=nothing)
    _,ids,X,ndof,R,_,rbe3,snorm,_=S.assemble_stiffness(model;sol105_context=true)
    Matrix(S.assemble_geometric_stiffness(model,ids,X,R,ndof,u,snorm,rbe3;
        snorm_angle_override=0.,geometric_capture=capture))
end

function checks()
    mktempdir() do dir
        for n in (3,4),warp in (n==4 ? (0.,.08) : (0.,)),offset in (-.04,.04)
            identity=Matrix{Float64}(I,3,3)
            base,_,coordinates=fixture(dir,n,offset,warp,identity,false)
            u=zeros(6n)
            for i in 1:n
                x,y,_=coordinates[i]
                u[6i-5:6i]=[-1e-4*x+2e-5*y,-7e-5*y,3e-5*x*y,
                    .002*y,-.001*x,5e-4]
            end
            for enabled in (true,false)
                withenv("JFEM_KG_SHELL_DRILL_ZERO"=>string(enabled)) do
                    @test S.kg_shell_drill_zero_enabled()==enabled
                    captured=Any[]
                    G=geometric(base,u;capture=(eid,data)->push!(captured,data))
                    reference_offset=get(only(captured),:kg_reference_offset_differential,false)
                    @test reference_offset == (n==4 && enabled)
                    @test norm(G)>0
                    for mixed_cd in (false,true)
                        Q=ry(35.)*rx(21.)
                        rotated,T,_=fixture(dir,n,offset,warp,Q,mixed_cd)
                        rotated_u=T*u
                        rotated_capture=Any[]
                        Grot=geometric(rotated,rotated_u;
                            capture=(eid,data)->push!(rotated_capture,data))
                        @test get(only(rotated_capture),:kg_reference_offset_differential,false)==reference_offset
                        expected=T*G*T'
                        @test norm(Grot-expected)/norm(expected)<2e-10
                        virtual=[sin(.31i) for i in 1:6n]
                        @test isapprox(dot(T*virtual,Grot*(T*virtual)),dot(virtual,G*virtual);
                            rtol=2e-10,atol=1e-9)
                        if reference_offset
                            # Ordinary reference-surface offset prestress acts
                            # on GRID translations. Both the finite-warp map's
                            # translation rows and GRID-CD rotations preserve
                            # zero work for every pure rotational perturbation.
                            rotations=[6(i-1)+j for i=1:n for j=4:6]
                            @test all(iszero,Grot[rotations,:])
                            @test all(iszero,Grot[:,rotations])
                        else
                            # Legacy offset and TRI3 routes retain physical
                            # bending terms in the rotated output frame, even
                            # when that component is numbered six.
                            @test maximum(abs,diag(Grot)[6:6:6n])>1e-6
                        end
                    end
                end
            end
        end
    end
end
end

@testset "Shell geometric work is invariant under output coordinate changes" begin
    ShellGeometricFrameInvarianceFixture.checks()
end
