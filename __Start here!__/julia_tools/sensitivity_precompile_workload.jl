# Exercise the native static adjoint and imported-property path in the same
# solver-project context used by production workers. No child solver is started.
using OpenJFEM
let app=normpath(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer"))
    isfile(joinpath(app,"Project.toml"))||error("Shared image requires the bundled JFEM-Boxer package")
    Core.eval(Main,:(using WingFEGen))
    Base.invokelatest() do
        W=Main.WingFEGen
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
        end
    end
end
