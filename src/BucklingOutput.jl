# Optional SOL105 output. These adapters never alter the solved pencil or modes.
function _sol105_output_options(model)
    flag(name) = begin
        value = get(model, "PARAM_" * name, 0)
        value isa Real && value in (0, 1) || throw(ArgumentError("PARAM,$name must be 0 or 1"))
        value == 1
    end
    compact, density, energy = flag("JFBKCOMP"), flag("JFBKDEN"), flag("JFBKENG")
    return Dict{String,Any}("compact"=>compact, "energy_density"=>density && !compact,
        "deformation_energy"=>energy && !compact,
        "requested_energy_density"=>density, "requested_deformation_energy"=>energy)
end

function _apply_sol105_output_overrides!(model; compact_buckling=false,
        export_element_energy=false, export_energy_density=false)
    if compact_buckling || export_element_energy || export_energy_density
        sol = _canonical_sol_type(get(model,"SOL",get(get(model,"CASE_CONTROL",Dict()),"SOL",101)))
        sol == 105 || throw(ArgumentError("Buckling output codes b/e/d require SOL 105; input is SOL $sol"))
        compact_buckling && (model["PARAM_JFBKCOMP"]=1)
        export_element_energy && (model["PARAM_JFBKENG"]=1)
        export_energy_density && (model["PARAM_JFBKDEN"]=1)
    end
    return model
end

const _BUCKLING_PROPERTY_FAMILIES = ("CSHELLs", "CBARs", "CBEAMs", "CRODs", "CONRODs", "CSOLIDs", "CELASs", "CBUSHs")
# These are the production assembly's higher-order shell subdivisions.
const _BUCKLING_SHELL_TRIANGLES = Dict(6=>((1,4,6),(4,2,5),(5,3,6),(4,5,6)),
    8=>((1,5,8),(5,2,6),(6,3,7),(7,4,8),(5,6,8),(6,7,8)))
function _buckling_element_nodes(element)
    haskey(element, "NODES") && return Int.(element["NODES"])
    return [Int(element[key]) for key in ("GA", "GB", "G1", "G2") if get(element, key, 0) > 0]
end
function _buckling_property_incidence(model)
    incidence = Dict{Int,Vector{Tuple{Int,Int}}}()
    for family in _BUCKLING_PROPERTY_FAMILIES, (key, element) in get(model, family, Dict())
        eid, pid = _solver_entry_public_id(key, element), Int(get(element, "PID", 0))
        for nid in _buckling_element_nodes(element)
            push!(get!(() -> Tuple{Int,Int}[], incidence, nid), (eid, pid))
        end
    end
    # Rigid interpolation has no property. Its reference GRID must never be
    # assigned the property of a nearby or indirectly connected shell.
    for (key, element) in get(model, "RBE2s", Dict())
        for nid in vcat(Int(get(element,"GN",0)), Int.(get(element,"GM",Int[])))
            nid > 0 && push!(get!(() -> Tuple{Int,Int}[], incidence, nid), (_solver_entry_public_id(key,element),0))
        end
    end
    for (key, element) in get(model, "RBE3s", Dict())
        nodes = Int[get(element,"REFGRID",0)]
        for group in get(element,"WT_GROUPS",[])
            append!(nodes, group isa AbstractDict ? get(group,"grids",Int[]) : group.grids)
        end
        for pair in get(element,"UM",[])
            push!(nodes, pair isa AbstractDict ? get(pair,"grid",0) : pair.grid)
        end
        for nid in unique(nodes)
            nid > 0 && push!(get!(() -> Tuple{Int,Int}[], incidence, nid), (_solver_entry_public_id(key,element),0))
        end
    end
    return incidence
end

"""Peak translational norm in a BASIC eigenvector, with every tied GRID's direct properties."""
function _buckling_peak_translation(vector, id_map, incidence; relative_tolerance=1e-6)
    maximum = 0.0
    for index in values(id_map)
        b = 6(index-1)
        magnitude = hypot(vector[b+1],vector[b+2],vector[b+3])
        isfinite(magnitude) || throw(ArgumentError("Buckling peak output requires finite mode translations"))
        maximum = max(maximum,magnitude)
    end
    nodes = Any[]; pids = Set{Int}()
    for nid in keys(id_map)
        b = 6(id_map[nid]-1)
        abs(hypot(vector[b+1],vector[b+2],vector[b+3])-maximum) <= maximum*relative_tolerance || continue
        incident = get(incidence,nid,Tuple{Int,Int}[])
        properties = sort!(unique!([pid for (_,pid) in incident if pid > 0]))
        union!(pids,properties)
        push!(nodes,Dict("node_id"=>nid,"property_ids"=>properties,
            "element_ids"=>sort!(unique!([eid for (eid,_) in incident])),
            "property_status"=>isempty(properties) ? "no_incident_property" : "direct_incident_elements"))
    end
    sort!(nodes;by=row->row["node_id"])
    return Dict("magnitude"=>maximum,"relative_tolerance"=>relative_tolerance,"nodes"=>nodes,"node_count"=>length(nodes),
        "property_ids"=>sort!(collect(pids)),"metric"=>"Euclidean norm of BASIC translations; rotations excluded",
        "normalization"=>"solver eigenvector; arbitrary amplitude", "all_translations_zero"=>maximum==0,
        "tie_policy"=>"Every tied GRID is included. An all-zero translation vector has no unique maximum; every GRID ties.")
