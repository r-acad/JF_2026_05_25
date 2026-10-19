# Run author-generated analytical cases through the installed/current JFEM.
# julia --project=<JFEM root> --threads=2 run_academic_cases.jl INPUT_ROOT OUTPUT_ROOT [ACA01 ...]
using OpenJFEM, JSON, LinearAlgebra, Dates, SHA
BLAS.set_num_threads(1)
const INPUT=abspath(ARGS[1]); const OUTPUT=abspath(ARGS[2]);mkpath(OUTPUT)
const SELECT=length(ARGS)>2 ? Set(ARGS[3:end]) : Set(["ACA01","ACA02","ACA03","ACA04","ACA05"])
jsonsafe(value::AbstractFloat)=isfinite(value) ? value : string(value)
jsonsafe(value::AbstractDict)=Dict(string(k)=>jsonsafe(v) for (k,v) in value)
jsonsafe(value::AbstractArray)=[jsonsafe(v) for v in value]
jsonsafe(value)=value
jwrite(path,data)=open(io->JSON.print(io,jsonsafe(data),2),path,"w")

function nodal_vectors(u,ids,order)
 [[Float64(u[6*(ids[g]-1)+k]) for k in 1:3] for g in order]
end

function visual_export(result,definition,run)
 ids=result["id_map"]; order=sort(collect(keys(ids)));X=result["node_coords"]
 nodes=[Dict("id"=>g,"xyz"=>[Float64(X[ids[g],k]) for k in 1:3]) for g in order]
 mesh=result["mesh"]; elements=Any[]
 for (key,typ) in (("quads","CQUAD4"),("trias","CTRIA3"),("bars","CBAR"),("rods","CROD"))
  for el in get(mesh,key,Any[])
   connectivity=haskey(el,"nodes") ? el["nodes"] : [el["ga"],el["gb"]]
   push!(elements,Dict("id"=>el["eid"],"type"=>typ,"nodes"=>connectivity,"property_id"=>get(el,"pid",1)))
  end
 end
 states=Any[];sol=run["sol"]
 if sol in (101,106)
  for sc in result["subcases"]
   vecs=nodal_vectors(sc["raw_displacement"],ids,order)
   push!(states,Dict("name"=>"Static displacement","kind"=>"static","subcase"=>sc["sid"],"displacements"=>vecs,"unit"=>"m"))
  end
 else
  U=result["_raw_mode_shapes"]
  for j in 1:min(size(U,2),6)
   vectors=nodal_vectors(U[:,j],ids,order);scale=maximum(sqrt(sum(abs2,v)) for v in vectors);scale=max(scale,eps())
   vectors=[v./scale for v in vectors]
   st=Dict{String,Any}("name"=>"Mode $j","kind"=>sol==105 ? "buckling" : "modal","mode"=>j,"eigenvalue"=>result["eigenvalues"][j],"displacements"=>vectors,"unit"=>"dimensionless; maximum nodal translation normalized to 1")
   sol==103 && (st["frequency"]=result["frequencies"][j])
   push!(states,st)
  end
  if sol==105 && haskey(result,"u_static")
   push!(states,Dict("name"=>"Static preload","kind"=>"preload","subcase"=>1,"unit"=>"m","displacements"=>nodal_vectors(result["u_static"],ids,order)))
  end
 end
 return Dict("case_id"=>definition["id"],"title"=>definition["title"],"run"=>run["name"],"nodes"=>nodes,"elements"=>elements,"states"=>states,"parameters"=>run["parameters"])
end

