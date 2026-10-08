using Test,JSON,LinearAlgebra
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
function fixture(;sandwich=false)
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "box.rib_pitch"=>.6,"box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>1,
        "mesh.elements_spar_height"=>1,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "properties.ribs"=>Any[Dict("rib"=>2,"thickness"=>.016,"height"=>.039)],
        "properties.spar_bays"=>Any[Dict("bay"=>1,"front_thickness"=>.019)]))
    if sandwich
        for row in p["materials.shells"];row["kind"]="sandwich";end
    end
    W.build_model(p)
end
tests=@testset "Exact property ownership and chain rules" begin
    for sandwich in (false,true)
        m=fixture(;sandwich);layout=W.stiffened_panel_layout(m.grid);panel=first(layout.panels)
        token=W.panel_property_context(m.params).token;key=W.panel_key(panel)
        m.params["properties.panels"]=Any[Dict("key"=>key,"layout_token"=>token,
            "skin"=>Dict("thickness"=>.0027,"face_thickness"=>.0007,"material"=>2),
            "stringer"=>Dict("height"=>.037,"material"=>2))]
        W.register_panel_properties!(m.params,m.grid)
        definitions=W.model_property_definitions(m);catalog=W.sensitivity_catalog(m)
        for d in catalog["variables"]
            h=1e-5max(abs(d["value"]),1e-4)
            plus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(m.params),d,d["value"]+h))
            minus=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(m.params),d,d["value"]-h))
            pp=Dict(x["pid"]=>x for x in W.model_property_definitions(plus));pm=Dict(x["pid"]=>x for x in W.model_property_definitions(minus))
            affected=Int[]
            for property in definitions
                pid=property["pid"];dp=W.sensitivity_analytic_property_direction(m,d,property)
                dp["active"]&&push!(affected,pid)
                if property["kind"]=="shell"
                    @test dp["thickness"]≈(pp[pid]["thickness_m"]-pm[pid]["thickness_m"])/(2h) atol=1e-7 rtol=1e-6
                    @test dp["areal_mass"]≈(pp[pid]["areal_mass_kg_m2"]-pm[pid]["areal_mass_kg_m2"])/(2h) atol=1e-6 rtol=1e-6
                    if property["type"]=="PCOMP"
                        @test dp["ply_thicknesses"]≈[(a["thickness_m"]-b["thickness_m"])/(2h) for (a,b) in zip(pp[pid]["plies"],pm[pid]["plies"])] atol=1e-7 rtol=1e-6
                    end
                else
                    @test dp["dimensions"]≈(pp[pid]["section"]["dimensions_m"]-pm[pid]["section"]["dimensions_m"])/(2h) atol=1e-7 rtol=1e-6
                    for (field,payload) in (("E","E_Pa"),("nu","nu"),("rho","rho_kg_m3"))
                        @test dp[field]≈(pp[pid]["material"][payload]-pm[pid]["material"][payload])/(2h) atol=1e-6 rtol=1e-6
                    end
                end
            end
            @test sort(affected)==sort(d["pids"])
        end
        @test W.sensitivity_request(m,Dict("case_id"=>1,"variables"=>["material.E"],"objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z")))["derivative_method"]=="analytic"
    end
end
c=Test.get_test_counts(tests);write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes)))
