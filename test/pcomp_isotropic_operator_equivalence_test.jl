using Test

module PcompIsotropicOperatorEquivalenceFixture
using Test, LinearAlgebra, OpenJFEM
const S = OpenJFEM.Solver

function fixture(path, scale=1.; core_factor=1.)
    h=.002scale
    Q(E,nu)=E/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    hs=(.0004+.0016core_factor)*scale
    A=.0004Q(7e10,.3)+.0016core_factor*Q(1e8,.25)
    nu=A[1,2]/A[1,1]; E=A[1,1]*(1-nu^2)/(.0004+.0016core_factor)
    lines=String["SOL 105","CEND","SUBCASE 1"," SPC=1"," LOAD=1",
        "SUBCASE 2"," SPC=1"," METHOD=2"," STATSUB(BUCKLING)=1",
        "BEGIN BULK","PARAM,SNORM,0.","PARAM,K6ROT,100.",
        "MAT1,1,7.E10,,.3,2700.","MAT1,2,1.E8,,.25,100.","MAT1,3,$E,,$nu,620.",
        "PSHELL,101,1,$h,1,,1","PCOMP,102,,,,,,,","+,1,$h,0.,YES",
        "PSHELL,103,3,$hs,3,,3","PCOMP,104,,,,,,,",
        "+,1,$(.0002scale),0.,YES,2,$(.0016scale*core_factor),0.,YES",
        "+,1,$(.0002scale),0.,YES"]
    shapes=(((0.,0.),(1.,0.),(1.,.5),(0.,.5)),
        ((0.,0.),(1.,0.),(1.3,.5),(.3,.5)),
        ((0.,0.),(1.,0.),(.7,.5),(.1,.5)))
    for (g,shape) in enumerate(shapes), p in 1:4
        eid=4(g-1)+p; first=4eid-3
        for (j,(x,y)) in enumerate(shape)
            # Same rotated cell for each representation; arbitrary material THETA
            # must not change an isotropic section's operator.
            xr=cos(.31)*x-sin(.31)*y+2eid; yr=sin(.31)*x+cos(.31)*y
            push!(lines,"GRID,$(first+j-1),,$xr,$yr,0.")
        end
        push!(lines,"CQUAD4,$eid,$(100+p),$first,$(first+1),$(first+2),$(first+3),37.")
    end
    # Balanced symmetric MAT8 plies give isotropic A, although D is anisotropic.
    # Kg depends on A, rather than on whether each individual ply is isotropic.
    angles=(0.,45.,-45.,90.,90.,-45.,45.,0.)
    laminate_A=sum(OpenJFEM.laminate_plane_stress_qbar(135e9,8.5e9,.27,4.8e9,deg2rad(a)) for a in angles)*(.00025scale)
    ln=laminate_A[1,2]/laminate_A[1,1];le=laminate_A[1,1]*(1-ln^2)/h
    append!(lines,["MAT8,20,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.",
        "MAT1,4,$le,,$ln,1600.","PSHELL,106,4,$h,4,,4","PCOMP,105,,,,,,,"])
    for i in 1:2:length(angles)
        push!(lines,"+,20,$(.00025scale),$(angles[i]),YES,20,$(.00025scale),$(angles[i+1]),YES")
    end
    for (eid,pid) in ((13,105),(14,106))
        first=4eid-3
        for (j,(x,y)) in enumerate(shapes[2])
            push!(lines,"GRID,$(first+j-1),,$(x+2eid),$y,0.")
        end
        push!(lines,"CQUAD4,$eid,$pid,$first,$(first+1),$(first+2),$(first+3),37.")
    end
    append!(lines,["SPC1,1,123456,1","FORCE,1,2,0,1.,-1.,0.,0.","EIGRL,2,0.,,2","ENDDATA"])
    write(path,join(lines,'\n')*"\n")
    OpenJFEM.bdf_to_model(path)
end

function operators(model, pattern)
    capture=S.AnalyticShellCapture(model)
    assembly=S.assemble_stiffness(model; membrane_incomp=false,
        snorm_angle_override=0.,sol105_context=true,shell_capture=capture)
    K,idmap,X,ndof,node_R,_,mapping,normals,_=assembly
    state=zeros(ndof)
    for el in values(model["CSHELLs"]), (j,nid) in enumerate(el["NODES"])
        i=idmap[nid]
        state[6(i-1)+1]=pattern[j][1]; state[6(i-1)+2]=pattern[j][2]
    end
    contexts=Dict{Int,Any}(); guard=ReentrantLock()
    callback=function(eid,c)
        value=(Kg=copy(c[:Kg_global]),iso=c[:kg_nastran_kdjj_iso_branch],
            E=c[:E_val],nu=c[:nu_val],h=c[:h],T=copy(c[:T_buf]),
            lc=copy(c[:lc_buf4]),u=copy(c[:u_elem24]),assumed=c[:assumed_transverse])
        lock(guard) do;contexts[eid]=value;end
    end
    S.assemble_geometric_stiffness(model,idmap,X,node_R,ndof,state,normals,mapping;
        snorm_angle_override=0.,buckling_subcase=2,static_load_id=1,geometric_capture=callback)
    capture,contexts
end

