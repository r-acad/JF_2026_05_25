using Test,LinearAlgebra,Random,JSON
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
isdefined(W,:sensitivity_analytic_bar)||Base.include(W,joinpath(@__DIR__,"..","src","sensitivity_analytic_beams.jl"))
repo=first(W.find_jfem(dirname(@__DIR__)))
module AnalyticBeamNative end
Base.include(AnalyticBeamNative,joinpath(repo,"src","jfem_bootstrap.jl"));const N=AnalyticBeamNative
stable,out=abspath.(ARGS);mkpath(stable);mkpath(out);Random.seed!(43027)
function deck_and_op(m,name;rotations=nothing,consistent=true)
    path=joinpath(stable,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    model=N.bdf_to_model(path);model["PARAM_COUPMASS"]=consistent
    ids=sort(parse.(Int,collect(keys(model["GRIDs"]))))
    id_map=Dict(id=>i for (i,id) in enumerate(ids))
    X=reduce(vcat,[transpose(Float64.(model["GRIDs"][string(id)]["X"])) for id in ids])
    node_R=rotations===nothing ? [Matrix{Float64}(I,3,3) for _ in ids] : rotations
    (;model,id_map,X,node_R,load_id=nothing)
end
function local_native(op,g,e)
    d=N.Solver._get_beam_element_data(g.eids[e],op.model,op.id_map,op.X,op.node_R)
    (;data=d,Ke=transpose(d.T12)*d.Ke_loc*d.T12)
end
function isolated_mass(op,g,e,ndof)
    model=deepcopy(op.model);model["CBARs"]=Dict(string(g.eids[e])=>model["CBARs"][string(g.eids[e])])
    for key in ("CSHELLs","CBEAMs","CRODs","CONRODs","CONM2s","CMASSs","CONM1s");model[key]=Dict();end
    M=N.Solver.assemble_mass(model,op.id_map,op.X,op.node_R,ndof)
    d=local_native(op,g,e).data.dofs
    Matrix(M[d,d])
end
p=W.default_params();merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
    "planform.dihedral"=>6.,"planform.twist_tip"=>-11.,"box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.07,
    "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>2,"aero.enabled"=>false,"fuel.enabled"=>false,
    "loads.structure_inertia"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
m=W.build_model(p);write(joinpath(stable,"beam_analytic.toml"),W.params_to_toml(p));op=deck_and_op(m,"beam_baseline")
ndof=6length(op.id_map);state=randn(ndof)*1e-4;phi=randn(ndof)
groups=[first(filter(g->g.kind===:bar&&W.component_base_pid(g.pid)==pid,m.groups)) for pid in (W.PID_STRINGER,W.PID_SPAR_CAP,W.PID_RIB_STIFFENER,W.PID_STRINGER_RUNOUT)]
records=Any[]
tests=@testset "Analytic PBARL dimensions, offsets, stiffness, mass and recovery" begin
    for (shape,dims,dirs) in (("T",[.032,.041,.003,.002],[Float64[i==j for i in 1:4] for j in 1:4]),
                           ("BAR",[.022,.031],[[1.,0.],[0.,1.]]),("BAR",[.023,.023],[[1.,1.]]),("ROD",[.018],[[1.]]))
        for dir in dirs
            exact=W.sensitivity_analytic_section(shape,dims,dir);h=1e-7
            plus=W.sensitivity_analytic_section(shape,dims.+h.*dir);minus=W.sensitivity_analytic_section(shape,dims.-h.*dir)
            for (key,dkey) in ((:area,:darea),(:I1,:dI1),(:I2,:dI2),(:J,:dJ),(:offset_y,:doffset_y),(:As_y,:dAs_y),(:As_z,:dAs_z))
                @test isapprox(getproperty(exact,dkey),(getproperty(plus,key)-getproperty(minus,key))/(2h);rtol=2e-8,atol=1e-12)
            end
            @test reduce(vcat,exact.dpolygon)≈(reduce(vcat,plus.polygon)-reduce(vcat,minus.polygon))/(2h) rtol=2e-8 atol=1e-10
        end
    end
    @test_throws ArgumentError W.sensitivity_analytic_section("BAR",[.02,.02],[1.,0.])
    for (gi,g) in enumerate(groups)
        e=min(2,length(g.eids));section=W.section_definition(m.params,g.pid)
        directions=if gi in (1,3)
            prefix=gi==1 ? "properties.stringer_" : "properties.rib_stiffener_"
            [(prefix*field,Dict{String,Any}("dimensions"=>Float64[i==j for i in 1:4])) for (j,field) in enumerate(("flange_width","height","flange_thickness","web_thickness"))]
        elseif gi==2
            [("properties.spar_cap_side",Dict{String,Any}("dimensions"=>[1.,1.]))]
        else
            Tuple{String,Dict{String,Any}}[]
        end
        append!(directions,[("material.E",Dict{String,Any}("E"=>1.)),("material.nu",Dict{String,Any}("nu"=>1.)),("material.rho",Dict{String,Any}("rho"=>1.))])
        for (key,dir) in directions
            b=W.sensitivity_analytic_bar(N,op,m,g,e,dir,state);native=local_native(op,g,e)
            @test b.Ke≈native.Ke rtol=1e-12
            @test b.Me≈isolated_mass(op,g,e,ndof) rtol=1e-12
            @test b.stress_gradient*state[b.dofs]≈b.stress_features rtol=1e-12
            @test dot(b.axial_gradient,state[b.dofs])≈b.axial_stress rtol=1e-12
            objective=Dict("type"=>"bar_stress","element_id"=>g.eids[e],"component"=>"max")
            target=W.sensitivity_recovery_target(N,op,objective)
            @test b.stress_features≈W.sensitivity_response_features(N,op,m,objective,state,target) rtol=1e-11
            h=max(abs(p[key])*1e-5,1e-8);samples=[]
            for sign in (-1,1)
                q=deepcopy(p);q[key]+=sign*h;trial=W.sensitivity_model(m,q)
                trialop=deck_and_op(trial,"beam_$(gi)_$(replace(key,'.'=>'_'))_$(sign)")
                native_trial=local_native(trialop,g,e);bd=native_trial.data
                features=W.sensitivity_response_features(N,trialop,trial,objective,state,W.sensitivity_recovery_target(N,trialop,objective))
                forces=bd.Ke_loc*(bd.T12*state[bd.dofs]);kg=transpose(bd.T12)*N.Solver.FEM.geometric_stiffness_frame3d(bd.L,forces,(bd.Iy+bd.Iz)/bd.A)*bd.T12
                push!(samples,(K=native_trial.Ke,M=isolated_mass(trialop,g,e,ndof),features,kg))
            end
            for (field,dfield) in ((:K,:dKe),(:M,:dMe),(:features,:dstress_features),(:kg,:dKg))
                fd=(getproperty(samples[2],field)-getproperty(samples[1],field))/(2h)
                exact=getproperty(b,dfield);err=norm(exact-fd)/max(norm(exact),norm(fd),1e-12)
                @test norm(exact-fd)<=2e-5max(norm(exact),norm(fd))+1e-7
                push!(records,Dict("group"=>g.name,"variable"=>key,"quantity"=>String(field),"relative_error"=>err))
            end
            @test issymmetric(b.dKe)||norm(b.dKe-transpose(b.dKe))<1e-12norm(b.dKe)
        end
        b=W.sensitivity_analytic_bar(N,op,m,g,e,Dict(),state)
        perturb=randn(ndof);h=1e-6
        plus=W.sensitivity_analytic_bar(N,op,m,g,e,Dict(),state.+h.*perturb)
        minus=W.sensitivity_analytic_bar(N,op,m,g,e,Dict(),state.-h.*perturb)
        fd=dot(phi[b.dofs],(plus.Kg-minus.Kg)*phi[b.dofs])/(2h)
        @test dot(W.sensitivity_analytic_bar_preload_gradient(b,phi),perturb[b.dofs])≈fd rtol=1e-9
        # Nonidentity GRID output frames and WTMASS must preserve exact replay.
        angle=.37;R=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]
        rotated=merge(op,(node_R=[R for _ in op.node_R],model=deepcopy(op.model)))
        rotated.model["PARAM_WTMASS"]=.007
        rb=W.sensitivity_analytic_bar(N,rotated,m,g,e,Dict("rho"=>1.),state)
        @test rb.Ke≈local_native(rotated,g,e).Ke rtol=1e-12
        @test rb.Me≈isolated_mass(rotated,g,e,ndof) rtol=1e-12
        @test rb.dMe≈rb.Me/p["material.rho"] rtol=1e-12
        # Explicit coupled mass and cardless/negative lumped mass must follow
        # the same choice as the real assembler, including rotated GRID CDs.
        for setting in (nothing,-1,false,1,true)
            selected=merge(rotated,(model=deepcopy(rotated.model),))
            setting===nothing ? delete!(selected.model,"PARAM_COUPMASS") : (selected.model["PARAM_COUPMASS"]=setting)
            sb=W.sensitivity_analytic_bar(N,selected,m,g,e,Dict("rho"=>1.),state)
            @test sb.Me≈isolated_mass(selected,g,e,ndof) rtol=1e-12
            @test sb.dMe≈sb.Me/p["material.rho"] rtol=1e-12
        end
        if gi==1
            # Imported source offsets remain fixed when section dimensions
            # vary, in contrast to generated outside-face placements.
            source=W.imported_source(Dict("name"=>"beam_baseline.bdf","text"=>read(joinpath(stable,"beam_baseline.bdf"),String)))
            imported=W.imported_model(deepcopy(rotated.model),source,p)
            ig=only(filter(x->x.kind===:bar&&x.pid==g.pid,imported.groups))
            ie=findfirst(==(g.eids[e]),ig.eids)
            @test W.is_imported_model(imported)
            for (key,dir) in (("properties.stringer_height",Dict("dimensions"=>[0.,1.,0.,0.])),("material.rho",Dict("rho"=>1.)))
                ib=W.sensitivity_analytic_bar(N,rotated,imported,ig,ie,dir,state)
                @test iszero(norm(ib.doffset))
                @test ib.Me≈isolated_mass(rotated,g,e,ndof) rtol=1e-12
                h=1e-5abs(p[key]);samples=Matrix{Float64}[]
                for sign in (-1,1)
                    q=deepcopy(p);q[key]+=sign*h;trial=W.sensitivity_model(m,q)
                    trialop=deck_and_op(trial,"imported_fixed_$(replace(key,'.'=>'_'))_$(sign)";rotations=rotated.node_R)
                    trialop.model["PARAM_WTMASS"]=rotated.model["PARAM_WTMASS"]
                    card=trialop.model["CBARs"][string(g.eids[e])];original=rotated.model["CBARs"][string(g.eids[e])]
                    for field in ("WA","WB");card[field]=copy(original[field]);end
                    push!(samples,isolated_mass(trialop,g,e,ndof))
                end
                fd=(samples[2]-samples[1])/(2h)
                @test isapprox(ib.dMe,fd;rtol=2e-6,atol=1e-10)
                push!(records,Dict("group"=>"imported_fixed_offset","variable"=>key,"quantity"=>"M","relative_error"=>norm(ib.dMe-fd)/max(norm(fd),1e-12)))
            end
        end
    end
end
c=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes,"comparisons"=>records)))
