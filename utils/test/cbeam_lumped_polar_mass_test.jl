using Test

module BeamLumpedPolarMassFixture
using OpenJFEM, Test, LinearAlgebra
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

function checks()
    # Integrate the Cartesian velocity of a spinning solid rectangular
    # section independently of the beam kernel's section-inertia formula.
    gx=(-sqrt(3/5),0.,sqrt(3/5));gw=(5/9,8/9,5/9)
    for (b,h,L,rho) in ((.02,.03,1.,2700.),(.7,.13,2.3,4.2),(.1,.4,.6,19.))
        A=b*h;Iy=b*h^3/12;Iz=h*b^3/12
        integral=sum(gw[i]*gw[j]*rho*((b*gx[i]/2)^2+(h*gx[j]/2)^2)*b*h*L/4 for i in 1:3,j in 1:3)
        # Elastic J is independent of rigid section kinetic energy, including
        # a zero torsional stiffness with a nonzero mass polar moment.
        for J in (0.,.2*(Iy+Iz),9*(Iy+Iz))
            M=F.reference_lumped_mass_frame3d(L,rho,A,J,Iy,Iz;torsion_inertia=true)
            twist=zeros(12);twist[4]=twist[10]=1.
            @test dot(twist,M*twist)≈integral rtol=2e-14
            @test isdiag(M) && minimum(diag(M))>=0.
            for d in 1:3
                velocity=zeros(12);velocity[d]=velocity[d+6]=1.
                @test dot(velocity,M*velocity)≈rho*A*L rtol=2e-14
            end
            @test diag(M)[[5,6,11,12]]==zeros(4)
            no_torsion=F.reference_lumped_mass_frame3d(L,rho,A,J,Iy,Iz)
            @test diag(no_torsion)[[4,5,6,10,11,12]]==zeros(6)
        end
    end
    # Verify the assembled operator against rigid endpoint-offset kinetic
    # energy for an oblique beam and independently rotated GRID DOF frames.
    mktempdir() do folder
        path=joinpath(folder,"offset_beam.bdf")
        write(path,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,0\nGRID,1,,0.,0.,0.\nGRID,2,,2.,.3,.2\nCBEAM,10,20,1,2,0.,1.,0.\n,0,0,.1,-.2,.3,-.05,.15,-.1\nPBAR,20,30,.02,.0003,.0004,.0002,0.\nMAT1,30,7.1E10,,.3,2700.\nENDDATA\n")
        model=OpenJFEM.bdf_to_model(path)
        ids=Dict(1=>1,2=>2);X=[0. 0. 0.;2. .3 .2];R=[Matrix{Float64}(I,3,3) for _ in 1:2]
        el=model["CBEAMs"]["10"];wa=Float64.(el["WA"]);wb=Float64.(el["WB"])
        p1=X[1,:]+wa;p2=X[2,:]+wb;L=norm(p2-p1);axis=(p2-p1)/L
        expected=zeros(12,12)
        for (i,w) in enumerate((wa,wb))
            B=hcat(Matrix{Float64}(I,3,3),-S.skew3(w));q=vcat(zeros(3),axis)
            ix=6i-5:6i
            expected[ix,ix].=(2700*.02*L/2)*(B'*B)+(2700*.0007*L/2)*(q*q')
        end
        M=Matrix(S.assemble_mass(model,ids,X,R,12))
        @test M≈expected rtol=2e-13 atol=1e-15
        theta=.41;Q=[cos(theta) 0. sin(theta);0. 1. 0.;-sin(theta) 0. cos(theta)]
        T=kron(I(4),Q)
        @test S.assemble_mass(model,ids,X,[Q,Q],12)≈T'*M*T rtol=2e-13 atol=1e-15
    end
end
end

@testset "CBEAM lumped polar inertia from section kinetic energy" begin
    BeamLumpedPolarMassFixture.checks()
end
