using Test
module PcompConstitutiveFrameRecoveryFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver
const F=S.FEM
function model_file(dir,tag;mcid=false,coupled=false,isotropic=false,rotation=Matrix{Float64}(I,3,3))
    xy=[0. 0. 0.;1. 0. 0.;.7 .5 0.;.1 .5 0.]
    text="SOL 105\nCEND\nBEGIN BULK\nPARAM,K6ROT,0.\nPARAM,SNORM,0.\n"
    for i=1:4
        xyz=rotation*xy[i,:];text*="GRID,$i,,"*join(xyz,",")*"\n"
    end
    z=rotation*[0.,0.,1.];axis=rotation*[cospi(1/6),sinpi(1/6),0.]
    text*="CORD2R,777,,0.,0.,0.,"*join(z,",")*"\n+,"*join(axis,",")*"\n"
    text*="CQUAD4,1,101,1,2,3,4,"*(mcid ? "777" : "30.")*"\n"
    text*=isotropic ? "MAT1,80,7.E10,,.3,1600.\n" : "MAT8,80,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.\n"
    text*=coupled ? "PCOMP,101,-.001\n+,80,.0008,0.,YES,80,.0012,45.,YES\n" : "PCOMP,101,-.001\n+,80,.002,0.,YES\n"
    path=joinpath(dir,tag*".bdf");write(path,text*"ENDDATA\n")
    OpenJFEM.bdf_to_model(path),xy*rotation'
end

function recovered(model,X,u)
    ids=Dict(i=>i for i=1:4);Rs=[Matrix{Float64}(I,3,3) for _=1:4]
    result=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in ("forces","forces_bilin","stresses","strains"))
    properties=deepcopy(model["PSHELLs"])
    S.recover_shell_stresses!(model,ids,X,Rs,u,Dict{Int,typeof(OpenJFEM.SVector(0.,0.,0.))}(),Dict{Int,Float64}(),result)
    @test isequal(model["PSHELLs"],properties)
    result
end

function compare_fields(a,b)
    if a isa AbstractDict
        @test keys(a)==keys(b);foreach(k->compare_fields(a[k],b[k]),keys(a))
    elseif a isa AbstractArray
        @test length(a)==length(b);foreach(p->compare_fields(p...),zip(a,b))
    elseif a isa Number
        @test isapprox(a,b;rtol=2e-10,atol=1e-9)
    else
        @test a==b
    end
end

function recovery_checks()
    mktempdir() do dir
        u=1e-5sin.(collect(1.:24.))
        psi=.37;rotation=[cos(psi) -sin(psi) 0.;sin(psi) cos(psi) 0.;0. 0. 1.]
        ur=copy(u);for i=1:4,off in (0,3);r=6(i-1)+off+1:6(i-1)+off+3;ur[r]=rotation*u[r];end
        for coupled in (false,true)
            m,X=model_file(dir,"theta";coupled=coupled)
            n,Y=model_file(dir,"mcid";mcid=true,coupled=coupled)
            o,Z=model_file(dir,"rotated";coupled=coupled,rotation=rotation)
            a=recovered(m,X,u);b=recovered(n,Y,u);c=recovered(o,Z,ur)
            for key in ("forces","stresses","strains")
                compare_fields(a[key]["quad4"],b[key]["quad4"])
                compare_fields(a[key]["quad4"],c[key]["quad4"])
            end
            @test S._buckling_local_rhs_has_operator_gap(m)
            minimal=Dict{String,Any}("model"=>m,"id_map"=>Dict(i=>i for i=1:4),"node_coords"=>X)
            @test_throws ErrorException S._solve_adjoint_buckling_case(minimal,Dict("design_variables"=>[Dict("type"=>"bar_area","pids"=>[99])]))
            @test_throws ArgumentError S.analytic_shell_constitutive(m,101)
            # Alternate recovery branches must also leave model tensors intact.
            withenv("JFEM_Q4_KERNEL_STATIC"=>"mitc") do;recovered(m,X,u);end
        end
        m,_=model_file(dir,"isotropic";isotropic=true)
        @test m["PSHELLs"]["101"]["IS_ISOTROPIC"]
        @test !S._buckling_local_rhs_has_operator_gap(m)
    end
end

@testset "PCOMP constitutive frame recovery" begin
    recovery_checks()
end
end
