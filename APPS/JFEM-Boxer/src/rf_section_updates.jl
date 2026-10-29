# Fixed-load sizing metadata. Reuse the analysed topology; never generate a
# mesh, modify AppState.model, or relabel the stored FE results as current.
function rf_equivalent_controls(a,b,key)
    startswith(key,"sensitivity.") && return true
    key in ("output.title","output.reference_file","jfem.repo","jfem.output_dir",
        "jfem.output_formats","jfem.timeout_minutes") && return true
    key in ("planform.leading_edge_points","planform.trailing_edge_points","box.front_spar_points","box.rear_spar_points") || return false
    # Editors expose the implicit root/tip handles even when a saved input has
    # an empty table. Compare the physical polylines, not those editor handles.
    g=planform_geometry(a);nominal=point_nominal(a,key)
    function line(p)
        rows=normalize_planform_points(p[key],key;nominal)
        values=Dict(0.0=>nominal*g.base_chord_root,1.0=>nominal*g.base_chord_tip)
        for row in rows
            values[row["eta"]]=(nominal+row["dxc"])*g.base_chord_root*(1-(1-g.base_taper)*row["eta"])
        end
        es=sort!(collect(keys(values)));return es,[values[e] for e in es]
    end
    ae,av=line(a);be,bv=line(b);etas=sort!(unique(vcat(ae,be)))
    all(e->isapprox(edge_offset(ae,av,e),edge_offset(be,bv,e);atol=1e-12*max(1.,g.base_chord_root),rtol=1e-12),etas) || return false
    if key=="box.rear_spar_points"
        ap=stringer_path(a);bp=stringer_path(b)
        all(e->isapprox(stringer_offset(ap,e),stringer_offset(bp,e);atol=1e-12,rtol=1e-12),
            unique(vcat(ap.etas,bp.etas))) || return false
    end
    return true
end

function rf_section_update(m::Model, p::Dict{String,Any})
    is_imported_model(m) && throw(ArgumentError("Fixed-load sizing requires a generated model"))
    changed=[s.key for s in SCHEMA if get(p,s.key,nothing)!=get(m.params,s.key,nothing)]
    allowed(key)=occursin(r"^(properties\.|material\.|materials\.)",key) ||
        key in ("stringers.euler_fixity_coefficient","stringers.skin_fixity_coefficient")
    unsupported=filter(key->!allowed(key)&&!rf_equivalent_controls(m.params,p,key),changed)
    isempty(unsupported) || throw(ArgumentError("Geometry, loads or analysis settings changed ($(join(unsupported,", "))); create the FEM and rerun analysis"))
    # Enabling/disabling physical stiffeners changes membership, not capacity.
    old_components=resolved_component_properties(m.params,length(m.grid.ribs))
    new_components=resolved_component_properties(p,length(m.grid.ribs))
    getproperty.(old_components.ribs,:stiffener_enabled)==getproperty.(new_components.ribs,:stiffener_enabled) ||
        throw(ArgumentError("Changing stiffener membership requires a new FEM"))
    register_panel_properties!(p,m.grid)
    candidate=Model((f===:params ? p : getfield(m,f) for f in fieldnames(Model))...)
    # Shell-stringer height/flange width physically move GRIDs. A fixed-force
    # shell estimate cannot represent those new integration surfaces.
    if shell_stringers(p)
        for panel in stiffened_panel_layout(m.grid).panels
            old=panel_stringer_dimensions(m.params,panel.stringer_pid)
            new=panel_stringer_dimensions(p,panel.stringer_pid)
            old[1:2]==new[1:2] || throw(ArgumentError("Shell-stringer height/flange width moves FE nodes; recreate the FEM and rerun analysis"))
        end
    end
    groups=[Dict("name"=>g.name,"kind"=>String(g.kind),"pid"=>g.pid,
        "properties"=>element_properties(candidate,g)) for g in m.groups if !isempty(g.eids)]
    return Dict("ok"=>true,"groups"=>groups,
        "stiffened_panels"=>stiffened_panels_payload(candidate),
        "component_buckling"=>component_buckling_payload(candidate),
        "changed_keys"=>changed,"fixed_geometry"=>true)
end

function handle_rf_sections(st::AppState, req)
    try
        raw=JSON.parse(String(req.body));m=st.model
        m===nothing && throw(ArgumentError("Create the FEM before sizing properties"))
        baseline=first(normalize_params(raw["baseline"]))
        all(s->get(baseline,s.key,nothing)==get(m.params,s.key,nothing),SCHEMA) ||
            throw(ArgumentError("The server FEM changed. Recreate this Study's FEM before sizing properties"))
        p=first(normalize_params(raw["parameters"]))
        return json_response(rf_section_update(m,p))
    catch error
        return error_response("Fixed-load property estimate: "*describe_error(error))
    end
end
