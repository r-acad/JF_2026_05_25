using Test
module ExplicitShellNormalFixture
using Test,OpenJFEM,LinearAlgebra,StaticArrays,Random,JSON
const S=OpenJFEM.Solver;const P=OpenJFEM.ReferenceParser;const F=OpenJFEM.FEM

function model(dir;cards="",angle=0.,cords="",points=[1. 2. 3.;2. 2. 3.;2. 3. 3.;1. 3. 3.])
    text="SOL 101\nCEND\nBEGIN BULK\nPARAM,SNORM,$angle\nPARAM,K6ROT,1.\n"
    for i=1:4
        text*="GRID,$i,,"*join(points[i,:],",")*"\n"
    end
    text*=cords*"CQUAD4,1,1,1,2,3,4\nMAT1,1,70000.,,.3,2.7\nPSHELL,1,1,.03,1,,1\n"*cards*"ENDDATA\n"
    path=joinpath(dir,"prescribed_normal.bdf");write(path,text)
    OpenJFEM.bdf_to_model(path)
end
ids=Dict(i=>i for i=1:4)
function coordinates(m)
    reduce(vcat,[permutedims(Float64.(m["GRIDs"][string(i)]["X"])) for i=1:4])
end
normals(m)=S.compute_snorm_normals(m,ids,coordinates(m))

