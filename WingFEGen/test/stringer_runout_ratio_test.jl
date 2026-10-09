using Test, TOML
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
const evidence=Dict{String,Any}()
function parameters(ratio;masters=false)
    merge(W.default_params(),Dict{String,Any}("mesh.stringer_runout_ratio"=>ratio,
        "box.rib_pitch"=>1.0,"mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>13,"airfoil.n_points"=>41,
        "ribs.masters"=>(masters ? [Dict("eta"=>.45,"mode"=>"rear_spar_angle","angle"=>95.,"pitch"=>1.)] : Any[])))
end
function make_grid(p)
    w=W.make_wing(p);xcs,_=W.chord_stations(w,p);etas,ribs,_=W.span_stations(w,p)
    W.stringer_grid(w,p,xcs,etas,ribs,p["mesh.elements_spar_height"])
end
function retirements(g)
    [something(findfirst(!=(0),g.collapsed[i+1,:]),length(g.etas)+1) for i in g.stringer_indices]
end
@testset "Configurable spar clearance for stringer runout" begin
    @test W.default_params()["mesh.stringer_runout_ratio"]==.75
    @test first(W.normalize_params(Dict()))["mesh.stringer_runout_ratio"]==.75
    legacy=W.default_params();delete!(legacy,"mesh.stringer_runout_ratio")
    @test first(W.normalize_params(legacy))["mesh.stringer_runout_ratio"]==1.
    for value in (0.,-.1,1.01,Inf,NaN)
        @test_throws ArgumentError W.validate_params(parameters(value))
    end
    for masters in (false,true)
        models=Dict{Float64,Any}()
        for ratio in (.5,.75,1.)
            p=parameters(ratio;masters);g=make_grid(p);models[ratio]=g
            pitch=p["box.stringer_pitch"];threshold=ratio*pitch;spars=W.spar_geometry(p)
            @test all(isapprox(d*g.wing.chord_root,pitch;atol=1e-11) for d in diff(g.xcs[2:end-1]))
            for i in g.stringer_indices,j in 0:W.nj(g),upper in (false,true)
                g.collapsed[i+1,j+1]==0||continue
                eta=W.grid_surface_eta(g,i,j,upper);surface=upper ? W.upper_point : W.lower_point
                point=W.grid_point(g,i,j,upper ? g.nh : 0)
                front=surface(g.wing,eta,W.spar_surface_xc(g.wing,spars,eta,:front))[1]
                rear=surface(g.wing,eta,W.spar_surface_xc(g.wing,spars,eta,:rear))[1]
                @test min(point[1]-front,rear-point[1])>=threshold-1e-9
            end
            for i in g.stringer_indices
                row=findfirst(!=(0),g.collapsed[i+1,:]);row===nothing&&continue
                @test all(==(g.collapsed[i+1,row]),g.collapsed[i+1,row:end])
            end
            refined=W.refine_stringer_bays(g,3)
            @test refined.etas==g.etas
            @test refined.collapsed[refined.stringer_indices.+1,:]==g.collapsed[g.stringer_indices.+1,:]
            roundtrip,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p))))
            @test roundtrip["mesh.stringer_runout_ratio"]==ratio
            evidence["$(masters ? "master" : "flight")_$ratio"]=Dict("etas"=>g.etas,
                "retirement_rows"=>retirements(g),"clearance_m"=>threshold)
        end
        # Reducing the cutoff moves actual runout endpoints outboard; it does
        # not change root pitch or merely add/remove shell subdivisions.
        @test models[.5].xcs==models[1.].xcs
        endpoint(g,i)=begin
            row=findfirst(!=(0),g.collapsed[i+1,:]);row===nothing ? Inf : g.etas[row]
        end
        @test all(endpoint(models[.5],i)>=endpoint(models[1.],i)-1e-12 for i in models[1.].stringer_indices)
        @test any(endpoint(models[.5],i)>endpoint(models[1.],i)+1e-12 for i in models[1.].stringer_indices)
    end
    m=W.build_model(parameters(.75))
    @test W.all_checks_pass(m)
    @test any(pair->pair[1]=="Stringer runout distance / pitch",m.info)
    @test any(g->g.kind==:tria&&W.n_elements(g)>0,m.groups)
    # Old saved signatures omitted the ratio; only the legacy one-pitch rule
    # may match them. Load-formulation version remains a separate stale guard.
    legacy_model=W.build_model(parameters(1.))
    oldparams=copy(legacy_model.params);delete!(oldparams,"mesh.stringer_runout_ratio")
    oldmodel=W.sensitivity_model(legacy_model,oldparams)
    for version in (1,2)
        record=Dict("baseline_model_signature"=>W.sensitivity_model_signature(oldmodel;version),"baseline_model_signature_version"=>version)
        @test W.sensitivity_result_matches_model(record,legacy_model)
        @test !W.sensitivity_result_matches_model(record,W.sensitivity_model(legacy_model,merge(oldparams,Dict("mesh.stringer_runout_ratio"=>.75))))
    end
end
if !isempty(ARGS)
    mkpath(ARGS[1]);write(joinpath(ARGS[1],"runout_summary.json"),W.JSON.json(evidence,2))
end
