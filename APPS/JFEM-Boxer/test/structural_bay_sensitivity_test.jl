# julia --project=. APPS/JFEM-Boxer/test/structural_bay_sensitivity_test.jl <private-output-dir>
# Finite differences below are independent validation only. Production uses
# exact raw-moment derivatives, one baseline eigenproblem and no property solves.
using Test, LinearAlgebra, JSON, WingFEGen, OpenJFEM
const W=WingFEGen; const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)
const records=Any[]
function export_model(m,name)
    path=joinpath(out,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    parsed=N.bdf_to_model(path)
    ids=sort(parse.(Int,collect(keys(parsed["GRIDs"]))))
    id_map=Dict(id=>i for (i,id) in enumerate(ids))
    X=reduce(vcat,[transpose(Float64.(parsed["GRIDs"][string(id)]["X"])) for id in ids])
    # An output-frame rotation exercises the same mass-block transformation
    # as imported node frames without changing physical generated geometry.
    angle=.37;rotation=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]
    node_R=[copy(rotation) for _ in ids]
    (;path,model=parsed,id_map,X,node_R,ndof=6length(ids))
end
mass(op)=N.Solver.assemble_mass(op.model,op.id_map,op.X,op.node_R,op.ndof)
p=W.default_params()
merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.65,
    "planform.sweep"=>24.,"planform.twist_tip"=>-8.,"planform.dihedral"=>5.,
    "box.end_eta"=>1.,"box.rib_pitch"=>.35,"box.stringer_pitch"=>.11,
    "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,"mesh.elements_spar_height"=>1,
    "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,"fuel.enabled"=>false,
    "leading_edge.enabled"=>true,"loads.cases"=>Any[],"aero.enabled"=>false,
    "loads.structure_inertia"=>false,"output.solution"=>"103","output.n_modes"=>6,
    "mass.structural_representation"=>"bay_concentrated","nonstructural.stringer"=>.17,
    "nonstructural.upper_skin"=>.8,"nonstructural.lower_skin"=>.5))
first(p["materials.shells"])["kind"]="sandwich"
m=W.build_model(W.normalize_params(p)[1]);p=m.params
catalog=W.sensitivity_catalog(m)["variables"]
ids=["material.rho","properties.t_skin_lower","materials.shells#upper_skin#core_thickness",
    "materials.shells#upper_skin#face_thickness","properties.stringer_height","properties.spar_cap_side"]
variables=[only(filter(d->d["id"]==id,catalog)) for id in ids]
op=export_model(m,"baseline_mass")
suite=@testset "Analytic bay mass and global-mode sensitivities" begin
    @test length(op.model["CONM2s"])==length(m.grid.ribs)-1
    for d in variables
        directions=W.sensitivity_analytic_property_directions(m,d)
        exact=W.sensitivity_analytic_bay_mass(N,op,m,directions)
        step=1e-5max(abs(d["value"]),1e-4)
        samples=[]
        for sign in (-1,1)
            trial=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),d,d["value"]+sign*step))
            trialop=export_model(trial,"mass_"*replace(d["id"],r"[^a-zA-Z0-9]"=>"_")*"_"*string(sign))
            @test trialop.id_map==op.id_map
            @test trialop.X==op.X
            push!(samples,mass(trialop))
        end
        fd=(samples[2]-samples[1])/(2step)
        relative=norm(exact-fd)/max(norm(fd),1e-12)
        @test relative<2e-6
        @test norm(exact-exact')<=1e-12max(norm(exact),1.)
        push!(records,Dict("variable"=>d["id"],"mass_tangent_relative_error"=>relative))
    end
    # Complete native eigensolve + production adjoint path; compare selected
    # well-separated low modes to independently solved perturbed decks.
    objective=Dict("type"=>"frequency_eigenvalue","mode"=>1)
    chosen=variables[[1,2,5]]
    request=Dict("solution"=>"103","case_id"=>1,"objective"=>objective,
        "variables"=>[d["id"] for d in chosen],"derivative_method"=>"analytic")
    calls=Ref(0)
    solve(path)=(calls[]+=1;N.solve_model(N.bdf_to_model(path)))
    result=W.compute_sensitivity(m,request,joinpath(out,"sensitivity");native=N,solve)
    W.sensitivity_json_write(joinpath(out,"sensitivity_result.json"),result)
    @test result["status"]=="complete"
    @test calls[]==1
    @test result["solver_counts"]["finite_difference_samples"]==0
    @test result["solver_counts"]["perturbed_forward_solves"]==0
    rows=Dict(row["id"]=>row for row in result["rows"])
    for d in chosen
        step=1e-4max(abs(d["value"]),1e-4);values=Float64[]
        for sign in (-1,1)
            trial=W.sensitivity_model(m,W.sensitivity_set!(deepcopy(p),d,d["value"]+sign*step))
            trialop=export_model(trial,"mode_"*replace(d["id"],r"[^a-zA-Z0-9]"=>"_")*"_"*string(sign))
            forward=N.solve_model(trialop.model)
            push!(values,W.sensitivity_response(forward,trial,objective).value)
        end
        fd=(values[2]-values[1])/(2step);exact=rows[d["id"]]["derivative"]
        relative=abs(exact-fd)/max(abs(exact),abs(fd),1e-12)
        @test relative<2e-3
        push!(records,Dict("variable"=>d["id"],"modal_derivative_relative_error"=>relative,
            "analytic"=>exact,"finite_difference_validation"=>fd))
    end
end
counts=Test.get_test_counts(suite)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,
    "checks"=>records,"production_forward_solves"=>1,"production_finite_difference_samples"=>0)))
