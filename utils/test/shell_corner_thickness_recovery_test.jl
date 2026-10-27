using Test, LinearAlgebra, StaticArrays, OpenJFEM

module ShellCornerThicknessRecoveryFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
const ep=[1.2e-4,-3e-5,7e-5]
const kap=[.002,-.0007,.0011]
const XY=[-1. -.4;1. -.4;1. .4;-1. .4]
function make_model(dir,orthotropic=false;rotation=Matrix{Float64}(I,3,3),offset=0.)
    X=hcat(XY,zeros(4))*rotation'
    path=joinpath(dir,"corner_recovery.bdf")
    open(path,"w") do io
        print(io,"SOL 101\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\n")
        for k=1:4;println(io,join(["GRID",k,"",X[k,:]...],','));end
        if orthotropic
            print(io,"MAT8,1,1.3E11,8.E9,.27,4.7E9,3.E9,2.E9\n")
        else
            print(io,"MAT1,1,7.E10,,.3\n")
        end
        print(io,"PSHELL,1,1,.02,1,,1\nCQUAD4,1,1,1,2,3,4\nENDDATA\n")
    end
    m=OpenJFEM.bdf_to_model(path);m["CSHELLs"]["1"]["ZOFFS"]=offset
    ids=Dict(i=>i for i=1:4);R=[Matrix{Float64}(I,3,3) for _=1:4]
    u=zeros(24)
    for i=1:4
        x,y=XY[i,:]
        theta=[-kap[2]*y-kap[3]*x/2,kap[1]*x+kap[3]*y/2,0.]
        displacement=[ep[1]*x+ep[3]*y/2,ep[2]*y+ep[3]*x/2,
            -kap[1]*x^2/2-kap[2]*y^2/2-kap[3]*x*y/2]
        displacement-=cross(theta,[0.,0.,offset])
        u[6i-5:6i-3]=rotation*displacement;u[6i-2:6i]=rotation*theta
    end
    C=if orthotropic
        den=1-.27^2*8e9/1.3e11
        [1.3e11/den .27*8e9/den 0.;.27*8e9/den 8e9/den 0.;0. 0. 4.7e9]
    else
        7e10/(1-.3^2)*[1. .3 0.;.3 1. 0.;0. 0. (1-.3)/2]
    end
    m,ids,X,R,u,C
