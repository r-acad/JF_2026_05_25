# Editable isotropic materials and symmetric three-ply shell construction.
# Material 1 is the legacy global material; its explicit values remain authoritative.
const MATERIAL_SHELL_COMPONENTS=("upper_skin","lower_skin","spar_web","rib_web","leading_edge_skin","leading_edge_rib","stringer_flange")
const MATERIAL_BAR_COMPONENTS=("stringer","spar_cap","rib_stiffener","runout")
const MATERIAL_IDEALIZATION_NOTE="Illustrative editable isotropic elastic properties. Optional allowables are user-supplied postprocessing criteria, not certified material strengths. Foam and honeycomb use effective isotropic MAT1 approximations; directional core behavior, crushing and damage are not modeled."
default_material_library()=Dict{String,Any}[
    Dict("id"=>2,"name"=>"Steel (generic)","E"=>210e9,"nu"=>.30,"rho"=>7850.),
    Dict("id"=>3,"name"=>"Foam core (effective isotropic)","E"=>.1e9,"nu"=>.30,"rho"=>80.),
    Dict("id"=>4,"name"=>"Honeycomb core (effective isotropic)","E"=>.2e9,"nu"=>.25,"rho"=>50.)]
default_shell_material(component)=Dict{String,Any}("component"=>component,"kind"=>"monolithic","material"=>1,
    "face_material"=>1,"core_material"=>3,"face_thickness"=>.0005,"core_thickness"=>.01)
# Flanges inherit the existing stringer material unless explicitly assigned.
default_shell_materials()=[default_shell_material(c) for c in MATERIAL_SHELL_COMPONENTS if c!="stringer_flange"]
default_bar_materials()=[Dict{String,Any}("component"=>c,"material"=>1) for c in MATERIAL_BAR_COMPONENTS]

function material_integer(value,label;minimum=1)
    value isa Real&&!(value isa Bool)&&isfinite(value)&&isinteger(value)&&minimum<=value<=99999999||
        throw(ArgumentError("$label must be an integer between $minimum and 99999999"))
    return Int(value)
end
function material_positive(value,label)
    value isa Real&&!(value isa Bool)&&isfinite(value)&&value>0||throw(ArgumentError("$label must be finite and positive"))
    return Float64(value)
end
function material_rows(value,label,limit)
    value isa AbstractVector&&length(value)<=limit||throw(ArgumentError("$label must be an array of at most $limit tables"))
    return [begin
        raw isa AbstractDict||throw(ArgumentError("$label row $i must be a table"))
        all(k->k isa AbstractString||k isa Symbol,keys(raw))||throw(ArgumentError("$label row $i has invalid field names"))
        Dict{String,Any}(String(k)=>v for (k,v) in raw)
    end for (i,raw) in enumerate(value)]
end

# Assessment criteria belong to the Study, independently of elastic material
# data. In particular, native MAT8 strength fields do not imply a von Mises or
# maximum-strain criterion and must never be reinterpreted as one.
function normalize_material_allowables(value)
    fields=("stress","e1_t","e1_c","e2_t","e2_c","g12")
    allowed=Set(("material_id","mode",fields...))
    out=Dict{String,Any}[];seen=Set{Int}()
    for row in material_rows(value,"materials.allowables",100000)
        all(key->key in allowed,keys(row))||throw(ArgumentError("Material allowables contain an unsupported field"))
        id=material_integer(get(row,"material_id",nothing),"Allowable material ID")
        id in seen&&throw(ArgumentError("Duplicate allowables for material $id"));push!(seen,id)
        mode=get(row,"mode",nothing)
        mode in ("stress","strain")||throw(ArgumentError("Material $id allowable mode must be stress or strain"))
        result=Dict{String,Any}("material_id"=>id,"mode"=>String(mode))
        for field in fields
            haskey(row,field)||(continue)
            result[field]=material_positive(row[field],"Material $id allowable $field")
        end
        # Partially entered criteria remain incomplete, not zero-valued. This
        # lets a Study retain edits without implying a passing assessment.
        push!(out,result)
    end
    sort!(out;by=row->row["material_id"])
