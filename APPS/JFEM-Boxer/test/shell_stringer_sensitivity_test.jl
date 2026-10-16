using Test, LinearAlgebra, JSON, WingFEGen, OpenJFEM
const W=WingFEGen; const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)
records=Any[]
function fixture(width)
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "box.rib_pitch"=>.6,"box.stringer_pitch"=>.14,"mesh.elements_between_ribs"=>2,
        "mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>2,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"aero.enabled"=>false,"loads.structure_inertia"=>false,
        "output.solution"=>"101","output.n_modes"=>3,"stringers.model"=>"shell",
        "properties.stringer_flange_width"=>width,"nonstructural.stringer"=>.07))
    W.build_model(W.normalize_params(p)[1])
end
function deck(m,name)
    path=joinpath(out,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    path
end
suite=@testset "Shell stringer catalogue, adjoint and native solutions" begin
    for width in (0.,.03)
        m=fixture(width);catalog=W.sensitivity_catalog(m)
        variables=catalog["variables"]
        localvars=filter(d->get(d,"group","")=="Panel stringers",variables)
        @test !isempty(localvars)
        @test all(d->endswith(d["id"],"#web_thickness"),localvars)
        @test all(d->!(d["id"] in ("properties.stringer_flange_width","properties.stringer_height","properties.stringer_flange_thickness")),variables)
        @test occursin("excluded",catalog["note"])
        chosen=[first(localvars),only(filter(d->d["id"]=="material.E",variables))]
        definitions=W.model_property_definitions(m)
        for d in chosen
            directions=W.sensitivity_analytic_property_directions(m,d)
            @test sort(collect(keys(directions)))==sort(d["pids"])
            step=1e-5max(abs(d["value"]),1e-4)
            plus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(m.params),d,d["value"]+step))
            minus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(m.params),d,d["value"]-step))
            pp=Dict(x["pid"]=>x for x in W.model_property_definitions(plus))
            pm=Dict(x["pid"]=>x for x in W.model_property_definitions(minus))
            for property in definitions
                property["kind"]=="shell"||continue
                pid=property["pid"];dp=W.sensitivity_analytic_property_direction(m,d,property)
                @test dp["thickness"]≈(pp[pid]["thickness_m"]-pm[pid]["thickness_m"])/(2step) atol=1e-7
                @test dp["areal_mass"]≈(pp[pid]["areal_mass_kg_m2"]-pm[pid]["areal_mass_kg_m2"])/(2step) atol=1e-6
            end
        end
        tag=width==0 ? "blade" : "flanged"
        # The last aerodynamic reference is outside the clamped root.
        objective=Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z")
        request=Dict("solution"=>"101","case_id"=>1,"objective"=>objective,
            "variables"=>[d["id"] for d in chosen],"derivative_method"=>"analytic")
        calls=Ref(0)
        solve(path)=(calls[]+=1;N.solve_model(N.bdf_to_model(path)))
        result=W.compute_sensitivity(m,request,joinpath(out,tag*"_adjoint");native=N,solve)
        @test result["status"]=="complete"
        @test calls[]==1
        rows=Dict(row["id"]=>row for row in result["rows"])
        for d in chosen
            step=1e-4max(abs(d["value"]),1e-4);values=Float64[]
            for sign in (-1,1)
                trial=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(m.params),d,d["value"]+sign*step))
                path=deck(trial,tag*"_fd_"*replace(d["id"],r"[^a-zA-Z0-9]"=>"_")*string(sign))
                push!(values,W.sensitivity_response(N.solve_model(N.bdf_to_model(path)),trial,objective).value)
            end
            fd=(values[2]-values[1])/(2step);exact=rows[d["id"]]["derivative"]
            rel=abs(exact-fd)/max(abs(exact),abs(fd),1e-12)
            @test rel<3e-3
            push!(records,Dict("model"=>tag,"variable"=>d["id"],"relative_error"=>rel))
        end
        p=deepcopy(m.params);p["output.solution"]="103"
        modal=W.build_model(p);forward=N.solve_model(N.bdf_to_model(deck(modal,tag*"_modal")))
        response=W.sensitivity_response(forward,modal,Dict("type"=>"frequency_eigenvalue","mode"=>1))
        @test isfinite(response.value)&&response.value>0
    end
end
c=Test.get_test_counts(suite)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes,"checks"=>records)))