function metric_rows(result,definition,run)
 rows=Any[];id=definition["id"];p=run["parameters"];tol=definition["acceptance"]["relative_error_percent"]
 function add(quantity,value,reference,unit;mode=nothing)
  err=100abs(value-reference)/max(abs(reference),eps())
  push!(rows,Dict("case_id"=>id,"run"=>run["name"],"mesh_n"=>run["n"],"sol"=>run["sol"],"quantity"=>quantity,"mode"=>mode,"value"=>value,"reference"=>reference,"error_percent"=>err,"unit"=>unit,"tolerance_percent"=>tol,"passed"=>err<=tol))
 end
 if id in ("ACA01","ACA02")
  if run["sol"]==101
   u=result["subcases"][1]["raw_displacement"];i=result["id_map"][run["n"]+1];L=p["length_m"];F=p["load_N"];E=p["E_Pa"];I=p["I_m4"]
   exact=F*L^3/(3E*I)
   id=="ACA02" && (exact+=F*L/(p["shear_factor"]*(E/(2*(1+p["nu"])))*p["area_m2"]))
   add("tip transverse displacement",u[6*(i-1)+2],exact,"m")
   add("tip section rotation",abs(u[6*(i-1)+6]),F*L^2/(2E*I),"rad")
  else
   beta=[1.875104068711961,4.694091132974174,7.854757438237613,10.995540734875467]
   for j in 1:min(4,length(result["frequencies"]))
    ref=beta[j]^2/(2pi*p["length_m"]^2)*sqrt(p["E_Pa"]*p["I_m4"]/(p["rho_kg_m3"]*p["area_m2"]))
    add("bending frequency",result["frequencies"][j],ref,"Hz";mode=j)
   end
  end
 elseif id in ("ACA03","ACA04")
  vals=id=="ACA03" ? result["eigenvalues"] : result["frequencies"]
  for j in 1:min(6,length(vals))
   add(id=="ACA03" ? "buckling load factor" : "natural frequency",vals[j],p["analytical_modes"][j]["value"],id=="ACA03" ? "dimensionless" : "Hz";mode=j)
  end
 else
  u=result["subcases"][1]["raw_displacement"];ids=result["id_map"];n=run["n"];g=n+1;top=n*(n+1)+1
  add("tip axial displacement",u[6*(ids[g]-1)+1],p["exact_tip_ux_m"],"m")
  add("top lateral contraction",u[6*(ids[top]-1)+2],p["exact_top_uy_m"],"m")
 end
 rows
end

records=Any[];allrows=Any[]
for cid in ("ACA01","ACA02","ACA03","ACA04","ACA05")
 cid in SELECT || continue
 definition=JSON.parsefile(joinpath(INPUT,cid,"case_definition.json"));caseout=joinpath(OUTPUT,cid);mkpath(caseout)
 jwrite(joinpath(caseout,"case_definition.json"),definition)
 caserows=Any[];case_records=Any[]
 for run in definition["runs"]
  name=run["name"];out=joinpath(caseout,name);mkpath(out);deck=joinpath(INPUT,cid,run["deck"])
  println("[ACADEMIC_START] $cid $name");flush(stdout)
  started=now(UTC);t=time()
  try
   result=OpenJFEM.main(deck;output_dir=out,export_json=true,export_jfem_binary=true,export_report=false)
   rows=metric_rows(result,definition,run);append!(caserows,rows);append!(allrows,rows)
   vis=visual_export(result,definition,run);jwrite(joinpath(out,"visual_data.json"),vis)
   rec=Dict("case_id"=>cid,"run"=>name,"status"=>"solved","wall_seconds_including_first_use"=>time()-t,"deck_sha256"=>bytes2hex(sha256(read(deck))),"started_utc"=>string(started),"finished_utc"=>string(now(UTC)),"metrics"=>rows,"solver_diagnostics"=>get(result,"solver_diagnostics",nothing))
   jwrite(joinpath(out,"receipt.json"),rec);push!(records,rec);push!(case_records,rec)
   println("[ACADEMIC_DONE] $cid $name $(maximum(r["error_percent"] for r in rows)) percent");flush(stdout)
  catch e
   msg=sprint(showerror,e,catch_backtrace());write(joinpath(out,"error.txt"),msg)
   rec=Dict("case_id"=>cid,"run"=>name,"status"=>"failed","error"=>msg,"wall_seconds_including_first_use"=>time()-t)
   push!(records,rec);push!(case_records,rec);println("[ACADEMIC_FAILED] $cid $name $msg");flush(stdout)
  end
  jwrite(joinpath(OUTPUT,"results.json"),Dict("runs"=>records,"metrics"=>allrows))
 end
 jwrite(joinpath(caseout,"results.json"),Dict("runs"=>case_records,"metrics"=>caserows))
 # Finest mesh at largest load for the nonlinear display; otherwise largest n.
 successful=filter(r->r["status"]=="solved",case_records)
 if !isempty(successful)
  representative=last(successful)["run"]
  cp(joinpath(caseout,representative,"visual_data.json"),joinpath(caseout,"visual_data.json");force=true)
 end
end
println("[ACADEMIC_FINISHED] $(length(records)) runs, $(length(allrows)) comparisons")
