module CorotationalShellPhysicalTests
using Test, OpenJFEM, LinearAlgebra, SparseArrays, StaticArrays, ForwardDiff
const S=OpenJFEM.Solver
const C=S.CorotationalShell

function fixture(folder;moment=1.,single_axis=false,cd=false,warp=0.,langle=1)
    Q=C.rotation_exp([.31,-.17,.23]);cid=cd ? 77 : 0
    coordinate=cd ? "CORD2R,77,0,0.,0.,0.,$(Q[1,3]),$(Q[2,3]),$(Q[3,3])\n+, $(Q[1,1]),$(Q[2,1]),$(Q[3,1])\n" : ""
    constraints=single_axis ? "SPC1,1,123456,1,2,3\nSPC1,1,12346,4" : "SPC1,1,123456,1,4"
    load=single_axis ? "MOMENT,1,4,$cid,$moment,0.,1.,0." : "FORCE,1,2,0,.5,0.,0.,1.\nFORCE,1,3,0,.5,0.,0.,1."
    path=joinpath(folder,"corotational_fixture.bdf")
    write(path,"""
SOL 106
CEND
SUBCASE 1
 SPC=1
 LOAD=1
 NLPARM=1
BEGIN BULK
PARAM,LGDISP,1
PARAM,LANGLE,$langle
PARAM,SNORM,0.
PARAM,K6ROT,1.
PARAM,AUTOSPC,YES
$(coordinate)GRID,1,0,0.,0.,0.,$cid
GRID,2,0,1.,0.,0.,$cid
GRID,3,0,1.,.7,$warp,$cid
GRID,4,0,0.,.7,0.,$cid
CQUAD4,1,1,1,2,3,4
PSHELL,1,1,.05,1,,1
MAT1,1,7.e7,,.3
$constraints
$load
NLPARM,1,4,,,1,30,P,NO
+,1.e-8,1.e-9,1.e-8
ENDDATA
""")
    OpenJFEM.bdf_to_model(path)
end