function run_checks()
    mktempdir() do directory
        model=fixture(joinpath(directory,"equivalent.bdf"))
        # Independent MAT1 G need not form an isotropic plane-stress law.
        @test S.shell_membrane_is_isotropic(model["PSHELLs"]["104"]["Cm"])
        bad=copy(model["PSHELLs"]["104"]["Cm"]);bad[3,3]*=1.1
        @test !S.shell_membrane_is_isotropic(bad)
        @test !S.shell_membrane_is_isotropic(zeros(3,3))
        patterns=(((0.,0.),(-.001,0.),(-.001,0.),(0.,0.)),
            ((0.,0.),(0.,0.),(.001,0.),(0.,0.)),
            ((.0002,.0001),(-.0008,.0004),(.0004,-.0003),(.0001,.0002)))
        for pattern in patterns
            cap,geo=operators(model,pattern)
            @test !model["PSHELLs"]["105"]["IS_ISOTROPIC"]
            @test S.shell_membrane_is_isotropic(model["PSHELLs"]["105"]["Cm"])
            @test geo[13].iso && geo[14].iso
            @test isapprox(geo[13].Kg,geo[14].Kg;rtol=2e-11)
            @test_throws ArgumentError S.analytic_shell_constitutive(model,105)
            for g in 0:2
                a,b,c,d=4g.+(1,2,3,4)
                @test isapprox(cap.contexts[a].Ke,cap.contexts[b].Ke;rtol=2e-11)
                membrane=[6(i-1)+j for i in 1:4 for j in 1:2]
                @test isapprox(cap.contexts[c].Ke[membrane,membrane],cap.contexts[d].Ke[membrane,membrane];rtol=2e-11)
                @test all(geo[e].iso for e in (a,b,c,d))
                @test isapprox(geo[a].Kg,geo[b].Kg;rtol=2e-11)
                @test isapprox(geo[c].Kg,geo[d].Kg;rtol=2e-11)
                @test isapprox(geo[c].E,geo[d].E;rtol=2e-14)
                @test isapprox(geo[c].nu,geo[d].nu;rtol=2e-14)
                # Laminate D/As remain independent of its equivalent membrane E.
                @test !isapprox(model["PSHELLs"]["104"]["Cb"],
                    S.analytic_shell_constitutive(model,103).Cb;rtol=.01)
            end
        end
        pattern=patterns[end]; cap,geo=operators(model,pattern)
        delta=1e-5
        plus=operators(fixture(joinpath(directory,"plus.bdf"),1+delta),pattern)
        minus=operators(fixture(joinpath(directory,"minus.bdf"),1-delta),pattern)
        for eid in (2,4,6,8,10,12)
            pid=cap.contexts[eid].pid
            c=S.analytic_shell_constitutive(model,pid)
            dt=[p["z_top"]-p["z_bot"] for p in model["PSHELLs"][string(pid)]["PLY_DATA"]]
            direction=(ply_thicknesses=dt,thickness=sum(dt))
            tangent=S.analytic_shell_tangent(cap.contexts[eid],direction)
            fd=(plus[1].contexts[eid].Ke-minus[1].contexts[eid].Ke)/(2delta)
            @test isapprox(tangent.dKe,fd;rtol=2e-8)
            # Isotropic Kg is linear in A for fixed geometry and preload;
            # proportional ply scaling is therefore an independent derivative oracle.
            fdg=(plus[2][eid].Kg-minus[2][eid].Kg)/(2delta)
            @test isapprox(geo[eid].Kg,fdg;rtol=2e-8)
            localg=S.FEM.geometric_stiffness_quad4_nastran_kdjj_iso(
                geo[eid].lc,geo[eid].u,c.E,c.nu,c.h;assumed_transverse=geo[eid].assumed)
            @test isapprox(geo[eid].Kg,geo[eid].T'*localg*geo[eid].T;rtol=2e-11)
        end
        # Changing only the core also changes effective E/nu; a simple total
        # thickness scale would not test that constitutive derivative chain.
        plus=operators(fixture(joinpath(directory,"core_plus.bdf");core_factor=1+delta),pattern)
        minus=operators(fixture(joinpath(directory,"core_minus.bdf");core_factor=1-delta),pattern)
        direction=(ply_thicknesses=[0.,.0016,0.],thickness=.0016)
        for eid in (4,8,12)
            tangent=S.analytic_shell_tangent(cap.contexts[eid],direction)
            fd=(plus[1].contexts[eid].Ke-minus[1].contexts[eid].Ke)/(2delta)
            @test isapprox(tangent.dKe,fd;rtol=2e-7)
            c=S.analytic_shell_constitutive(model,104,direction,S.ForwardDiff.Dual(0.,1.))
            localg=S.FEM.geometric_stiffness_quad4_nastran_kdjj_iso(
                geo[eid].lc,geo[eid].u,c.E,c.nu,c.h;assumed_transverse=geo[eid].assumed)
            globalg=geo[eid].T'*localg*geo[eid].T
            dg=map(v->S.ForwardDiff.partials(v)[1],globalg)
            fdg=(plus[2][eid].Kg-minus[2][eid].Kg)/(2delta)
            @test isapprox(dg,fdg;rtol=2e-7)
        end
    end
end
end

@testset "Isotropic laminate operator representation invariance" begin
    PcompIsotropicOperatorEquivalenceFixture.run_checks()
end