end
function recover(m,ids,X,R,u;compact=false,snorm=Dict{Int,SVector{3,Float64}}())
    out=Dict{String,Any}(k=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
    fields=Dict{Int,Any}();stress=Dict{Int,Float64}()
    S.recover_shell_stresses!(m,ids,X,R,u,snorm,stress,out;
        static_fields=compact ? fields : nothing,static_fields_capture=compact ? nothing : fields)
    out,fields
end
values3(row)=[row[k] for k in ("normal_x","normal_y","shear_xy")]
function checks()
    tilt=.43;spin=.27
    Q=[cos(spin) -sin(spin) 0.;sin(spin) cos(spin) 0.;0. 0. 1.]*
        [1. 0. 0.;0. cos(tilt) -sin(tilt);0. sin(tilt) cos(tilt)]
    ti=[.012,.021,.031,.018];h=sum(ti)/4
    p=1/sqrt(3.);cube=sum((dot([(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]/4,ti))^3 for r in (-p,p),s in (-p,p))/4
    mktempdir() do dir
        for orthotropic in (false,true), rotation in (Matrix{Float64}(I,3,3),Q),offset in (0.,.013)
            m,ids,X,R,u,C=make_model(dir,orthotropic;rotation=rotation,offset=offset)
            m["CSHELLs"]["1"]["CORNER_THICKNESSES"]=copy(ti)
            m["CSHELLs"]["1"]["TFLAG"]=0
            before=deepcopy(m["PSHELLs"])
            out,fields=recover(m,ids,X,R,u)
            _,compact=recover(m,ids,X,R,u;compact=true)
            @test fields==compact
            @test m["PSHELLs"]==before
            @test isapprox(OpenJFEM._buckling_element_volume(m,"CSHELLs",m["CSHELLs"]["1"]),1.6h;rtol=3e-14)
            row=only(out["forces"]["quad4"])
            @test isapprox([row[k] for k in ("fx","fy","fxy")],h*C*ep;rtol=3e-12)
            @test isapprox([row[k] for k in ("mx","my","mxy")],-cube/12*C*kap;rtol=3e-12)
            stress=only(out["stresses"]["quad4"]);strain=only(out["strains"]["quad4"])
            for (name,z) in (("z1",-h/2),("z2",h/2))
                @test isapprox(stress[name]["fiber_dist"],z;rtol=4eps(Float64))
                @test isapprox(values3(stress[name]),C*(ep+z*kap);rtol=3e-12)
            end
            @test isapprox(values3(strain["z1"]),ep;rtol=3e-12)
            @test isapprox(values3(strain["z2"]),-kap;rtol=3e-12)
            @test isempty(out["forces_bilin"]["quad4"])
            @test out["recovery_diagnostics"]["unavailable_corner_force_eids"]==[1]
            m["PSHELLs"]["1"]["Z1"]=-.007;m["PSHELLs"]["1"]["Z2"]=.019
            m["PSHELLs"]["1"]["Z1_DEFAULT"]=false;m["PSHELLs"]["1"]["Z2_DEFAULT"]=false
            explicit,_=recover(m,ids,X,R,u);row=only(explicit["stresses"]["quad4"])
            for (name,z) in (("z1",-.007),("z2",.019))
                @test row[name]["fiber_dist"]==z
                @test isapprox(values3(row[name]),C*(ep+z*kap);rtol=3e-12)
            end
            # Fractional Ti has identical physical output.
            m["CSHELLs"]["1"]["CORNER_THICKNESSES"]=ti/.02;m["CSHELLs"]["1"]["TFLAG"]=1
            fractional,_=recover(m,ids,X,R,u)
            frac=only(fractional["stresses"]["quad4"])
            for name in ("z1","z2")
                @test isapprox(values3(frac[name]),values3(row[name]);rtol=3e-13)
            end
        end
        for orthotropic in (false,true)
            m,ids,X,R,u,_=make_model(dir,orthotropic)
            m["CSHELLs"]["1"]["CORNER_THICKNESSES"]=fill(.017,4)
            m["CSHELLs"]["1"]["TFLAG"]=0
            uniform,_=recover(m,ids,X,R,u)
            @test m["PSHELLs"]["1"]["T"]==.02
            @test isapprox(OpenJFEM._buckling_element_volume(m,"CSHELLs",m["CSHELLs"]["1"]),1.6*.017;rtol=3e-14)
            delete!(m["CSHELLs"]["1"],"CORNER_THICKNESSES");m["PSHELLs"]["1"]["T"]=.017
            reference,_=recover(m,ids,X,R,u)
            @test uniform==reference
        end
        m,ids,X,R,u,C=make_model(dir)
        m["CSHELLs"]["1"]["CORNER_THICKNESSES"]=copy(ti)
        snorm=Dict(i=>SVector(0.,0.,1.) for i=1:4)
        flat,_=recover(m,ids,X,R,u;snorm=snorm);plain,_=recover(m,ids,X,R,u)
        @test flat==plain
        for mutation in (
                a->(a["SOL"]=106),
                a->(a["PSHELLs"]["1"]["MID2"]=0),
                a->(a["PSHELLs"]["1"]["MID3"]=0),
                a->(a["PSHELLs"]["1"]["MID4"]=1),
                a->(a["_active_temp_sid"]=1))
            bad=deepcopy(m);mutation(bad)
            @test_throws ArgumentError recover(bad,ids,X,R,u)
        end
        badX=copy(X);badX[3,1]+=.1
        distorted,distorted_fields=recover(m,ids,badX,R,u)
        @test length(distorted["forces"]["quad4"])==1
        @test length(distorted["stresses"]["quad4"])==1
        @test length(distorted["strains"]["quad4"])==1
        @test all(isfinite,values3(only(distorted["stresses"]["quad4"])["z1"]))
        @test all(isfinite,values3(only(distorted["stresses"]["quad4"])["z2"]))
        @test haskey(distorted_fields,1)
        badX=X[[1,3,2,4],:]
        @test_throws ArgumentError recover(m,ids,badX,R,u)
        # A saddle warp uses the same projected strain field when nodal motion
        # is pulled back through the finite-warp map. Verify the physical
        # membrane, moment and fiber outputs, including basic-frame rotation.
        for orthotropic in (false,true),height in (-.03,.03),rotation in (Matrix{Float64}(I,3,3),Q)
            warped_model,_,_,_,warped_u,warped_C=make_model(dir,orthotropic)
            warped_model["CSHELLs"]["1"]["CORNER_THICKNESSES"]=copy(ti)
            warpedX=hcat(XY,height*[1.,-1.,1.,-1.])
            W=OpenJFEM.FEM.quad4_finite_warp_displacement_map(XY,warpedX)
            projected_u=W\warped_u
            T=kron(Matrix{Float64}(I,8,8),rotation)
            warped,warped_fields=recover(warped_model,ids,warpedX*rotation',R,T*projected_u)
            _,warped_compact=recover(warped_model,ids,warpedX*rotation',R,T*projected_u;compact=true)
            @test warped_fields==warped_compact
            force=only(warped["forces"]["quad4"])
            @test isapprox([force[k] for k in ("fx","fy","fxy")],h*warped_C*ep;rtol=5e-12)
            @test isapprox([force[k] for k in ("mx","my","mxy")],-cube/12*warped_C*kap;rtol=5e-12)
            stress=only(warped["stresses"]["quad4"])
            for (name,z) in (("z1",-h/2),("z2",h/2))
                @test isapprox(values3(stress[name]),warped_C*(ep+z*kap);rtol=5e-12)
            end
        end
        badnorm=copy(snorm);badnorm[2]=normalize(SVector(.1,0.,1.))
        @test_throws ArgumentError recover(m,ids,X,R,u;snorm=badnorm)
    end
end
end

@testset "Corner-thickness shell recovery and fiber locations" begin
    ShellCornerThicknessRecoveryFixture.checks()
end
