using Test,LinearAlgebra,SparseArrays
module CHAN2SectionFixture
using Test,LinearAlgebra,SparseArrays
include(joinpath(@__DIR__,"..","..","src","parsing","ReferenceParser.jl"))
const P=ReferenceParser

function polygon_properties(tw,tb,h,b)
    vertices=[(-b/2,0.),(b/2,0.),(b/2,h),(b/2-tw,h),
        (b/2-tw,tb),(-b/2+tw,tb),(-b/2+tw,h),(-b/2,h)]
    area=zfirst=yfirst=iyy=izz=iyz=0.
    for i in eachindex(vertices)
        z,y=vertices[i];zz,yy=vertices[mod1(i+1,length(vertices))]
        cross=z*yy-zz*y
        area+=cross/2;zfirst+=(z+zz)*cross/6;yfirst+=(y+yy)*cross/6
        iyy+=(z^2+z*zz+zz^2)*cross/12
        izz+=(y^2+y*yy+yy^2)*cross/12
        iyz+=(2z*y+z*yy+zz*y+2zz*yy)*cross/24
    end
    zc,yc=zfirst/area,yfirst/area
    return (;A=area,yc,I1=izz-area*yc^2,I2=iyy-area*zc^2,I12=iyz-area*yc*zc)
end

# Independent Prandtl stress-function check, using a five-point Dirichlet
# finite-difference grid rather than the production Neumann warping problem.
function prandtl_torsion(tw,tb,h,b,n)
    step=b/n;ny=round(Int,h/step);nt=round(Int,tw/step);nb=round(Int,tb/step)
    ids=zeros(Int,n+1,ny+1);nn=0
    for j in 1:ny-1,i in 1:n-1
        (j<nb || i<nt || i>n-nt) || continue
        nn+=1;ids[i+1,j+1]=nn
    end
    rows=Int[];cols=Int[];values=Float64[]
    for j in 1:ny-1,i in 1:n-1
        node=ids[i+1,j+1];node>0 || continue
        push!(rows,node);push!(cols,node);push!(values,4.)
        for (di,dj) in ((1,0),(-1,0),(0,1),(0,-1))
            neighbor=ids[i+1+di,j+1+dj];neighbor>0 || continue
            push!(rows,node);push!(cols,neighbor);push!(values,-1.)
        end
    end
    matrix=sparse(rows,cols,values,nn,nn)
    field=cholesky(Symmetric(matrix))\fill(2step^2,nn)
    return 2step^2*sum(field)
end

function checks()
    @testset "CHAN2 exact geometric properties and positional dimensions" begin
        for dims in ((.002,.002,.025,.0745),(.013,.022,.1,.12),(.12,.08,.31,.5))
            exact=P.chan2_section_geometry(dims...);polygon=polygon_properties(dims...)
            for key in (:A,:I1,:I2,:yc)
                @test getproperty(exact,key)≈getproperty(polygon,key) rtol=1e-12
            end
            @test abs(polygon.I12)<1e-14
        end
        dims=(.002,.002,.025,.0745)
        card=Any["SMALL","PBARL",11,1,"","CHAN2","","","","",dims...,.25]
        prop=P.extract_pbarl([card])["11"]
        @test prop["DIMS"]==collect(dims)
        @test prop["NSM"]==.25
        @test prop["TYPE"]=="CHAN2"
        @test prop["I12"]==0
        @test prop["C1"]==prop["F1"]==dims[3]-prop["SECTION_CENTROID_Y"]
        @test prop["D1"]==prop["E1"]==-prop["SECTION_CENTROID_Y"]
        @test prop["C2"]==prop["D2"]==dims[4]/2
        @test prop["E2"]==prop["F2"]==-dims[4]/2
        @test !haskey(prop,"N1A")
        beam=copy(card);beam[2]="PBEAML";beam[3]=12
        p=P.extract_pbeaml([beam])["12"]
        @test p["LIBRARY_CARD"]=="PBEAML"
        @test p["N1A"]==p["N1B"]>p["SECTION_CENTROID_Y"]>0
        @test p["N2A"]==p["N2B"]==0
        for key in ("A","I1","I2","I12","J","K1","K2","C1","C2","NSM")
            @test p[key]==prop[key]
        end
        compact=Any["SMALL","PBARL",13,1,"","CHAN2",dims...,.25]
        @test P.extract_pbarl([compact])["13"]["DIMS"]==collect(dims)
        missing=copy(card);missing[12]=""
        @test_throws ArgumentError P.extract_pbarl([missing])
        excess=copy(compact);push!(excess,1.)
        @test_throws ArgumentError P.extract_pbarl([excess])
        for invalid in ((0.,.1,.5,1.),(.1,-1.,.5,1.),(.6,.1,.5,1.),(.1,.6,.5,1.),(NaN,.1,.5,1.))
            @test_throws ArgumentError P.chan2_section_warping(invalid...)
        end
    end
    @testset "CHAN2 independent torsion problem and scale invariance" begin
        dims=(.1,.1,.5,1.)
        section=P.chan2_section_warping(dims...)
        coarse=prandtl_torsion(dims...,400)
        fine=prandtl_torsion(dims...,800)
        @test abs(fine/coarse-1)<.001
        @test isapprox(section.J,fine;rtol=.001)
        @test section.relative_change<=1e-4
        @test 0<section.K1<1 && 0<section.K2<1
        @test section.N1>P.chan2_section_geometry(dims...).yc
        scaled=P.chan2_section_warping((1000 .*dims)...)
        @test scaled.J≈1e12section.J rtol=1e-9
        @test scaled.N1≈1000section.N1 rtol=1e-9
        @test scaled.K1≈section.K1 rtol=1e-9
        @test scaled.K2≈section.K2 rtol=1e-9
        for rectangular in ((.5,.1,.5,1.),(.1,.5,.5,1.))
            limit=P.chan2_section_warping(rectangular...)
            reference=P._t_section_rectangle_limit(1.,.5)
            @test limit.J==reference.J
            @test limit.N1==0
            @test limit.K1==limit.K2==5/6
        end
    end
end
end
CHAN2SectionFixture.checks()
