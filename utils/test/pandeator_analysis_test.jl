module PandeatorAnalysisTests
using Test, LinearAlgebra
import OpenJFEM, WingFEGen, ForwardDiff
include(joinpath(@__DIR__,"..","..","APPS","PANDEATOR_APP","panel_model.jl"))
include(joinpath(@__DIR__,"..","..","APPS","PANDEATOR_APP","panel_analysis.jl"))
const M=PandeatorModel;const A=PandeatorAnalysis;const W=WingFEGen
const RECOVERY_REGRESSION_RESULTS=Dict{String,Any}()

@testset "Spectral ambiguity takes priority over basis approximation" begin
    @test A.spectral_status(false,true,true)=="cluster"
    @test A.spectral_status(false,true,false)=="cluster"
    @test A.spectral_status(false,false,true)=="approximation"
    @test A.spectral_status(true,true,true)=="no_demand"
end

function parsed_panel(model,directory,name)
    file=joinpath(directory,name*".bdf");write(file,M.panel_bdf(model))
    OpenJFEM.bdf_to_model(file)
end

@testset "Physical associated-column section and exact gauge chain" begin
    mktempdir() do directory
        m=M.build_panel_model(Dict("R"=>0.,"nx"=>2,"ny"=>2,"nz"=>1,"nf"=>2))
        parsed=parsed_panel(m,directory,"section");ctx=(;op=(;model=parsed))
        K=A.section_stiffness(m,ctx,Dict(),0.)
        # Associated skin: 300 x 2; full added flange: 50 x 2; blade: 40 x 2.
        # Centered combined footprint has thickness 4, not two coincident t=2
        # plates, and the full physical section's centroid is condensed once.
        area=780.;first_moment=80*20.;second_moment=250*2^3/12+50*4^3/12+2*40^3/3
        expected_ei=71000*(second_moment-first_moment^2/area)
        @test K[1,1]≈71000area rtol=1e-12
        @test K[1,2]≈71000first_moment rtol=1e-12
        @test A.W.rf_weakest_ei(K)≈expected_ei rtol=1e-12
        for variable in ("tSkin","tWeb","tFoot")
            direction=M.panel_property_directions(m,variable)
            exact=ForwardDiff.derivative(x->A.W.rf_weakest_ei(A.section_stiffness(m,ctx,direction,x)),0.)
            delta=1e-5;mats=Float64[]
            for sign in (-1,1)
                p=copy(m.params);p[variable]+=sign*delta;trial=M.build_panel_model(p)
                trialctx=(;op=(;model=parsed_panel(trial,directory,variable*string(sign))))
                push!(mats,A.W.rf_weakest_ei(A.section_stiffness(trial,trialctx,Dict(),0.)))
            end
            @test exact≈(mats[2]-mats[1])/(2delta) rtol=1e-7
        end
    end
end

@testset "Bare plate has full physical width and fixed-flow cubic gauge scaling" begin
    mktempdir() do directory
        m=M.build_panel_model(Dict("R"=>0.,"nx"=>2,"ny"=>2,"bladeH"=>0.,"footW"=>0.,
            "width"=>40.,"length"=>80.,"tSkin"=>.2,"Nx"=>1.))
        parsed=parsed_panel(m,directory,"bare");ctx=(;op=(;model=parsed))
        elements=sort(m.elements;by=e->e["eid"])
        values=reduce(vcat,[[-1.,0.,0.,0.,0.,0.] for e in elements])
        rec=(;elements,values,index=Dict(e["eid"]=>i for (i,e) in enumerate(elements)))
        specs=A.analytic_response_specs(m,ctx,rec;progress=_ -> nothing,cancelled=()->false)
        @test length(specs)==1
        spec=only(specs);@test spec.id=="skin_full"
        @test spec.diagnostics["width_mm"]==40.
        D=71000*.2^3/(12*(1-.33^2));expected=4pi^2*D/40^2
        @test spec.value≈expected rtol=1e-12
        direction=M.panel_property_directions(m,"tSkin")
        tangent=ForwardDiff.derivative(x->spec.kernel(values,direction,x),0.)
        @test tangent≈3expected/.2 rtol=1e-12
    end
end

@testset "Native symmetric PCOMP recovery retains nonzero directional B" begin
    mktempdir() do directory
        # Two nonsymmetric component stacks make one symmetric combined stack.
        # Independently scaling the skin breaks symmetry and creates dB != 0.
        m=M.build_panel_model(Dict("R"=>0.,"nx"=>2,"ny"=>2,"nz"=>1,"nf"=>2,
            "material_mode"=>"composite","lamSkin"=>"0/90","lamFoot"=>"90/0"))
        parsed=parsed_panel(m,directory,"symmetric")
        @test parsed["PSHELLs"]["3"]["Bmb"]===nothing
        op=W.sensitivity_assemble(OpenJFEM,parsed;solution=105,analytic=true)
        direction=M.panel_property_directions(m,"scaleSkin")
        state=zeros(op.ndof)
        for node in m.nodes
            i=op.id_map[node["id"]];x,y,z=node["x"],node["y"],node["z"]
            translation=[.001x,.0003y,.0001x*x+.0002x*y+.0003y*y]
            rotation=[.0002x+.0006y,-.0002x-.0002y,0.]
            state[6i-5:6i-3]=transpose(op.node_R[i])*translation
            state[6i-2:6i]=transpose(op.node_R[i])*rotation
        end
        eid=first(m.regions["footprint"]["eids"]);shell=op.shell_capture.contexts[eid]
        constitutive=OpenJFEM.Solver.analytic_shell_constitutive(parsed,3,direction[3],ForwardDiff.Dual(0.,1.))
        @test norm(map(v->ForwardDiff.partials(v)[1],constitutive.Bmb))>1.
        RECOVERY_REGRESSION_RESULTS["baseline_B_is_nothing"]=true
        RECOVERY_REGRESSION_RESULTS["directional_B_norm"]=norm(map(v->ForwardDiff.partials(v)[1],constitutive.Bmb))
        RECOVERY_REGRESSION_RESULTS["rows"]=Any[]
        tangent=OpenJFEM.Solver.analytic_shell_recovery_tangent(shell,direction[3],state,op.id_map,op.X,op.node_R,op.snorm_normals)
        records=Any[];delta=1e-5
        for sign in (-1,1)
            p=copy(m.params);p["scaleSkin"]+=sign*delta;trial=M.build_panel_model(p)
            model=parsed_panel(trial,directory,"perturbed"*string(sign));trialop=merge(op,(;model))
            context=(;op=trialop,wing=(;groups=Any[]),expanded=state)
            target=W.rf_recovery_target(OpenJFEM,trialop,context.wing,eid)
            push!(records,W.rf_recovery_record(OpenJFEM,context,target,state,"force";native_frame=true))
        end
        for field in A.FORCE_FIELDS
            finite=(records[2][field]-records[1][field])/(2delta)
            exact=tangent.derivative["forces"][field]
            @test isapprox(exact,finite;rtol=2e-6,atol=1e-5)
            push!(RECOVERY_REGRESSION_RESULTS["rows"],Dict("feature"=>field,"analytic"=>exact,"finite_difference"=>finite,
                "absolute_error"=>abs(exact-finite),"relative_error"=>abs(exact-finite)/max(abs(exact),abs(finite),1e-10)))
        end
    end
end

end