end

function material_allowable(p,id::Integer)
    for row in get(p,"materials.allowables",Any[])
        get(row,"material_id",nothing)==id&&return deepcopy(row)
    end
    nothing
end

function material_with_allowable(row,p)
    result=Dict{String,Any}(row)
    allowable=material_allowable(p,Int(row["id"]))
    allowable===nothing||(result["allowables"]=allowable)
    result
end

function normalize_material_library(value)
    out=Dict{String,Any}[];seen=Set{Int}()
    for row in material_rows(value,"materials.library",256)
        Set(keys(row))==Set(("id","name","E","nu","rho"))||throw(ArgumentError("Each material needs exactly id, name, E (Pa), nu and rho (kg/m3)"))
        id=material_integer(row["id"],"Material id";minimum=2)
        id in seen&&throw(ArgumentError("Duplicate material id $id"));push!(seen,id)
        row["name"] isa AbstractString||throw(ArgumentError("Material $id name must be text"))
        name=strip(String(row["name"]));!isempty(name)&&!any(iscntrl,name)||throw(ArgumentError("Material $id needs a single-line name"))
        nu=row["nu"];nu isa Real&&!(nu isa Bool)&&isfinite(nu)&&0<=nu<.5||throw(ArgumentError("Material $id Poisson ratio must be in [0, 0.5); negative (auxetic) ratios are not supported by the current solver input path"))
        push!(out,Dict("id"=>id,"name"=>name,"E"=>material_positive(row["E"],"Material $id E"),
            "nu"=>Float64(nu),"rho"=>material_positive(row["rho"],"Material $id density")))
    end
    return sort!(out,by=r->r["id"])
end
function normalize_material_assignments(value,key)
    shell=key=="materials.shells";shell||key=="materials.bars"||throw(ArgumentError("Unknown material assignment table $key"))
    components=shell ? MATERIAL_SHELL_COMPONENTS : MATERIAL_BAR_COMPONENTS
    allowed=shell ? Set(keys(default_shell_material(""))) : Set(("component","material"))
    out=Dict{String,Any}[];seen=Set{String}()
    for row in material_rows(value,key,length(components))
        all(k->k in allowed,keys(row))||throw(ArgumentError("$key contains an unsupported field"))
        component=get(row,"component",nothing);component in components||throw(ArgumentError("$key component must be one of "*join(components,", ")))
        component in seen&&throw(ArgumentError("$key repeats $component"));push!(seen,component)
        result=shell ? merge(default_shell_material(component),row) : merge(Dict{String,Any}("component"=>component,"material"=>1),row)
        for field in (shell ? ("material","face_material","core_material") : ("material",))
            result[field]=material_integer(result[field],"$component $field")
        end
        if shell
            result["kind"] in ("monolithic","sandwich")||throw(ArgumentError("$component construction must be monolithic or sandwich"))
            for field in ("face_thickness","core_thickness");result[field]=material_positive(result[field],"$component $field");end
        end
        push!(out,result)
    end
    return sort!(out,by=r->findfirst(==(r["component"]),components))
end

function material_definitions(p)
    first=Dict{String,Any}("id"=>1,"name"=>String(p["material.name"]),"E"=>Float64(p["material.E"]),
        "nu"=>Float64(p["material.nu"]),"rho"=>Float64(p["material.rho"]))
    return [material_with_allowable(row,p) for row in vcat([first],normalize_material_library(get(p,"materials.library",default_material_library())))]
end
function material_definition(p,id::Integer)
    id==1&&return material_with_allowable(Dict{String,Any}("id"=>1,"name"=>String(p["material.name"]),"E"=>Float64(p["material.E"]),
        "nu"=>Float64(p["material.nu"]),"rho"=>Float64(p["material.rho"])),p)
    for row in get(p,"materials.library",default_material_library());row["id"]==id&&return material_with_allowable(row,p);end
    throw(ArgumentError("Material $id is not defined in the material library"))
