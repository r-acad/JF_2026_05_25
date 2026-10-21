# Exercise imported and generated static adjoints in the production package
# environment, including local shell thickness and PBARL section dimensions.
# The generated path has different dispatch from an imported material variable;
# warming only the latter leaves most Boxer sensitivity code to compile on use.
# No child solver is started and all generated outputs are temporary.
using OpenJFEM
let app=normpath(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer"))
    isfile(joinpath(app,"Project.toml"))||error("Shared image requires the bundled JFEM-Boxer package")
    Core.eval(Main,:(using WingFEGen))
    Base.invokelatest() do
        W=Main.WingFEGen
        records=Dict{String,Any}[]
        deck=normpath(joinpath(@__DIR__,"..","examples","precompile","sol101_adjoint_shell.bdf"))
        mktempdir() do output
            text=read(deck,String)
            source=Base.invokelatest(W.imported_source,Dict("name"=>basename(deck),"text"=>text))
            model=Base.invokelatest(W.imported_model,OpenJFEM.bdf_to_model(deck),source,Base.invokelatest(W.default_params))
            Base.invokelatest(W.imported_prepare_loads!,OpenJFEM,model)
            request=Dict("solution"=>"101","case_id"=>1,"variables"=>["reference.MAT1#1#E"],
                "objective"=>Dict("type"=>"displacement","node_id"=>3,"component"=>"z"),"derivative_method"=>"analytic")
            solve=path->OpenJFEM.solve_model(OpenJFEM.bdf_to_model(path))
            result=Base.invokelatest(W.compute_sensitivity,model,request,output;native=OpenJFEM,solve)
            result["status"]=="complete"||error("Sensitivity warm-up did not complete: "*W.JSON.json(result["rows"]))
            push!(records,Dict("kind"=>"imported","variables"=>length(result["rows"]),"status"=>result["status"],
                "finite_derivatives"=>all(row->row["status"]=="ok"&&isfinite(row["derivative"]),result["rows"])))
        end
        mktempdir() do output
            parameters=merge(W.default_params(),Dict{String,Any}(
                "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
                "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
                "box.end_eta"=>1.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.12,
                "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
                "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
                "loads.method"=>"analytic","loads.cases"=>Any[],"fuel.enabled"=>false))
            model=W.build_model(parameters)
            catalog=W.sensitivity_catalog(model)["variables"]
            # Select actual local variables rather than a shared family alias,
            # so this remains a small workload as the generator gains features.
            selected=String[]
            for (part,field) in (("skin","thickness"),("stringer","flange_width"),
                    ("stringer","height"),("stringer","flange_thickness"),("stringer","web_thickness"))
                index=findfirst(row->startswith(row["id"],"properties.panels#")&&endswith(row["id"],"#$part#$field"),catalog)
                index===nothing&&error("Generated sensitivity warm-up lacks $part $field")
                push!(selected,catalog[index]["id"])
            end
            push!(selected,"material.E")
            request=Dict("solution"=>"101","case_id"=>1,"variables"=>selected,
                "objective"=>Dict("type"=>"displacement","node_id"=>last(model.node_ids),"component"=>"z"),
                "derivative_method"=>"analytic")
            solve=path->OpenJFEM.solve_model(OpenJFEM.bdf_to_model(path))
            result=Base.invokelatest(W.compute_sensitivity,model,request,output;native=OpenJFEM,solve)
            result["status"]=="complete"||error("Generated sensitivity warm-up did not complete: "*W.JSON.json(result["rows"]))
            finite=all(row->row["status"]=="ok"&&isfinite(row["derivative"]),result["rows"])
            finite||error("Generated sensitivity warm-up returned unavailable derivatives")
            push!(records,Dict("kind"=>"generated","variables"=>length(result["rows"]),"status"=>result["status"],
                "finite_derivatives"=>finite,"solver_counts"=>result["solver_counts"],
                "has_shells"=>any(g->g.kind in (:quad,:tria),model.groups),
                "has_bars"=>any(g->g.kind===:bar,model.groups)))
        end
        records
    end
end