end

function _buckling_element_volume(model, family, element)
    nodes = _buckling_element_nodes(element)
    all(nid -> haskey(model["GRIDs"],string(nid)),nodes) || return nothing
    xyz = reduce(vcat, [reshape(Float64.(model["GRIDs"][string(nid)]["X"]),1,3) for nid in nodes]; init=zeros(0,3))
    pid = string(get(element,"PID",0))
    if family == "CSHELLs"
        prop = get(get(model,"PSHELLs",Dict()),pid,nothing); prop === nothing && return nothing
        thickness = Float64(get(prop,"T",0)); thickness > 0 || return nothing
        area = if length(nodes)==3
            norm(cross(xyz[2,:]-xyz[1,:],xyz[3,:]-xyz[1,:]))/2
        elseif haskey(_BUCKLING_SHELL_TRIANGLES,length(nodes))
            sum(norm(cross(xyz[b,:]-xyz[a,:],xyz[c,:]-xyz[a,:]))/2
                for (a,b,c) in _BUCKLING_SHELL_TRIANGLES[length(nodes)])
        elseif length(nodes)==4
            sum(begin
                dr,ds = FEM.shape_derivs_quad(r,s)
                norm(cross(xyz' * dr,xyz' * ds))
            end for r in (-1/sqrt(3),1/sqrt(3)), s in (-1/sqrt(3),1/sqrt(3)))
        else
            return nothing
        end
        return area*thickness
    elseif family in ("CBARs","CBEAMs","CRODs","CONRODs")
        length(nodes)==2 || return nothing
        prop = family=="CONRODs" ? element : get(get(model,family=="CRODs" ? "PRODs" : "PBARLs",Dict()),pid,nothing)
        prop === nothing && return nothing
        length_element = norm(xyz[2,:]-xyz[1,:])
        if family in ("CBARs","CBEAMs")
            _,_,_,pa,pb = Solver.bar_offsets_and_endpoints(element,StaticArrays.SVector{3}(xyz[1,:]),StaticArrays.SVector{3}(xyz[2,:]))
            length_element = norm(pb-pa)
        end
        area = Float64(get(prop,"A",0))
        if family in ("CBARs","CBEAMs")
            stations = sort(collect(get(prop,"STATIONS",[]));by=s->get(s,"X",0.0))
            if length(stations)>=2
                area = sum((clamp(Float64(get(b,"X",1)),0,1)-clamp(Float64(get(a,"X",0)),0,1))*
                    (Float64(get(a,"A",area))+Float64(get(b,"A",area)))/2 for (a,b) in zip(stations[1:end-1],stations[2:end]))
            end
        end
        return area>0 ? area*length_element : nothing
    elseif family=="CSOLIDs"
        # Unit-density consistent mass integrates the same physical volume;
        # the three translational blocks each integrate to that volume.
        kind = get(element,"TYPE","")
        mass = kind=="CTETRA" && length(nodes)==4 ? FEM.consistent_mass_tetra4(xyz,1.0) :
            kind=="CHEXA" && length(nodes)==8 ? FEM.consistent_mass_hexa8(xyz,1.0) :
            kind=="CPENTA" && length(nodes)==6 ? FEM.consistent_mass_cpenta6(xyz,1.0) : nothing
        return mass===nothing ? nothing : sum(mass)/3
    end
    return nothing # A discrete spring has stiffness, but no physical volume.
end

function _buckling_energy_header(normalization)
    Dict{String,Any}("records"=>Any[],"normalization"=>normalization,
        "units"=>Dict("deformation_energy"=>"force * length","energy_density"=>"force / length^2","volume"=>"length^3"),
        "si_units"=>Dict("deformation_energy"=>"J","energy_density"=>"J/m^3","volume"=>"m^3"),
        "definition"=>"0.5 * u_e' * K_e * u_e from the assembled elastic element stiffness; density is energy / physical element volume. Includes element numerical stabilization; excludes geometric stiffness, rigid constraints, constraint penalties and direct matrices. SI units apply only to a consistent N-m model.")
end

"""One stiffness pass per preload evaluates all its eigenvectors together.

No element matrices are retained. The capture hook sees production transformed
matrices before constraint processing; concurrent shell writes use distinct rows.
"""
function _sol105_element_energy!(results)
    _pipeline_detail_measure!(()->_sol105_element_energy_impl!(results),"element_energy","Element deformation energy recovery")
