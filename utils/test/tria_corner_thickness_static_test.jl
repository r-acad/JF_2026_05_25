using Test
module TriaCornerThicknessStaticFixture
using Test,LinearAlgebra,StaticArrays,OpenJFEM
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver
const E=69e9
const NU=.27
const C=E/(1-NU^2)*[1. NU 0.;NU 1. 0.;0. 0. (1-NU)/2]
const XY=[0. 0.;.87 0.;.21 .64]
const TI=[.0021,.0047,.0032]
function model(path;ti=TI,rotation=Matrix{Float64}(I,3,3),sol=101,mpc=true)
    xyz=hcat(XY,zeros(3))*rotation'
    zz=rotation[:,3];xx=rotation[:,1]
    lines=["SOL $sol","CEND","SPC=1","MPC=2","LOAD=3","BEGIN BULK",
        "PARAM,SNORM,0.","PARAM,K6ROT,0.","PARAM,AUTOSPC,NO",
        "CORD2R,10,0,0.,0.,0.,$(join(zz,','))","+,$(join(xx,','))",
        "MAT1,1,$E,,$NU,2700.","PSHELL,1,1,.003,1,,1"]
    for i=1:3;push!(lines,"GRID,$i,,$(join(xyz[i,:],',')),10");end
    append!(lines,["GRID,4,,0.,0.,0.,10","CTRIA3,1,1,1,2,3,,,",
        "+,,0,$(join(ti,','))","SPC1,1,123456,1","SPC1,1,23456,2",
        "SPC1,1,13456,3","SPC1,1,23456,4",
        "MPC,2,2,1,1.,4,1,-1.","MPC,2,3,2,1.,4,1,-.7",
        "FORCE,3,4,10,1.,1.,0.,0.","ENDDATA"])
    mpc || filter!(line -> !(line=="MPC=2" || startswith(line,"MPC,")),lines)
    write(path,join(lines,'\n')*"\n")
    OpenJFEM.bdf_to_model(path)
end
function assembled(m)
    K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(m;snorm_angle_override=0.)
    (K=Matrix(K),ids=ids,X=X,nd=nd,R=R,normals=normals,mapping=mapping)