function run_checks()
    @testset "Corotational shell physical force and coordinate work" begin
        mktempdir() do folder
            for warp in (0.,.025),cd in (false,true)
                model=fixture(folder;warp=warp,cd=cd)
                K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(model)
                context=S._corotational_shell_context(K,nd,model,ids,X,R,1,mapping)
                e=only(context.elements);u=.002sin.(1.:24.);v=cos.(1.:24.);v/=norm(v)
                f=C.engineering_element_force(e,u);J=ForwardDiff.jacobian(q->C.engineering_element_force(e,q),u)
                @test norm(ForwardDiff.jacobian(q->C.engineering_element_force(e,q),zeros(24))-e.K)<2e-10norm(e.K)
                fd=(C.engineering_element_force(e,u+1e-6v)-C.engineering_element_force(e,u-1e-6v))/(2e-6)
                @test fd≈J*v rtol=2e-7 atol=1e-6
                G=C.rotation_exp([.27,-.41,.19]);shift=[.1,-.2,.3];rigid=zeros(24);changed=copy(u)
                for i in 1:4
                    rigid[6i-5:6i-3]=G*e.X[i,:]+shift-e.X[i,:];rigid[6i-2:6i]=[.27,-.41,.19]
                    changed[6i-5:6i-3]=G*(e.X[i,:]+u[6i-5:6i-3])+shift-e.X[i,:]
                    changed[6i-2:6i]=C.rotation_log(G*C.rotation_exp(u[6i-2:6i]))
                end
                @test norm(C.engineering_element_force(e,rigid))<2e-12norm(e.K)*norm(rigid)
                physical=C.engineering_physical_force(e,u);actual=C.engineering_physical_force(e,changed)
                @test actual≈hcat(physical[:,1:3]*G',physical[:,4:6]*G') rtol=2e-9 atol=1e-6
                Y=e.X+permutedims(reshape(u,6,4)[1:3,:])
                @test norm(vec(sum(physical[:,1:3];dims=1)))<2e-12max(norm(physical),1.)
                @test norm(sum(cross(Y[i,:],physical[i,1:3])+physical[i,4:6] for i in 1:4))<2e-12max(norm(physical),1.)
                # Full analysis/CD chain uses the same basic-frame objective work.
                state=S._evaluate_nonlinear_state_corotational(context,K,zeros(nd),u)
                sd=(S._evaluate_nonlinear_state_corotational(context,K,zeros(nd),u+1e-6v).residual_vector-
                    S._evaluate_nonlinear_state_corotational(context,K,zeros(nd),u-1e-6v).residual_vector)/(2e-6)
                @test sd≈state.K_eff*v rtol=2e-7 atol=1e-6
                loads=cos.(1.:24.);applied,tangent,workmap=S._corotational_applied_force_tangent(loads,u)
                ld=(S._corotational_applied_force(loads,u+1e-6v)-S._corotational_applied_force(loads,u-1e-6v))/(2e-6)
                @test ld≈tangent*v rtol=2e-7 atol=1e-9
                @test applied≈workmap*loads rtol=2e-14 atol=1e-14
                # Mixed families and active constraint maps cannot silently reuse this law.
                for family in ("CBARs","CBEAMs","CRODs","CONRODs","CBUSHs","CELASs","CSOLIDs","RBE2s")
                    mixed=deepcopy(model);mixed[family]=Dict("2"=>Dict())
                    @test !S._corotational_shell_support_report(mixed,normals,mapping).supported
                end
                @test !S._corotational_shell_support_report(model,normals,Dict(1=>[(2,1.)])).supported
                direct=deepcopy(model);direct["DMIGs"]=Dict("TEST"=>Dict());direct["CASE_CONTROL"]["K2GG"]="TEST"
                @test !S._corotational_shell_support_report(direct,normals,mapping).supported
            end
            # Independent exact solution: fixed positions and one free rotation.
            # R_frame=I, theta=t*axis, and J_l(theta)'*(M*axis)=M*axis.
            for cd in (false,true),langle in (1,2)
                model=fixture(folder;single_axis=true,cd=cd,langle=langle)
                K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(model)
                free,_=S.compute_free_dofs(K,nd,model,ids,1,mapping)
                @test length(free)==1
                dof=only(free);target=.2
                model=fixture(folder;single_axis=true,cd=cd,langle=langle,moment=K[dof,dof]*target)
                solved=only(OpenJFEM.solve_model(model)["subcases"])
                @test solved["nonlinear_diagnostics"]["converged"]
                @test solved["nonlinear_diagnostics"]["nonlinear_method"]=="corotational_shell"
                @test solved["u_analysis"][dof]≈target rtol=2e-9 atol=2e-11
                coordinates=solved["nonlinear_rotation_coordinates"]
                @test coordinates["internal"]=="GRID_CD_ROTATION_VECTOR"
                row=only(r for r in coordinates["grid_cd_rotations"] if r["grid_id"]==4)
                @test row["angles"]≈[0.,target,0.] atol=3e-10
            end
            # LANGLE=2 must remain valid at a gimbal singularity.
            model=fixture(folder;single_axis=true,langle=2)
            K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(model)
            context=S._corotational_shell_context(K,nd,model,ids,X,R,1,mapping)
            q=zeros(nd);q[6ids[4]-1]=pi/2
            _,_,result=S._build_results_from_state(nd,model,ids,X,R,q,zeros(nd),normals,Dict{String,Any}();corotational_context=context)
            @test result["nonlinear_rotation_coordinates"]["reported"]=="BASIC_ROTATION_VECTOR"
            # Nonzero GRID.CD output uses rotation conjugation, never a linear
            # rotation of Euler-angle triples.
            Q=C.rotation_exp([.41,-.23,.18]);theta=[.23,-.17,.31]
            angles=S._corotational_gimbal_rotation(Q*theta;frame=Q)
            restored=C.rotation_exp([0.,0.,angles[3]])*C.rotation_exp([0.,angles[2],0.])*C.rotation_exp([angles[1],0.,0.])
            @test Q*restored*Q'≈C.rotation_exp(Q*theta) atol=3e-15
        end
    end
end
end