end
function material_payload(row)
    result=Dict{String,Any}("id"=>row["id"],"name"=>row["name"],"E_Pa"=>row["E"],"nu"=>row["nu"],"rho_kg_m3"=>row["rho"],"type"=>"MAT1")
    haskey(row,"allowables")&&(result["allowables"]=deepcopy(row["allowables"]))
    result
end
function material_assignment(p,component;shell=true)
    key=shell ? "materials.shells" : "materials.bars"
    for row in get(p,key,Any[])
        get(row,"component",nothing)==component&&return shell ? merge(default_shell_material(component),row) : row
    end
    return shell ? default_shell_material(component) : Dict{String,Any}("component"=>component,"material"=>1)
end
function shell_material_component(pid)
    is_movable_pid(pid)&&return "movable"
    base=component_base_pid(pid)
    base in (PID_STRINGER_WEB,PID_STRINGER_FLANGE)&&return "stringer"
    base==PID_SKIN_UPPER&&return "upper_skin"
    base==PID_SKIN_LOWER&&return "lower_skin"
    base==PID_SPAR_WEB&&return "spar_web"
    base==PID_RIB_WEB&&return "rib_web"
    base==PID_LE_SKIN&&return "leading_edge_skin"
    base==PID_LE_RIB&&return "leading_edge_rib"
    base==PID_AERO&&return "aero"
    throw(ArgumentError("No shell material component for property $pid"))
end
function bar_material_definition(p,pid)
    base=component_base_pid(pid)
    component=base==PID_STRINGER ? "stringer" : base==PID_SPAR_CAP ? "spar_cap" : base==PID_RIB_STIFFENER ? "rib_stiffener" :
        base==PID_STRINGER_RUNOUT ? "runout" : throw(ArgumentError("No bar material component for property $pid"))
    override=merge(panel_property_override(p,pid,"stringer"),component_table_override(p,pid))
    return material_definition(p,Int(get(override,"material",material_assignment(p,component;shell=false)["material"])))
end

"""PSHELL or explicit face/core/face PCOMP, with resolved physical-bay/rib total thickness."""
function shell_material_definition(p,pid::Integer)
    is_movable_pid(pid)&&return movable_shell_property(p,pid)
    component_base_pid(pid)==PID_STRINGER_FLANGE&&return shell_stringer_flange_definition(p,pid)
    if is_shell_stringer_pid(pid)
        material=bar_material_definition(p,panel_stringer_pid(something(stiffened_panel_id(pid),0)))
        thickness=nominal_shell_thickness(p,pid);nsm=nonstructural_mass_density(p,pid)
        return Dict{String,Any}("type"=>"PSHELL","construction"=>"monolithic","thickness_m"=>thickness,
            "material_id"=>material["id"],"material"=>material_payload(material),"nonstructural_mass_kg_m2"=>nsm,
            "areal_mass_kg_m2"=>thickness*material["rho"]+nsm,
            "stringer_part"=>component_base_pid(pid)==PID_STRINGER_WEB ? "web" : "flange")
    end
    component=shell_material_component(pid);assignment=component=="aero" ? default_shell_material(component) : material_assignment(p,component)
    nsm=nonstructural_mass_density(p,pid)
    assignment=merge(assignment,panel_property_override(p,pid,"skin"),component_table_override(p,pid))
    if assignment["kind"]=="monolithic"
        material=material_definition(p,Int(assignment["material"]));thickness=nominal_shell_thickness(p,pid)
        return Dict{String,Any}("type"=>"PSHELL","construction"=>"monolithic","thickness_m"=>thickness,
            "material_id"=>material["id"],"material"=>material_payload(material),"nonstructural_mass_kg_m2"=>nsm,
            "areal_mass_kg_m2"=>thickness*material["rho"]+nsm)
    end
    face=Float64(assignment["face_thickness"]);core=Float64(assignment["core_thickness"])
    family,index=divrem(pid,COMPONENT_PID_STRIDE)
    row=family==1 ? component_property_row(p,"properties.ribs",index) : family in (3,4) ? component_property_row(p,"properties.spar_bays",index) : Dict{String,Any}()
    family==15&&(row=component_property_row(p,"properties.ribs",index);family=1)
    family in (17,18)&&(family-=14;row=component_property_row(p,"properties.spar_bays",index))
    key=family==1 ? "thickness" : family==3 ? "front_thickness" : "rear_thickness"
    localrow=component_table_override(p,pid)
    if haskey(localrow,"core_thickness")
        core=Float64(localrow["core_thickness"])
    elseif haskey(row,key)
        core=Float64(row[key])-2face
    end
    core>0||throw(ArgumentError("$component property $pid sandwich total thickness must exceed twice the face thickness ($(2face) m); a rib/bay thickness override changes the core only"))
    face_material=material_definition(p,Int(assignment["face_material"]));core_material=material_definition(p,Int(assignment["core_material"]))
    thickness=2face+core
    plies=[Dict{String,Any}("material_id"=>mat["id"],"thickness_m"=>t,"angle_deg"=>0.,"material"=>material_payload(mat))
        for (mat,t) in ((face_material,face),(core_material,core),(face_material,face))]
    return Dict{String,Any}("type"=>"PCOMP","construction"=>"sandwich","thickness_m"=>thickness,
        "z0_m"=>-thickness/2,"plies"=>plies,"face_thickness_m"=>face,"core_thickness_m"=>core,
        "nonstructural_mass_kg_m2"=>nsm,
        "areal_mass_kg_m2"=>2face*face_material["rho"]+core*core_material["rho"]+nsm,
        "recovery_note"=>"Current solver z1/z2 stress values are the first/last ply midpoint stresses, not outer-surface stresses or failure margins.")
