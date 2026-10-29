# In-memory SOL105 sessions for the JSONL worker. This file is an adapter;
# all assembly, equilibrium, eigenvalue and energy calculations use JFEM.
using SHA

mutable struct WarmModelSession
    baseline::Dict
    input::String
    input_sha256::String
    thicknesses::Dict{Int,Float64}
    revision::Int
    solves::Int
end
const WARM_MODELS=Dict{String,WarmModelSession}()

function _warm_thicknesses(model)
    used=Set(Int(e["PID"]) for e in values(get(model,"CSHELLs",Dict())))
    Dict(parse(Int,string(pid))=>Float64(p["T"]) for (pid,p) in get(model,"PSHELLs",Dict())
         if parse(Int,string(pid)) in used)
end

function _warm_load_model(cmd)
    name=string(get(cmd,"model_id","default"))
    haskey(WARM_MODELS,name) && error("model_id already loaded; unload it before replacing it")
    input=abspath(string(cmd["input"]))
    model=OpenJFEM.bdf_to_model(input)
    Int(get(model,"SOL",101))==105 || error("Warm model sessions currently require SOL105")
    thicknesses=_warm_thicknesses(model)
    isempty(thicknesses) && error("No active PSHELL thickness properties found")
    # Mode vectors stay in Julia. The caller receives only roots and grouped
    # energy, avoiding repeated disk exports and large JSON eigenvectors.
    OpenJFEM._apply_sol105_output_overrides!(model;compact_buckling=false,export_element_energy=true)
    session=WarmModelSession(model,input,bytes2hex(sha256(read(input))),thicknesses,0,0)
    WARM_MODELS[name]=session
    Dict("model_id"=>name,"input"=>input,"input_sha256"=>session.input_sha256,
         "properties"=>[Dict("pid"=>pid,"thickness"=>t) for (pid,t) in sort!(collect(thicknesses))],
         "revision"=>0,"parse_count"=>1)
end

function _warm_solve_model(cmd)
    name=string(get(cmd,"model_id","default"))
    haskey(WARM_MODELS,name) || error("Unknown model_id: $name")
    session=WARM_MODELS[name]
    expected=get(cmd,"expected_revision",session.revision)
    expected==session.revision || error("Model revision mismatch")
    updated=copy(session.thicknesses)
    updates=get(cmd,"thicknesses",Dict())
    updates isa AbstractDict || error("thicknesses must be an object mapping PID to absolute thickness")
    for (key,value) in updates
        pid=parse(Int,string(key))
        haskey(updated,pid) || error("PID $pid is not an active PSHELL property")
        value isa Real && !(value isa Bool) && isfinite(value) && value>0 || error("Thickness must be positive and finite")
        updated[pid]=Float64(value)
    end
    # Keep the parsed baseline immutable: solve_model owns working caches and
    # state. Geometry/parsing is reused, but stiffness and prestress are rebuilt.
    model=deepcopy(session.baseline)
    for (pid,t) in updated
        model["PSHELLs"][string(pid)]["T"]=t
    end
    start=time_ns()
    results=OpenJFEM.solve_model(model)
    Int(results["sol_type"])==105 || error("Expected SOL105 results")
    spectra=Any[]; candidates=Any[]
    expected_modes=get(cmd,"expected_modes",nothing)
    for sc in results["buckling"].subcases
        roots=Float64.(sc.reported_eigenvalues)
        isempty(roots) && error("No returned eigenvalues; cannot accept this design")
        all(isfinite,roots) || error("Non-finite eigenvalue returned")
        expected_modes===nothing || length(roots)==Int(expected_modes) || error("Returned mode count differs from expected_modes")
        push!(spectra,Dict("static_subcase_id"=>sc.static_subcase_id,
            "buckling_subcase_id"=>sc.buckling_subcase_id,"eigenvalues"=>roots))
        for (mode,root) in enumerate(roots)
            root>0 && push!(candidates,(root,sc.static_subcase_id,sc.buckling_subcase_id,mode))
        end
    end
    isempty(candidates) && error("No positive buckling eigenvalue returned")
    critical=first(sort!(candidates))
    energies=OpenJFEM._sol105_element_energy!(results)
    payload=energies[critical[2]].modes[(critical[3],critical[4])]
    payload["status"]=="complete" || error("Incomplete element-energy coverage")
    grouped=Dict{Int,Float64}()
    for record in payload["records"]
        energy=record["deformation_energy"]
        energy isa Real && isfinite(energy) && energy>=0 || error("Invalid element strain energy")
        pid=Int(record["pid"])
        grouped[pid]=get(grouped,pid,0.)+Float64(energy)
    end
    total=sum(values(grouped)); total>0 || error("Critical mode has no positive strain energy")
    properties=[Dict("pid"=>pid,"strain_energy"=>energy,"fraction"=>energy/total,
        "updateable"=>haskey(updated,pid)) for (pid,energy) in sort!(collect(grouped);by=p->(-last(p),first(p)))]
    session.thicknesses=updated
    session.revision+=!isempty(updates)
    session.solves+=1
    Dict("model_id"=>name,"revision"=>session.revision,"solve_count"=>session.solves,
         "parse_count"=>1,"spectra"=>spectra,"minimum_positive_eigenvalue"=>critical[1],
         "critical_mode"=>Dict("static_subcase_id"=>critical[2],"buckling_subcase_id"=>critical[3],"mode"=>critical[4]),
         "property_energy"=>properties,"thicknesses"=>Dict(string(pid)=>t for (pid,t) in updated),
         "solve_and_energy_seconds"=>(time_ns()-start)/1e9,"input_sha256"=>session.input_sha256)
end