module CorotationalShellIndependentWorkTests
using Test,OpenJFEM,LinearAlgebra,ForwardDiff
using ..CorotationalShellPhysicalTests
const S=OpenJFEM.Solver;const C=S.CorotationalShell
function independent_work(e,u,v;h=1e-6)
    Y=e.X+permutedims(reshape(u,6,4)[1:3,:]);dY=permutedims(reshape(v,6,4)[1:3,:])
    R=C.nodal_polar_rotation(e.X,e.Q0,Y)
    Rp=C.nodal_polar_rotation(e.X,e.Q0,Y+h*dY);Rm=C.nodal_polar_rotation(e.X,e.Q0,Y-h*dY)
    W=R'*(Rp-Rm)/(2h);omega=[W[3,2]-W[2,3],W[1,3]-W[3,1],W[2,1]-W[1,2]]/2
    local_force=permutedims(reshape(e.K*C.deformational_dofs(e.X,e.Q0,u),6,4))
    r=(Y.-sum(Y;dims=1)/4)*R;virtual=(dY.-sum(dY;dims=1)/4)*R;work=0.
    for i in 1:4
        theta=u[6i-2:6i];dt=v[6i-2:6i]
        Q=C.rotation_exp(theta);dQ=(C.rotation_exp(theta+h*dt)-C.rotation_exp(theta-h*dt))/(2h)
        W=dQ*Q';spin=[W[3,2]-W[2,3],W[1,3]-W[3,1],W[2,1]-W[1,2]]/2
        work+=dot(local_force[i,1:3],virtual[i,:]-cross(omega,r[i,:]))
        work+=dot(local_force[i,4:6],R'*spin-omega)
    end
    work
end
function run_checks()
    @testset "Independent corotational spin work and AUTO compatibility" begin
        mktempdir() do folder
            model=CorotationalShellPhysicalTests.fixture(folder;warp=.025)
            K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(model)
            ctx=S._corotational_shell_context(K,nd,model,ids,X,R,1,mapping);e=only(ctx.elements)
            u=.03sin.(1.:24.);v=cos.(0.3 .+ (1.:24.));v/=norm(v)
            @test dot(C.engineering_element_force(e,u),v)≈independent_work(e,u,v) rtol=2e-7 atol=2e-7
            physical=sin.(1.:24.);generalized=S._corotational_applied_force(physical,u);external_work=0.
            for i in 1:4
                theta=u[6i-2:6i];dt=v[6i-2:6i];Q=C.rotation_exp(theta)
                dQ=(C.rotation_exp(theta+1e-6dt)-C.rotation_exp(theta-1e-6dt))/(2e-6)
                W=dQ*Q';spin=[W[3,2]-W[2,3],W[1,3]-W[3,1],W[2,1]-W[1,2]]/2
                external_work+=dot(physical[6i-5:6i-3],v[6i-5:6i-3])+dot(physical[6i-2:6i],spin)
            end
            @test dot(generalized,v)≈external_work rtol=2e-8 atol=2e-10
            # The leading derivative cancels when moment and virtual rotation
            # are parallel. A high-precision FD sweep detects cancellation in
            # trigonometric coefficients without changing the Float64 gate.
            small=.002sin.(1.:24.);direction=cos.(1.:24.);direction/=norm(direction)
            moment=cos.(1.:24.);_,load_jacobian,_=S._corotational_applied_force_tangent(moment,small)
            expected=load_jacobian*direction
            for h in (1e-6,1e-7,1e-8)
                reference=setprecision(BigFloat,128) do
                    q=BigFloat.(small);dv=BigFloat.(direction);m=BigFloat.(moment);step=BigFloat(h)
                    Float64.((S._corotational_applied_force(m,q+step*dv)-S._corotational_applied_force(m,q-step*dv))/(2step))
                end
                @test reference≈expected rtol=2e-9 atol=1e-13
            end
            @test S._nonlinear_numerical_failure(C.TrialDomainError("trial only"))
            @test !S._nonlinear_numerical_failure(ArgumentError("unsupported model"))
            # Geometrically similar cells retain the same objective polar
            # frame and dimensionally transformed work, independent of units.
            for scale in (1e-13,1e-6,1e3)
                D=Diagonal(repeat([scale,scale,scale,1.,1.,1.],4))
                es=(X=scale*e.X,Q0=e.Q0,K=scale^3*(D\e.K)/D)
                actual=C.engineering_element_force(es,D*u);expected=scale^3*(D\C.engineering_element_force(e,u))
                @test norm(actual-expected)<2e-8norm(expected)
            end
            # A collapsed trial is recoverable; a shorter step remains in the
            # same supported domain. No unsupported-model exception is caught.
            model=CorotationalShellPhysicalTests.fixture(folder)
            K,ids,X,nd,R,_,mapping,normals,_=S.assemble_stiffness(model)
            ctx=S._corotational_shell_context(K,nd,model,ids,X,R,1,mapping);flat=only(ctx.elements)
            collapsed=copy(flat.X);collapsed[:,2].=0.
            @test_throws C.TrialDomainError C.nodal_polar_rotation(flat.X,flat.Q0,collapsed)
            @test C.nodal_polar_rotation(flat.X,flat.Q0,(flat.X+collapsed)/2)≈I atol=2e-14
            @test_throws C.TrialDomainError C.nodal_polar_rotation(e.X,e.Q0,zeros(4,3))
            # At extremely small deformation the exact zero-state tangent is
            # an independent force oracle. Refined arithmetic resolves it
            # without changing the requested residual criterion.
            tiny=1e-12sin.(1.:24.);load=K*tiny
            state=S._evaluate_nonlinear_state_corotational(ctx,K,load,tiny)
            @test state.internal_force_precision_bits==128
            @test norm(state.residual_vector)<1e-8norm(load)
            @test ctx.precision_refinements[]==1
            # Moving the coordinate origin cannot erase tiny distortions.
            # Dyadic geometry and an exact large integer shift avoid changing
            # the represented reference dimensions in this arithmetic oracle.
            for warp in (0.,.03125)
                xyz=[0. 0. 0.;1. 0. 0.;1. .5 warp;0. .5 0.]
                centered=merge(flat,(X=xyz,Q0=C.element_frame(xyz)))
                shifted=merge(centered,(X=xyz .+ [2.0^30 -2.0^29 2.0^28],))
                expected=S._corotational_precise_internal_force(merge(ctx,(elements=[centered],precise_elements=Ref{Any}(nothing),precision_refinements=Ref(0))),tiny)
                shifted_context=merge(ctx,(elements=[shifted],precise_elements=Ref{Any}(nothing),precision_refinements=Ref(0),roundoff_force_bound=1.))
                actual=S._evaluate_nonlinear_state_corotational(shifted_context,K,expected,tiny)
                @test actual.internal_force_precision_bits==128
                @test norm(actual.residual_vector)<1e-8norm(expected)
            end
            # The undeformed state has exactly zero physical load, force and
            # recovered strain, even after rotating a warped reference cell.
            for warp in (0.,.025)
                unloaded=CorotationalShellPhysicalTests.fixture(folder;warp=warp,cd=true)
                G=C.rotation_exp([.31,-.17,.23])
                for grid in values(unloaded["GRIDs"]);grid["X"]=G*grid["X"];end
                unloaded["FORCEs"]=Any[];unloaded["MOMENTs"]=Any[]
                result=only(OpenJFEM.solve_model(unloaded)["subcases"])
                @test result["nonlinear_diagnostics"]["converged"]
                @test all(iszero,result["u_analysis"])
                @test result["nonlinear_diagnostics"]["final_relative_residual"]==0.
                @test all(iszero,result["raw_displacement"])
                strain=only(result["strains"]["quad4"])
                @test all(iszero(strain[face][component]) for face in ("z1","z2") for component in ("normal_x","normal_y","shear_xy"))
            end
            # RFORCE has an unimplemented current-geometry load tangent. Only
            # selected nonzero contributions exclude the new work law.
            rotating=deepcopy(model)
            rotating["RFORCEs"]=[Dict("SID"=>7,"A"=>1.,"RACC"=>0.,"R"=>[0.,0.,1.])]
            supported(m,sid)=S._corotational_shell_support_report(m,normals,mapping;load_id=sid).supported
            @test supported(rotating,1)
            @test !supported(rotating,7)
            rotating["LOAD_COMBOS"]=[Dict("SID"=>9,"S"=>1.,"COMPS"=>[
                Dict("LID"=>7,"S"=>1.),Dict("LID"=>7,"S"=>-1.)])]
            @test supported(rotating,9)
            rotating["LOAD_COMBOS"]=[Dict("SID"=>9,"S"=>-2.,"COMPS"=>[Dict("LID"=>7,"S"=>1.)])]
            @test !supported(rotating,9)
            rotating["RFORCEs"][1]["A"]=0.
            @test supported(rotating,7)
            rotating["RFORCEs"][1]["RACC"]=1.
            @test !supported(rotating,7)
            rotating["RFORCEs"][1]["R"]=[0.,0.,0.]
            @test supported(rotating,7)
            for kind in (:bar,:mpc)
                model=CorotationalShellPhysicalTests.fixture(folder)
                file=joinpath(folder,"corotational_fixture.bdf");deck=read(file,String)
                if kind===:bar
                    deck=replace(deck,"ENDDATA"=>"CBAR,11,11,2,3,1.,0.,0.\nPBAR,11,1,.001,1.e-6,1.e-6,1.e-6\nENDDATA")
                else
                    deck=replace(deck," NLPARM=1"=>" NLPARM=1\n MPC=2")
                    deck=replace(deck,"ENDDATA"=>"MPC,2,2,2,1.,3,2,-1.\nENDDATA")
                end
                write(file,deck);model=OpenJFEM.bdf_to_model(file)
                automatic=only(OpenJFEM.solve_model(deepcopy(model))["subcases"])
                formal_model=deepcopy(model);formal_model["PARAM_NLMETHOD"]="FORMAL"
                formal=only(OpenJFEM.solve_model(formal_model)["subcases"])
                @test automatic["nonlinear_diagnostics"]["converged"]
                @test automatic["nonlinear_diagnostics"]["nonlinear_method"]=="formal_shell_green_lagrange"
                @test !automatic["nonlinear_diagnostics"]["corotational_shell_supported"]
                @test automatic["u_analysis"]≈formal["u_analysis"] rtol=2e-12 atol=1e-12
                @test automatic["nonlinear_rotation_coordinates"]===nothing
                strict=deepcopy(model);strict["PARAM_NLMETHOD"]="COROT"
                @test_throws ArgumentError OpenJFEM.solve_model(strict)
            end
        end
    end
end
end

CorotationalShellPhysicalTests.run_checks()
CorotationalShellIndependentWorkTests.run_checks()
