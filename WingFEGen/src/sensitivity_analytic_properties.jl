# Exact ownership and chain rules from editable wing properties to physical
# PSHELL/PCOMP/PBARL inputs. No perturbed parameter dictionaries or decks.
function sensitivity_material_direction(d,mid)
    path=d["path"];target=0;field=""
    if length(path)==1&&startswith(path[1],"material.")
        target=1;field=split(path[1],'.')[end]
    elseif length(path)==3&&path[1]=="materials.library"
        tokens=split(d["id"],'#');target=parse(Int,tokens[2]);field=path[3]
    end
    scale=target==mid ? Float64(d["scale"]) : 0.
    Dict("E"=>field=="E" ? scale : 0.,"nu"=>field=="nu" ? scale : 0.,"rho"=>field=="rho" ? scale : 0.)
end

function sensitivity_owned_derivative(p,pid,d,part,field,owner)
    id=stiffened_panel_id(pid)
    if id!==nothing
        key=panel_property_context(p).keys[id]
        local_id="properties.panels#$key#$part#$field"
        d["id"]==local_id&&return Float64(d["scale"])
        haskey(panel_property_override(p,pid,part),field)&&return 0.
    end
    d["id"]==owner ? Float64(d["scale"]) : 0.
end

function sensitivity_shell_thickness_owner(p,pid)
    family,index=divrem(pid,COMPONENT_PID_STRIDE)
    if family==1&&haskey(component_property_row(p,"properties.ribs",index),"thickness")
        return "properties.ribs#$index#thickness"
    elseif family in (3,4)
        field=family==3 ? "front_thickness" : "rear_thickness"
        haskey(component_property_row(p,"properties.spar_bays",index),field)&&return "properties.spar_bays#$index#$field"
    end
    base=component_base_pid(pid)
    get(Dict(PID_SKIN_UPPER=>"properties.t_skin_upper",PID_SKIN_LOWER=>"properties.t_skin_lower",
        PID_SPAR_WEB=>"properties.t_spar_web",PID_RIB_WEB=>"properties.t_rib_web",
        PID_LE_SKIN=>"leading_edge.t_skin",PID_LE_RIB=>"leading_edge.t_rib",PID_AERO=>"output.t_aero_shell"),base,"")
end

function sensitivity_analytic_property_direction(m,d,property)
    p=m.params;pid=property["pid"];base=component_base_pid(pid)
    if property["kind"]=="bar"
        section=property["section"];dims=section["dimensions_m"];ddims=zeros(length(dims))
        if base==PID_STRINGER
            for (i,field) in enumerate(RIB_STIFFENER_FIELDS)
                ddims[i]=sensitivity_owned_derivative(p,pid,d,"stringer",field,"properties.stringer_"*field)
            end
        elseif base==PID_RIB_STIFFENER
            index=pid==PID_RIB_STIFFENER ? 0 : pid%COMPONENT_PID_STRIDE
            row=index==0 ? Dict() : component_property_row(p,"properties.ribs",index)
            for (i,field) in enumerate(RIB_STIFFENER_FIELDS)
                owner=haskey(row,field) ? "properties.ribs#$index#$field" : "properties.rib_stiffener_"*field
                ddims[i]=d["id"]==owner ? Float64(d["scale"]) : 0.
            end
        elseif base==PID_SPAR_CAP&&d["id"]=="properties.spar_cap_side"
            fill!(ddims,Float64(d["scale"]))
        end
        material=sensitivity_material_direction(d,property["material_id"])
        return merge(Dict{String,Any}("kind"=>"bar","dimensions"=>ddims,"active"=>any(!iszero,ddims)||any(!iszero,values(material))),material)
    end
    mids=property["type"]=="PCOMP" ? unique([ply["material_id"] for ply in property["plies"]]) : [property["material_id"]]
    materials=Dict(mid=>sensitivity_material_direction(d,mid) for mid in mids)
    dm0=dm1=dm2=0.
    if property["type"]=="PSHELL"
        dt=sensitivity_owned_derivative(p,pid,d,"skin","thickness",sensitivity_shell_thickness_owner(p,pid))
        rho=property["material"]["rho_kg_m3"];drho=materials[property["material_id"]]["rho"];h=property["thickness_m"]
        dm0=drho*h+rho*dt;dm2=drho*h^3/12+rho*h^2*dt/4;dplies=Float64[]
    else
        component=shell_material_component(pid)
        df=sensitivity_owned_derivative(p,pid,d,"skin","face_thickness","materials.shells#$component#face_thickness")
        dc=sensitivity_owned_derivative(p,pid,d,"skin","core_thickness","materials.shells#$component#core_thickness")
        family,index=divrem(pid,COMPONENT_PID_STRIDE)
        row=family==1 ? component_property_row(p,"properties.ribs",index) : family in (3,4) ? component_property_row(p,"properties.spar_bays",index) : Dict()
        field=family==1 ? "thickness" : family==3 ? "front_thickness" : "rear_thickness"
        if haskey(row,field)
            owner=family==1 ? "properties.ribs#$index#$field" : "properties.spar_bays#$index#$field"
            dc=(d["id"]==owner ? Float64(d["scale"]) : 0.)-2df
        end
        dplies=[df,dc,df];dt=sum(dplies)
        z=-property["thickness_m"]/2;dz=-dt/2
        for (ply,dh) in zip(property["plies"],dplies)
            h=ply["thickness_m"];rho=ply["material"]["rho_kg_m3"];drho=materials[ply["material_id"]]["rho"]
            top=z+h;dtop=dz+dh
            dm0+=drho*h+rho*dh
            dm1+=drho*(top^2-z^2)/2+rho*(top*dtop-z*dz)
            dm2+=drho*(top^3-z^3)/3+rho*(top^2*dtop-z^2*dz)
            z=top;dz=dtop
        end
    end
    Dict{String,Any}("kind"=>"shell","thickness"=>dt,"ply_thicknesses"=>dplies,"materials"=>materials,
        "areal_mass"=>dm0,"mass_moments"=>(dm0,dm1,dm2),
        "active"=>!iszero(dt)||any(!iszero,dplies)||any(any(!iszero,values(v)) for v in values(materials)))
end

function sensitivity_analytic_property_directions(m,d;properties=model_property_definitions(m))
    directions=Dict{Int,Dict{String,Any}}()
    for property in properties
        direction=sensitivity_analytic_property_direction(m,d,property)
        direction["active"]&&(directions[property["pid"]]=direction)
    end
    directions
end