function checks()
    mktempdir() do dir
        # Free, small fixed and continued large fields encode the same input.
        free="SNORM,1,,2.,3.,4.\n"
        small=rpad("SNORM",8)*join(lpad.(string.([1,0,2.,3.,4.]),8))*"\n"
        large=rpad("SNORM*",8)*join(lpad.(string.([1,0,2.,3.]),16))*"\n"*rpad("*",8)*lpad("4.",16)*"\n"
        for card in (free,small,large)
            m=model(dir;cards=card)
            @test m["SNORMs"]["1"]==Dict("GID"=>1,"CID"=>0,"N"=>[2.,3.,4.])
            @test normals(m)[1] ≈ normalize([2.,3.,4.])
            @test length(normals(m))==1
            @test JSON.parse(JSON.json(m))["SNORMs"]["1"]["N"]==[2.,3.,4.]
        end
        # Every blank component defaults to zero; scale is physically irrelevant.
        for scale in (1e-300,1.,1e300)
            m=model(dir;cards="SNORM,1,0,$scale,,$(2scale)\n")
            @test normals(m)[1] ≈ normalize([1.,0.,2.])
        end
        m=model(dir;cards="SNORM,1,0,.5,0.,.8660254037844386\n",angle=20.)
        @test normals(m)[1] ≈ [.5,0.,sqrt(3.)/2]
        @test normals(m)[2]==SVector(0.,0.,1.)
        # Prescribed tilt exceeds the generated tolerance and remains accepted.
        @test dot(normals(m)[1],SVector(0.,0.,1.))<cosd(20.)
        m["PARAM_SNORM"]=0.;@test length(normals(m))==1
        m["PARAM_SNORM"]=-1.;@test isempty(normals(m))
        m["PARAM_SNORM"]=20.
        @test isempty(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=-1.))
        @test length(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=0.))==1

        # Scoped guard parameters follow the same common override precedence
        # as forward assembly, including invalid generic values falling back.
        m["PARAM_SNORM"]=-1.
        withenv("JFEM_PARAM_SNORM_OVERRIDE"=>"0", "JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"-1",
                "JFEM_PARAM_SNORM_OVERRIDE_EIG"=>"-1", "JFEM_PARAM_SNORM_OVERRIDE_KG"=>"-1") do
            @test length(normals(m))==1
            @test length(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=-1.))==1
            dv=Dict{String,Any}("type"=>"shell_thickness","pids"=>[1])
            @test_throws ErrorException S._guard_mapped_quad4_local_dkdx!(dv,m,ids,coordinates(m))
            @test S._adjoint_has_active_completed_q4_snorm(m,ids,coordinates(m))
        end
        withenv("JFEM_PARAM_SNORM_OVERRIDE"=>"-1", "JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"20",
                "JFEM_PARAM_SNORM_OVERRIDE_EIG"=>"20", "JFEM_PARAM_SNORM_OVERRIDE_KG"=>"20") do
            @test isempty(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=20.))
            dv=Dict{String,Any}("type"=>"shell_thickness","pids"=>[1])
            @test S._guard_mapped_quad4_local_dkdx!(dv,m,ids,coordinates(m))===nothing
            @test !S._adjoint_has_active_completed_q4_snorm(m,ids,coordinates(m))
        end
        withenv("JFEM_PARAM_SNORM_OVERRIDE"=>"invalid") do
            @test length(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=0.))==1
            @test isempty(S.compute_snorm_normals(m,ids,coordinates(m);angle_deg=-1.))
        end
        m["PARAM_SNORM"]=20.

        # Rectangular, nested, cylindrical and spherical input frames act on
        # vectors at the GRID, independently of its displacement coordinate CD.
        rect="CORD2R,10,0,1.,-2.,3.,1.,-2.,4.\n+,1.,-1.,3.\n"
        r=model(dir;cords=rect,cards="SNORM,1,10,2.,3.,4.\n")
        @test normals(r)[1] ≈ normalize([-3.,2.,4.])
        r["GRIDs"]["1"]["CD"]=10
        @test normals(r)[1] ≈ normalize([-3.,2.,4.])
        nested=rect*"CORD2R,11,10,0.,0.,0.,0.,0.,1.\n+,1.,0.,0.\n"
        r=model(dir;cords=nested,cards="SNORM,1,11,2.,3.,4.\n")
        @test normals(r)[1] ≈ normalize([-3.,2.,4.])
        for ctype in ('C','S')
            cords="CORD2$ctype,10,0,0.,0.,0.,0.,0.,1.\n+,1.,0.,0.\n"
            cards=join(["SNORM,$i,10,1.,0.,$(ctype=='C' ? 1. : 0.)\n" for i=1:4])
            r=model(dir;cords=cords,cards=cards)
            for i=1:4
                x=coordinates(r)[i,:]
                expected=ctype=='C' ? normalize([x[1]/hypot(x[1],x[2]),x[2]/hypot(x[1],x[2]),1.]) : normalize(x)
                @test normals(r)[i] ≈ expected
            end
            # Nonradial tangent components are evaluated at each separate GRID.
            r["SNORMs"]["1"]["N"]=ctype=='C' ? [0.,1.,1.] : [0.,1.,0.]
            x=coordinates(r)[1,:];rho=hypot(x[1],x[2]);radius=norm(x)
            expected=ctype=='C' ? normalize([-x[2]/rho,x[1]/rho,1.]) : [x[3]*x[1]/(rho*radius),x[3]*x[2]/(rho*radius),-rho/radius]
            @test normals(r)[1] ≈ expected
        end
        # Raw JSON follows the same model contract and preserves normals.
        raw=Dict("case_control"=>Dict("SOL"=>101),"parameters"=>Dict("SNORM"=>0.),
            "bulk_data"=>Dict("GRID"=>deepcopy(m["GRIDs"]),"CQUAD4"=>deepcopy(m["CSHELLs"]),
                "SNORM"=>Dict("1"=>Dict("CID"=>0,"N1"=>.5,"N3"=>sqrt(3.)/2))))
        from_json=OpenJFEM.build_model_from_json(raw)
        @test from_json["SNORMs"]["1"]["GID"]==1
        @test normals(from_json)[1] ≈ [.5,0.,sqrt(3.)/2]
        raw["bulk_data"]["SNORM"]["1"]["GID"]=2
        @test_throws ArgumentError OpenJFEM.build_model_from_json(raw)

        # Undefined active directions are rejected, while PARAM<0 ignores
        # their semantic contents as specified by the card precedence rule.
        for card in ("SNORM,1,0,0.,0.,0.\n","SNORM,1,77,1.,0.,0.\n","SNORM,99,0,1.,0.,0.\n")
            r=model(dir;cards=card)
            @test_throws ArgumentError normals(r)
            r["PARAM_SNORM"]=-1.
            @test isempty(normals(r))
        end
        for card in ("SNORM,0,0,1.,0.,0.\n","SNORM,1,-1,1.,0.,0.\n", "SNORM,1.5,0,1.,0.,0.\n",
                     "SNORM,1,0,garbage,0.,1.\n","SNORM,1,0,NaN,0.,1.\n",
                     "SNORM,1,0,1.,0.,0.\nSNORM,1,0,0.,1.,0.\n")
            @test_throws ArgumentError model(dir;cards=card)
        end
        r=model(dir;cards="SNORM,1,77,0.,0.,0.\n")
        r["CSHELLs"]["1"]["TYPE"]="CSHEAR"
        @test isempty(normals(r))
        r["CSHELLs"]["1"]["TYPE"]="CQUAD8"
        @test isempty(normals(r))
        r["CSHELLs"]["2"]=deepcopy(r["CSHELLs"]["1"])
        r["CSHELLs"]["2"]["TYPE"]="CQUAD4"
        @test_throws ArgumentError normals(r)

        # A prescribed tangent direction must not be silently discarded by
        # the existing slope-map denominator guard, for either shell topology.
        for kind in ("CQUAD4","CTRIA3"),normal in ([1.,0.,0.],[1.,0.,1e-4])
            r=model(dir;cards="SNORM,1,0,"*join(normal,",")*"\n")
            r["CSHELLs"]["1"]["TYPE"]=kind
            kind=="CTRIA3" && (r["CSHELLs"]["1"]["NODES"]=[1,2,3])
            error=try normals(r);nothing catch caught;caught end
            @test error isa ArgumentError
            @test occursin("GRID 1",sprint(showerror,error))
            @test occursin("EID=1",sprint(showerror,error))
            r["PARAM_SNORM"]=-1.
            @test isempty(normals(r))
        end

        # Proper rigid rotations of geometry and BASIC prescribed vectors
        # commute with normalization and the physical work map.
        rng=MersenneTwister(39841)
        points=[0. 0. 0.;1.2 0. 0.;1.1 .8 0.;-.1 .7 0.]
        prescribed=normalize([.3,-.2,1.])
        cards=join(["SNORM,$i,0,"*join(prescribed,",")*"\n" for i=1:4])
        m=model(dir;cards=cards,points=points)
        a=S.assemble_stiffness(m;sol101_context=true)
        K,aid,X,ndof,R,_,_,field=a[1:8]
        @test Set(keys(field))==Set(1:4)
        @test all(n->isapprox(n,prescribed;rtol=2e-14),values(field))
        plain=deepcopy(m);empty!(plain["SNORMs"])
        base=S.assemble_stiffness(plain;sol101_context=true)[1]
        @test norm(K-base)>1e-5norm(base)
        @test norm(K-K')<1e-12norm(K)
        @test minimum(eigvals(Symmetric(Matrix(K))))>-1e-11norm(K)
        for axis in eachcol(Matrix{Float64}(I,3,3))
            rigid=vcat([vcat(cross(axis,X[i,:]),axis) for i=1:4]...)
            @test norm(K*rigid)<2e-12norm(K)*norm(rigid)
        end
        Q=Matrix(qr(randn(rng,3,3)).Q);det(Q)<0 && (Q[:,1].*=-1)
        rotated_cards=join(["SNORM,$i,0,"*join(Q*prescribed,",")*"\n" for i=1:4])
        rotated=model(dir;cards=rotated_cards,points=points*Q')
        Kr=S.assemble_stiffness(rotated;sol101_context=true)[1]
        T=kron(Matrix{Float64}(I,8,8),Q)
        @test isapprox(Kr,T*K*T';rtol=3e-12,atol=3e-10)
        u=randn(rng,24);v=randn(rng,24)
        @test isapprox(dot(T*v,Kr*(T*u)),dot(v,K*u);rtol=3e-12,atol=3e-10)

        # The local derivative builders must see explicit normals even with
        # PARAM=0. A negative parameter removes those same guarded maps.
        dv=Dict{String,Any}("type"=>"shell_thickness","pids"=>[1])
        @test_throws ErrorException S._guard_mapped_quad4_local_dkdx!(dv,m,aid,X)
        @test S._adjoint_has_active_completed_q4_snorm(m,aid,X)
        m["PARAM_SNORM"]=-1.
        @test S._guard_mapped_quad4_local_dkdx!(dv,m,aid,X)===nothing
        @test !S._adjoint_has_active_completed_q4_snorm(m,aid,X)
    end
end
end
@testset "Explicit shell normal parsing, coordinates and virtual work" begin
    ExplicitShellNormalFixture.checks()
end
