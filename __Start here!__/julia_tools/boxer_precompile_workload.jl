# Executed in a temporary process by PackageCompiler, never in the user's study.
using WingFEGen
using Pkg
Pkg.activate(normpath(joinpath(@__DIR__,"..",".."));io=devnull)
Pkg.dependencies()
let W=WingFEGen
    W.main(["--help"])
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "box.rib_pitch"=>.6,"box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","fuel.enabled"=>false))
    mktempdir() do output
        input=joinpath(output,"input.toml");write(input,W.params_to_toml(p))
        model=W.build_model(p)
        W.all_checks_pass(model)||error("JFEM-Boxer precompile model checks failed")
        W.mesh_payload(model)
        W.sensitivity_catalog(model)
        W.write_reference(model,joinpath(output,"model.bdf"))
        aerodynamic=W.build_model(merge(p,Dict{String,Any}(
            "loads.method"=>"vortex_lattice","loads.cases"=>Any[],
            "aero.span_panels"=>4,"aero.chord_panels"=>2)))
        W.all_checks_pass(aerodynamic)||error("JFEM-Boxer aerodynamic warm-up checks failed")
        W.mesh_payload(aerodynamic)
        state=W.AppState(dirname(dirname(pathof(W))),input;deck_store_dir=joinpath(output,"decks"))
        W.handle_input(state,W.HTTP.Request("GET","/api/input")).status==200||error("input route failed")
        W.handle_generate(state,W.HTTP.Request("POST","/api/generate",[],W.JSON.json(p))).status==200||error("generation route failed")
        router=W.make_router(state)
        server=W.HTTP.serve!(router,"127.0.0.1",0)
        close(server)
        precompile(W.run_app,(String,))
    end
end