end
function _sol105_element_energy_impl!(results)
    haskey(results,"element_energy_by_subcase") && return results["element_energy_by_subcase"]
    options = get(results,"output_options",_sol105_output_options(results["model"]))
    cache = Dict{Int,Any}()
    (options["energy_density"] || options["deformation_energy"]) || return cache
    model = results["model"]; br = get(results,"buckling",nothing)
    br === nothing && return cache
    catalog = Any[]
    for family in _BUCKLING_PROPERTY_FAMILIES, (key,element) in get(model,family,Dict())
        push!(catalog,(eid=_solver_entry_public_id(key,element),pid=Int(get(element,"PID",0)),family=family,element=element))
    end
    sort!(catalog;by=row->(row.eid,row.family))
    indices = Dict(row.eid=>i for (i,row) in enumerate(catalog))
    unique_ids = length(indices)==length(catalog)
    volumes = [_buckling_element_volume(model,row.family,row.element) for row in catalog]
    for static_sid in unique(sc.static_subcase_id for sc in br.subcases)
        cases = filter(sc->sc.static_subcase_id==static_sid,br.subcases)
        state = results["static_states"][static_sid]
        refs = [(sc,mode) for sc in cases for mode in eachindex(sc.reported_eigenvalues)]
        vectors = Matrix{Float64}(undef,length(state.u_static),1+length(refs));vectors[:,1]=state.u_static
        for (column,(sc,mode)) in enumerate(refs)
            vectors[:,column+1]=view(sc.reported_mode_shapes,:,mode)
        end
        for index in values(state.id_map), components in (1:3,4:6)
            rows = 6(index-1) .+ components
            vectors[rows,2:end] = state.node_R[index]' * vectors[rows,2:end]
        end
        energies = fill(NaN,length(catalog),size(vectors,2))
        # Subdivided shells emit several matrices with one parent EID. Other
        # parallel shell callbacks own distinct rows; only shared parent rows
        # need a lock (also safe if subdivision assembly becomes parallel).
        parent_locks = Dict(i=>ReentrantLock() for (i,row) in enumerate(catalog)
            if row.family=="CSHELLs" && haskey(_BUCKLING_SHELL_TRIANGLES,length(_buckling_element_nodes(row.element))))
        unsupported = !unique_ids ? "Duplicate element IDs prevent unambiguous energy output" :
            !hasproperty(state,:assembly_options) || state.assembly_options === nothing ? "Production stiffness capture is unavailable for this backend or legacy result" : ""
        if isempty(unsupported)
            capture = function(eid,pid,dofs,ke)
                index = get(indices,eid,0); index==0 && return
                ue = vectors[dofs,:]; fe = ke*ue
                accumulate = function()
                    for column in axes(ue,2)
                        contribution = 0.5dot(view(ue,:,column),view(fe,:,column))
                        previous = energies[index,column]
                        energies[index,column] = isnan(previous) ? contribution : previous+contribution
                    end
                end
                haskey(parent_locks,index) ? lock(accumulate,parent_locks[index]) : accumulate()
            end
            _with_active_temperature_material(model,state.temp_load_id) do
                Solver.assemble_stiffness(model;state.assembly_options...,element_capture=capture)
            end
        end
        payloads = Any[]
        for column in axes(vectors,2)
            payload = _buckling_energy_header(column==1 ? "Physical static preload displacement; energy scales with load squared" :
                "As-exported solver eigenvector; arbitrary amplitude. Energy and density scale with eigenvector amplitude squared and are not physical critical-load energies.")
            reason = column==1 && state.temp_load_id!==nothing ? "Thermal preload stored energy requires initial-strain subtraction; not available" : unsupported
            available = 0; density_available=0; complete_records=0; any_records=0
            for (index,row) in enumerate(catalog)
                energy = energies[index,column]; volume=volumes[index]
                valid = isempty(reason) && isfinite(energy)
                has_volume = volume!==nothing && isfinite(volume) && volume>0
                density_valid = valid && has_volume
                requested_count = Int(options["deformation_energy"])+Int(options["energy_density"])
                available_count = Int(options["deformation_energy"] && valid)+Int(options["energy_density"] && density_valid)
                available_count==requested_count && (complete_records+=1)
                available_count>0 && (any_records+=1)
                record = Dict{String,Any}("eid"=>row.eid,"pid"=>row.pid,"volume"=>volume,
                    "status"=>available_count==requested_count ? "available" : available_count>0 ? "partial" : "unavailable",
                    "energy_status"=>valid ? "available" : "unavailable")
                options["deformation_energy"] && (record["deformation_energy"]=valid ? energy : nothing)
                if options["energy_density"]
                    record["energy_density"]=density_valid ? energy/volume : nothing
                    record["density_status"]=density_valid ? "available" : "unavailable"
                    density_valid && (density_available+=1)
                    valid && !has_volume && (record["density_reason"]="No positive physical element volume is defined")
                end
                valid ? (available+=1) : (record["reason"]=isempty(reason) ? "Element did not provide an assembled elastic stiffness" : reason)
                push!(payload["records"],record)
            end
            payload["coverage"]=Dict("elements"=>length(catalog),"energy_available"=>available,"density_available"=>density_available)
            payload["status"]=complete_records==length(catalog) ? "complete" : any_records>0 ? "partial" : "unavailable"
            push!(payloads,payload)
        end
        cache[static_sid]=(preload=first(payloads),modes=Dict((sc.buckling_subcase_id,mode)=>payloads[i+1] for (i,(sc,mode)) in enumerate(refs)))
    end
    results["element_energy_by_subcase"] = cache
    return cache
end
