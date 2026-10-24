using Test

module ShellReferenceOffsetFixture
using Test,OpenJFEM,LinearAlgebra,StaticArrays
const S=OpenJFEM.Solver

function fixture(dir,n,z;format=:free)
    connection=n==4 ? "CQUAD4,1,1,1,2,3,4,0.0,$z" : "CTRIA3,1,1,1,2,3,0.0,$z"
    if format==:large
        @assert n==4
        fields=("1","1","1","2","3","4","0.0",string(z))
        connection=rpad("CQUAD4*",8)*join(lpad.(fields[1:4],16))*"\n"*
            rpad("*",8)*join(lpad.(fields[5:8],16))
    elseif format==:small
        fields=n==4 ? ("1","1","1","2","3","4","0.0",string(z)) :
            ("1","1","1","2","3","0.0",string(z))
        connection=rpad(n==4 ? "CQUAD4" : "CTRIA3",8)*join(lpad.(fields,8))
    end
    file=joinpath(dir,"shell.bdf")
    write(file,"SOL 101\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,COUPMASS,1\n"*
        "GRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nGRID,3,,2.,1.,0.\n"*
        (n==4 ? "GRID,4,,0.,1.,0.\n" : "")*connection*"\n"*
        "PSHELL,1,1,.02,1,,1\nMAT1,1,70000000.,,.3,2700.\nENDDATA\n")
    OpenJFEM.bdf_to_model(file)
end

function recover(model,ids,X,R,u,snorm,n)
    output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in ("forces","forces_bilin","stresses","strains"))
    S.recover_shell_stresses!(model,ids,X,R,u,snorm,Dict{Int,Float64}(),output)
    only(output["forces"][n==4 ? "quad4" : "tria3"])
end

function checks()
    mktempdir() do dir
        for n in (3,4),format in (:free,:small),z in (-.04,.04)
            model=fixture(dir,n,z;format)
            @test only(values(model["CSHELLs"]))["ZOFFS"]==z
        end
        for z in (-.04,.04)
            model=fixture(dir,4,z;format=:large)
            @test only(values(model["CSHELLs"]))["ZOFFS"]==z
        end
        for n in (3,4)
            model=fixture(dir,n,0.)
            K,ids,X,ndof,R,_,rbe3,snorm,_=S.assemble_stiffness(model)
            M=S.assemble_modal_mass(model,ids,X,R,ndof)
            mapping=S.assemble_constraints(model,ids,X,R,Int[],Int[],Float64[])[1]
            surface=zeros(ndof)
            for i=1:n
                x,y=X[i,1:2]
                surface[6i-5:6i]=[.001*x+.0002*y,-.0003*y,.0001*x*y,.0002*y,-.0004*x,0.]
            end
            G=S.assemble_geometric_stiffness(model,ids,X,R,ndof,surface,snorm,mapping;snorm_angle_override=0.)
            baseline=recover(model,ids,X,R,surface,snorm,n)
            for z in (-.04,.04)
                offset=deepcopy(model);only(values(offset["CSHELLs"]))["ZOFFS"]=z
                O=Matrix{Float64}(I,ndof,ndof)
                for i=1:n
                    O[6i-5,6i-1]=z
                    O[6i-4,6i-2]=-z
                end
                grid=O\surface
                Kz=S.assemble_stiffness(offset)[1]
                @test isapprox(Matrix(Kz),O'*K*O;rtol=2e-12,atol=1e-9)
                @test isapprox(dot(grid,Kz*grid),dot(surface,K*surface);rtol=2e-12)
                # ZOFFS has no mass relocation; explicit rigid links are a
                # different model with a different inertia convention.
                @test S.assemble_modal_mass(offset,ids,X,R,ndof)==M
                Gz=S.assemble_geometric_stiffness(offset,ids,X,R,ndof,grid,snorm,mapping;snorm_angle_override=0.)
                @test isapprox(Matrix(Gz),O'*G*O;rtol=2e-10,atol=1e-9)
                fields=recover(offset,ids,X,R,grid,snorm,n)
                for key in ("fx","fy","fxy","mx","my","mxy")
                    @test isapprox(fields[key],baseline[key];rtol=2e-10,atol=1e-9)
                end
            end
        end
        # Arbitrary GRID coordinate rotations preserve rigid-arm work.
        Q=Matrix(qr([1. .3 -.2;.2 1. .4;.1 -.3 1.]).Q)
        O=Matrix{Float64}(I,6,6);O[1:3,4:6]=-S.skew3(SVector(0.,0.,.07))
        T=zeros(6,6);T[1:3,1:3]=Q;T[4:6,4:6]=Q
        @test isapprox(S.shell_reference_offset_transform!(copy(T),.07),O*T;atol=1e-15)
        u=[.2,-.1,.4,.05,-.06,.02]
        @test S.shell_reference_offset_displacement!(copy(u),.07)≈O*u
        @test_throws ArgumentError S.shell_reference_offset_transform!(copy(T),NaN)
    end
end
end

@testset "Shell reference-surface offsets preserve physical work" begin
    ShellReferenceOffsetFixture.checks()
end
