using Test

module IndependentBeamMassAxisFixture
using OpenJFEM,LinearAlgebra,Test
const S=OpenJFEM.Solver

function check_independent_mass_axis()
    mktempdir() do dir
        path=joinpath(dir,"independent_mass_axis.bdf")
        write(path,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,1\nGRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nCBEAM,1,1,1,2,0.,1.,0.\nPBAR,1,1,2.,.4,.3,.5,4.\nMAT1,1,7.E10,,.3,3.\nENDDATA\n")
        model=OpenJFEM.bdf_to_model(path)
        prop=model["PBARLs"]["1"];prop["TYPE"]="PBEAM"
        for key in ("N1A","N1B","N2A","N2B");prop[key]=0.;end
        prop["M1A"]=prop["M1B"]=.2
        prop["M2A"]=prop["M2B"]=.3
        ids=Dict(1=>1,2=>2);coordinates=[0. 0. 0.;2. 0. 0.]
        frames=[Matrix{Float64}(I,3,3),Matrix{Float64}(I,3,3)]
        mass()=Matrix(S.assemble_mass(model,ids,coordinates,frames,12))
        M=mass()
        axial=zeros(12);axial[1]=axial[7]=1.
        twist=zeros(12);twist[4]=twist[10]=1.
        rz=zeros(12);rz[6]=rz[12]=1.
        # Independent rigid-motion integrals: structural polar inertia is
        # rho*(Iy+Iz)*L and the NSM line adds NSM*L*(M1^2+M2^2).
        @test dot(axial,M*axial)≈20.
        @test dot(twist,M*twist)≈5.24
        @test dot(axial,M*rz)≈-1.6
        @test M≈M'
        @test minimum(eigvals(Symmetric(M)))>0
        for delta in (-1e-8,1e-8)
            prop["N1A"]=prop["N1B"]=delta
            Mn=mass()
            @test isapprox(dot(twist,Mn*twist),5.24+12delta^2;rtol=1e-12)
            @test isapprox(dot(axial,Mn*rz),-1.6-12delta;rtol=1e-12)
            @test norm(Mn-M)/norm(M)<1e-7
        end
        # Disabling elastic centroid coupling must not suppress a separately
        # specified NSM axis. Preserve the existing N-axis switch semantics.
        prop["N1A"]=prop["N1B"]=.1
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>"false") do
            @test mass()≈M
        end
        prop["N1A"]=prop["N1B"]=0.
        prop["NSM"]=0.
        M0=mass()
        @test dot(axial,M0*axial)≈12.
        @test dot(twist,M0*twist)≈4.2
        @test abs(dot(axial,M0*rz))<1e-12
    end
end
end

@testset "CBEAM independent NSM-axis kinetic energy" begin
    IndependentBeamMassAxisFixture.check_independent_mass_axis()
end


module SignedBeamLineMassFixture
using OpenJFEM,LinearAlgebra,Test
const S=OpenJFEM.Solver
function checks()
    mktempdir() do dir
        path=joinpath(dir,"signed_beam_line_mass.bdf")
        write(path,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,1\nGRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nCBEAM,1,1,1,2,0.,1.,0.\nPBAR,1,1,2.,.4,.3,.5,-1.\nMAT1,1,7.E10,,.3,3.\nENDDATA\n")
        model=OpenJFEM.bdf_to_model(path);prop=model["PBARLs"]["1"];prop["TYPE"]="PBEAM"
        @test prop["NSM"] == -1.
        ids=Dict(1=>1,2=>2);coordinates=[0. 0. 0.;2. 0. 0.]
        frames=[Matrix{Float64}(I,3,3),Matrix{Float64}(I,3,3)]
        mass()=Matrix(S.assemble_mass(model,ids,coordinates,frames,12))
        axial=zeros(12);axial[1]=axial[7]=1.
        twist=zeros(12);twist[4]=twist[10]=1.
        rz=zeros(12);rz[6]=rz[12]=1.
        for (n1,n2) in ((0.,0.),(.01,-.005)),(m1,m2,positive_definite) in ((0.,0.,true),(.02,.03,true),(.2,.3,false))
            prop["N1A"]=prop["N1B"]=n1;prop["N2A"]=prop["N2B"]=n2
            prop["M1A"]=prop["M1B"]=m1;prop["M2A"]=prop["M2B"]=m2
            prop["NSM"]=0.;M0=mass()
            prop["NSM"]=1.;Mplus=mass()
            prop["NSM"]=-1.;Mminus=mass()
            @test isapprox(Mplus+Mminus,2M0;rtol=1e-13,atol=1e-13)
            @test isapprox(dot(axial,Mminus*axial),10.;rtol=1e-13)
            @test isapprox(dot(twist,Mminus*twist),4.2+12*(n1^2+n2^2)-2*(m1^2+m2^2);rtol=1e-13)
            @test isapprox(dot(axial,Mminus*rz),-12n1+2m1;rtol=1e-13,atol=1e-13)
            @test isapprox(Mminus,Mminus';rtol=1e-13)
            # Large eccentric negative line masses are not necessarily
            # physically admissible despite their positive total mass.
            minimum_energy=minimum(eigvals(Symmetric(Mminus)))
            @test positive_definite ? minimum_energy>0 : minimum_energy<0
        end
    end
end
@testset "Coupled CBEAM signed NSM remains an additive line mass" begin
    checks()
end
end