end

"""Thinnest of the actual skin properties touching either flange half."""
function shell_stringer_skin_sources(p,pid)
    id=stiffened_panel_id(pid)
    id===nothing&&throw(ArgumentError("An attached flange requires a physical panel property ID"))
    candidates=get(panel_property_context(p).flange_skins,id,Int[])
    isempty(candidates)&&throw(ArgumentError("No underlying skin property found for attached flange $pid; regenerate the shell stringer mesh"))
    sources=[merge(shell_material_definition(p,skinpid),Dict{String,Any}("pid"=>skinpid,"kind"=>"shell")) for skinpid in candidates]
    sort!(sources;by=property->(property["thickness_m"],property["pid"]))
end

"""Additional flange alone, before merging it with its supporting skin."""
function shell_stringer_added_flange(p,pid)
    material=bar_material_definition(p,panel_stringer_pid(stiffened_panel_id(pid)))
    thickness=nominal_shell_thickness(p,pid)
    assignment=findfirst(row->get(row,"component",nothing)=="stringer_flange",get(p,"materials.shells",Any[]))
    definition=assignment===nothing ? nothing : material_assignment(p,"stringer_flange")
    if definition===nothing||definition["kind"]=="monolithic"
        definition===nothing||(material=material_definition(p,Int(definition["material"])))
        plies=[Dict{String,Any}("material_id"=>material["id"],"thickness_m"=>thickness,
            "angle_deg"=>0.,"material"=>material_payload(material))]
        return (;plies,thickness,composite=false)
    end
    # The user-specified flange thickness remains authoritative. The chosen
    # sandwich supplies its face thicknesses; the remainder is its core.
    face=Float64(definition["face_thickness"]);core=thickness-2face
    core>0||throw(ArgumentError("Attached flange total thickness ($thickness m) must exceed twice its face thickness ($(2face) m); the remainder forms the core"))
    fm=material_definition(p,Int(definition["face_material"]));cm=material_definition(p,Int(definition["core_material"]))
    plies=[Dict{String,Any}("material_id"=>mat["id"],"thickness_m"=>h,"angle_deg"=>0.,"material"=>material_payload(mat))
        for (mat,h) in ((fm,face),(cm,core),(fm,face))]
    (;plies,thickness,composite=true)
end