end
function recover(m,a,u)
    rows=Dict{String,Any}(k=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
    S.recover_shell_stresses!(m,a.ids,a.X,a.R,u,a.normals,Dict{Int,Float64}(),rows)
    rows
end
function checks()
    section=F.tria3_corner_thickness_section(TI)
    @test section.mean_thickness==sum(TI)/3
    midpoint=[(TI[1]+TI[2])/2,(TI[2]+TI[3])/2,(TI[3]+TI[1])/2]
    @test section.mean_cube==sum(midpoint.^3)/3
    @test section.mean_cube>section.mean_thickness^3
    @test F.tria3_corner_thickness_section(fill(.004,3)).bending_scale==1.
    @test_throws ArgumentError F.tria3_corner_thickness_section([.001,0.,.003])
    @test_throws DimensionMismatch F.tria3_corner_thickness_section([.001,.002])
    axis=normalize([.3,-.6,.7]);angle=.63
    skew=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
    rotation=Matrix{Float64}(I,3,3)+sin(angle)*skew+(1-cos(angle))*skew^2
    area=.87*.64/2
    mktempdir() do dir
        m=model(joinpath(dir,"triangle.bdf");mpc=false);before=deepcopy(m["PSHELLs"])
        a=assembled(m)
        @test m["PSHELLs"]==before
        @test isapprox(a.K,a.K';rtol=2e-13)
        @test minimum(eigvals(Symmetric(a.K)))>=-3e-12opnorm(a.K)
        e=[.0004,-.0002,.0003];kap=[.0017,-.0009,.0011]
        u=zeros(a.nd)
        for i=1:3
            x,y=XY[i,:];n=a.ids[i]
            u[6n-5:6n-3]=[e[1]*x+e[3]*y/2,e[2]*y+e[3]*x/2,0.]
        end
        @test isapprox(dot(u,a.K*u),area*section.mean_thickness*dot(e,C*e);rtol=3e-12)
        for i=1:3
            x,y=XY[i,:];n=a.ids[i]
            u[6n-2:6n]=[-kap[2]*y-kap[3]*x/2,kap[1]*x+kap[3]*y/2,0.]
        end
        rows=recover(m,a,u);force=only(rows["forces"]["tria3"])
        @test isapprox([force[k] for k in ("fx","fy","fxy")],section.mean_thickness*C*e;rtol=4e-12)
        @test isapprox([force[k] for k in ("mx","my","mxy")],-section.mean_cube/12*C*kap;rtol=4e-12)
        f=a.K*u
        q=[sum(XY[i,j]*f[6a.ids[i]-3] for i=1:3)/area for j=1:2]
        @test isapprox([force["qx"],force["qy"]],q;rtol=3e-11,atol=1e-10)
        stress=only(rows["stresses"]["tria3"])
        for (face,z) in (("z1",-section.mean_thickness/2),("z2",section.mean_thickness/2))
            @test stress[face]["fiber_dist"]==z
            @test isapprox([stress[face][k] for k in ("normal_x","normal_y","shear_xy")],C*(e+z*kap);rtol=4e-12)
        end
        @test m["PSHELLs"]==before
        for ti in (TI[[2,3,1]],TI[[3,1,2]],TI[[3,2,1]])
            am=assembled(model(joinpath(dir,"permuted.bdf");ti=ti,mpc=false))
            @test isapprox(am.K,a.K;rtol=4e-13)
        end
        # Explicit uniform Ti reuses the original constant section exactly.
        uniform=model(joinpath(dir,"uniform.bdf");ti=fill(.004,3),mpc=false)
        ordinary=deepcopy(uniform);delete!(ordinary["CSHELLs"]["1"],"CORNER_THICKNESSES")
        ordinary["PSHELLs"]["1"]["T"]=.004
        @test assembled(uniform).K==assembled(ordinary).K
        # A real two-equation MPC and its load are rotated with the GRID frame.
        # The remaining single generalized coordinate has stiffness v'Kv.
        constrained=model(joinpath(dir,"constrained.bdf"));ac=assembled(constrained)
        v=zeros(a.nd);v[6a.ids[2]-5]=1.;v[6a.ids[3]-4]=.7;v[6a.ids[4]-5]=1.
        expected=inv(dot(v,ac.K*v))
        @test isapprox(dot(v,ac.K*v),dot(v,a.K*v);rtol=4e-13)
        r=OpenJFEM.solve_model(constrained);sol=only(r["subcases"]);ur=sol["raw_displacement"]
        @test isapprox(ur,v*expected;rtol=5e-11,atol=1e-18)
        @test isapprox(dot(ur,ac.K*ur),ur[6a.ids[4]-5];rtol=4e-11)
        mr=model(joinpath(dir,"rotated.bdf");rotation=rotation);ar=assembled(mr)
        @test isapprox(ar.K,ac.K;rtol=5e-13)
        rr=OpenJFEM.solve_model(mr);urr=only(rr["subcases"])["raw_displacement"]
        # Public static displacement rows are BASIC vectors.
        T=kron(Matrix{Float64}(I,2length(a.ids),2length(a.ids)),rotation)
        @test isapprox(urr,T*ur;rtol=8e-10,atol=1e-17)
        for badsol in (103,105,106)
            bad=deepcopy(m);bad["SOL"]=badsol
            @test_throws ArgumentError assembled(bad)
        end
        bad=deepcopy(m);bad["PSHELLs"]["1"]["MID4"]=1
        @test_throws ArgumentError assembled(bad)
        bad=deepcopy(m);bad["GRAVs"]=Dict("1"=>Dict())
        @test_throws ArgumentError assembled(bad)
        @test_throws ArgumentError S.assemble_modal_mass(m,a.ids,a.X,a.R,a.nd)
        kg_error=try
            S.assemble_geometric_stiffness(m,a.ids,a.X,a.R,a.nd,zeros(a.nd),a.normals,a.mapping;snorm_angle_override=0.)
            nothing
        catch error
            error
        end
        # Threaded assembly preserves the guard as a nested task exception.
        @test kg_error isa Union{ArgumentError,CompositeException,TaskFailedException}
        @test occursin("nonuniform corner-thickness geometric stiffness is not implemented",sprint(showerror,kg_error))
        @test_throws ArgumentError S.assert_no_corner_thickness_analytic(m)
    end
end
end
@testset "Static triangle corner-thickness section and recovery" begin
    TriaCornerThicknessStaticFixture.checks()
end
