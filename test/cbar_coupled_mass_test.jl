using Test, OpenJFEM, LinearAlgebra

function cbar_mass_test_model()
    mktempdir() do dir
        deck=joinpath(dir,"bar.bdf")
        write(deck,"""
        SOL 103
        CEND
        BEGIN BULK
        PARAM,COUPMASS,1
        MAT1,1,7.+10,,.3,2700.
        PBAR,1,1,.0001,1.-8,2.-8,1.-8
        GRID,1,,0.,0.,0.
        GRID,2,,.5,0.,0.
        GRID,3,,1.,0.,0.
        CBAR,1,1,1,2,0.,1.,0.
        CBAR,2,1,2,3,0.,1.,0.
        ENDDATA
        """)
        return OpenJFEM.bdf_to_model(deck)
    end
end

@testset "CBAR coupled mass integrates kinetic energy" begin
    model=cbar_mass_test_model()
    K,ids,x,ndof,rot,_,_,_,_=OpenJFEM.Solver.assemble_stiffness(model)
    mass(m)=OpenJFEM.Solver.assemble_mass(m,ids,x,rot,ndof)
    M=mass(model)
    # Independent continuous velocity field: constant axial velocity and
    # cubic transverse velocities. Integrating their squared polynomials
    # gives the exact kinetic energy, including translation/rotation terms.
    u=[.4];v=[-.7,.8,1.2,-.6];w=[.2,-.5,.9,.3]
    poly(c,s)=sum(c[i]*s^(i-1) for i in eachindex(c))
    deriv(c,s)=sum(((i-1)*c[i]*s^(i-2) for i in 2:length(c));init=0.)
    integral_square(c)=sum(c[i]*c[j]/(i+j-1) for i in eachindex(c),j in eachindex(c))
    q=zeros(ndof)
    for (_,idx) in ids
        s=x[idx,1];b=6*(idx-1)
        q[b+1:b+6]=[poly(u,s),poly(v,s),poly(w,s),.37,-deriv(w,s),deriv(v,s)]
    end
    expected=.27*sum(integral_square(c) for c in (u,v,w))
    @test dot(q,M*q) ≈ expected rtol=2e-13
    @test M ≈ M' rtol=1e-14
    @test minimum(eigvals(Symmetric(Matrix(M)))) >= -1e-14
    torsion=zeros(ndof);torsion[4:6:end].=1.
    @test iszero(norm(M*torsion))
    # Documented native CBAR axial averaging (MSC Nastran 2023.2 Dynamic
    # Analysis User's Guide, p.26), independently reduced to the complete
    # two-element fixed/free axial characteristic polynomial.
    axial=[6*(ids[i]-1)+1 for i in (2,3)]
    axial_roots=sort(real.(eigvals(Matrix(K[axial,axial]),Matrix(M[axial,axial]))))
    @test axial_roots ≈ (70e9/2700).*[(528-288sqrt(2.))/49,(528+288sqrt(2.))/49] rtol=2e-13

    # Distributed NSM contributes to the same kinetic energy as rho*A.
    extra=deepcopy(model);extra["PBARLs"]["1"]["NSM"]=.27
    @test mass(extra) ≈ 2M rtol=2e-13
    nsm_only=deepcopy(extra);nsm_only["MATs"]["1"]["RHO"]=0.
    @test mass(nsm_only) ≈ M rtol=2e-13

    # The cardless and explicit negative convention stays translationally
    # lumped, with no spurious rotational inertia or off-diagonal blocks.
    lumped=deepcopy(model);lumped["PARAM_COUPMASS"]=-1
    Ml=mass(lumped)
    delete!(lumped,"PARAM_COUPMASS")
    @test mass(lumped) == Ml
    @test Ml == Diagonal(diag(Ml))
    @test all(iszero,diag(Ml)[[6*(i-1)+j for i in 1:3 for j in 4:6]])
    @test diag(Ml)[1:6:end] ≈ [.0675,.135,.0675]
    # Released coupled mass needs a separately verified element interpolation;
    # fail explicitly while preserving the established released lumped path.
    for flag in ("PA","PB")
        released=deepcopy(model);released["CBARs"]["1"][flag]=5
        @test_throws ArgumentError mass(released)
        released["PARAM_COUPMASS"]=-1
        @test mass(released) == Ml
    end

    # With equal transverse offsets, the line mass moves rigidly to z=h.
    # Its six rigid-motion mass moments follow the parallel-axis theorem.
    shifted=deepcopy(model);h=.1
    for bar in values(shifted["CBARs"])
        bar["WA"]=[0.,0.,h];bar["WB"]=[0.,0.,h]
    end
    rigid=zeros(ndof,6)
    for (_,idx) in ids
        b=6*(idx-1);position=vec(x[idx,:])
        for j in 1:3
            axis=Float64.(collect(1:3).==j)
            rigid[b+1:b+3,j]=axis
            rigid[b+1:b+3,j+3]=cross(axis,position)
            rigid[b+4:b+6,j+3]=axis
        end
    end
    M0=rigid'*mass(shifted)*rigid
    @test M0[1:3,1:3] ≈ .27*Matrix{Float64}(I,3,3) atol=1e-14
    @test M0[1,5] ≈ .27h atol=1e-14
    @test M0[2,4] ≈ -.27h atol=1e-14
    @test M0[4,4] ≈ .27h^2 atol=1e-14
    @test M0[5,5] ≈ .27*(1/3+h^2) atol=1e-14
    @test M0[6,6] ≈ .27/3 atol=1e-14
    @test M0[4,6] ≈ -.27h/2 atol=1e-14
end