"""One bonded section, with inward flange plies below outward skin plies.

Offsets use the PCOMP reference plane, which retains the physical A/B/D and
mass moments in the solver. No unsupported element ZOFFS field is emitted.
"""
function shell_stringer_flange_definition(p,pid)
    sources=shell_stringer_skin_sources(p,pid);skin=first(sources)
    flange=shell_stringer_added_flange(p,pid);ts=skin["thickness_m"];tf=flange.thickness;t=ts+tf
    skinplies=skin["type"]=="PCOMP" ? deepcopy(skin["plies"]) :
        [Dict{String,Any}("material_id"=>skin["material_id"],"thickness_m"=>ts,"angle_deg"=>0.,"material"=>skin["material"])]
    plies=vcat(deepcopy(flange.plies),skinplies)
    offset=Bool(get(p,"stringers.shell_offsets",false)) ? -tf/2 : 0.
    nsm=skin["nonstructural_mass_kg_m2"]
    result=Dict{String,Any}("construction"=>"combined skin and attached flange","thickness_m"=>t,
        "stringer_part"=>"flange","combined_flange"=>true,"underlying_skin_pid"=>skin["pid"],
        "underlying_skin_candidates"=>[s["pid"] for s in sources],"skin_thickness_m"=>ts,
        "added_flange_thickness_m"=>tf,"shell_offset_m"=>offset,
        "z_bottom_m"=>offset-t/2,"z_top_m"=>offset+t/2,
        "nonstructural_mass_kg_m2"=>nsm,
        "areal_mass_kg_m2"=>sum(ply["thickness_m"]*ply["material"]["rho_kg_m3"] for ply in plies)+nsm)
    if skin["type"]=="PSHELL"&&!flange.composite&&all(ply["material_id"]==skin["material_id"] for ply in plies)&&iszero(offset)
        merge!(result,Dict("type"=>"PSHELL","material_id"=>skin["material_id"],"material"=>skin["material"]))
    else
        merge!(result,Dict("type"=>"PCOMP","z0_m"=>offset-t/2,"plies"=>plies,
            "recovery_note"=>"Ply order follows the outward normal: added flange on the inside, selected skin on the outside. Skin footprint elements are replaced, never duplicated."))
    end
    result
end

function validate_materials(p)
    normalize_material_allowables(get(p,"materials.allowables",Any[]))
    library=material_definitions(p);ids=Set(row["id"] for row in library)
    for row in normalize_material_assignments(get(p,"materials.shells",Any[]),"materials.shells")
        for field in (row["kind"]=="sandwich" ? ("face_material","core_material") : ("material",))
            row[field] in ids||throw(ArgumentError("$(row["component"]) $field selects missing material $(row[field])"))
        end
    end
    for row in normalize_material_assignments(get(p,"materials.bars",Any[]),"materials.bars")
        row["material"] in ids||throw(ArgumentError("$(row["component"]) selects missing material $(row["material"])"))
    end
    for pid in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_SPAR_WEB,PID_RIB_WEB,PID_LE_SKIN,PID_LE_RIB)
        shell_material_definition(p,pid)
    end
    for row in get(p,"properties.ribs",Any[]);haskey(row,"thickness")&&shell_material_definition(p,COMPONENT_PID_STRIDE+row["rib"]);end
    for row in get(p,"properties.spar_bays",Any[]), (field,family) in (("front_thickness",3),("rear_thickness",4))
        haskey(row,field)&&shell_material_definition(p,family*COMPONENT_PID_STRIDE+row["bay"])
    end
    for row in get(p,"properties.components",Any[])
        part,indextext=split(row["key"],':');pid=component_table_family(part)*COMPONENT_PID_STRIDE+parse(Int,indextext)
        if component_table_iscap(part)||part=="rib_stiffener"
            bar_material_definition(p,pid);section_definition(p,pid)
        else;shell_material_definition(p,pid);end
    end
    return nothing
end
function model_material_definitions(m)
    ids=Set{Int}()
    for property in model_property_definitions(m)
        if get(property,"type","")=="PCOMP";union!(ids,[ply["material_id"] for ply in property["plies"]])
        else;push!(ids,property["material_id"]);end
    end
    m.params["output.include_aero_shells"]&&push!(ids,1)
    return [material_definition(m.params,id) for id in sort!(collect(ids))]
end
