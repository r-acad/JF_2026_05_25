"""Resolve element thickness and reject load laws that still use property T."""
function shell_corner_thickness_model_data(model,prop,el)
    data=shell_corner_thickness_data(el,prop)
    data===nothing && return nothing
    eid=get(el,"ID","?")
    get(model,"SOL",101) in (101,103,105) || throw(ArgumentError(
        "Shell $eid corner thickness is supported for SOL101, SOL103 and SOL105 only"))
    for key in ("GRAVs","RFORCEs","TEMPs","TEMPDs")
        isempty(get(model,key,())) || throw(ArgumentError(
            "Shell $eid corner thickness is not implemented with $key body or thermal load data"))
    end
    get(model,"_active_temp_sid",nothing)===nothing || throw(ArgumentError(
        "Shell $eid corner-thickness thermal fields are not implemented"))
    if !data.uniform && length(data.thickness)==3
        shell_tria3_corner_section(model,prop,el,data)
    end
    return data
end

"""Validate the bounded corner-thickness section law without changing a property ID."""
function shell_variable_thickness_domain(model,prop,el,coords,coords3d=nothing)
    data=shell_corner_thickness_model_data(model,prop,el)
    data===nothing && return nothing
    eid=get(el,"ID","?")
    data.uniform && return data
    # Experimental shell operators have separate section/recovery contracts.
    # Do not combine a new thickness law with a silently selected research law.
    for key in keys(ENV)
        any(prefix->startswith(key,prefix),("JFEM_Q4_","JFEM_PSHELL_","JFEM_MAT8_",
            "JFEM_KG_","JFEM_SOL101_","JFEM_SOL105_STATIC_","JFEM_PARAM_SNORM")) &&
            throw(ArgumentError("Shell $eid nonuniform corner thickness is not implemented with experimental option $key"))
    end
    get(el,"TYPE","CQUAD4")=="CQUAD4" && length(data.thickness)==4 ||
        throw(ArgumentError("Shell $eid nonuniform corner thickness requires a CQUAD4"))
    # Thickness uses the same isoparametric field as the projected element.
    # Skew and taper do not require a different section law, but a folded or
    # collapsed mapping cannot be integrated as a positive physical area.
    jacobians = [begin
        dr,ds=FEM.shape_derivs_quad(r,s)
        det([dr';ds']*coords)
    end for (r,s) in ((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))]
    all(isfinite,jacobians) && minimum(jacobians)>64eps(Float64)*maximum(abs,jacobians) ||
        throw(ArgumentError("CQUAD4 $eid nonuniform corner thickness requires a noncollapsed, convex projected mapping"))
    mid=Int(get(prop,"MID",0))
    mid>0 && Int(get(prop,"MID2",0))==mid && Int(get(prop,"MID3",0))>0 &&
        Int(get(prop,"MID4",0))==0 || throw(ArgumentError(
        "CQUAD4 $eid nonuniform corner thickness requires common MID1/MID2, explicit MID3 and no MID4"))
    br=Float64(get(prop,"BEND_RATIO",1.));tst=Float64(get(prop,"TS_T",5/6))
    all(isfinite,(br,tst)) && br>0 && tst>0 || throw(ArgumentError(
        "CQUAD4 $eid nonuniform corner thickness requires positive bending and transverse-shear ratios"))
    return data
end

function shell_variable_thickness_packet(model,prop,el,coords,coords3d,Cm,Cb,Cs,Eref;
        k6rot=100.,drill_scale=1.,supported_kinematics=true)
    data=shell_variable_thickness_domain(model,prop,el,coords,coords3d)
    data!==nothing && !data.uniform || throw(ArgumentError("A nonuniform corner-thickness section is required"))
    supported_kinematics || throw(ArgumentError(
        "CQUAD4 $(get(el,"ID","?")) nonuniform corner thickness requires ordinary projected MacNeal kinematics"))
    all(C->all(isfinite,C)&&isposdef(Symmetric(C)),(Cm,Cb,Cs)) || throw(ArgumentError(
        "CQUAD4 $(get(el,"ID","?")) nonuniform corner thickness requires positive membrane, bending and shear laws"))
    packet=FEM.quad4_variable_thickness_packet(coords,Cm,Cb,Cs,data.reference_thickness,Eref,data.thickness;
        k6rot=k6rot,drill_scale=drill_scale,bend_ratio=Float64(get(prop,"BEND_RATIO",1.)))
    # The section integrates physical energy in the projected plane. Pull it
    # back to the actual corner DOFs, retaining the map for force recovery.
    warp=coords3d===nothing ? nothing : FEM.quad4_finite_warp_displacement_map(coords,coords3d)
    warp===nothing && return packet
    return merge(packet,(K=warp'*packet.K*warp,warp_map=warp))
end

"""Bounded static PSHELL/MAT1 triangle section with explicit corner Ti."""
function shell_tria3_corner_section(model,prop,el,data)
    eid=get(el,"ID","?")
    get(model,"SOL",101)==101 || throw(ArgumentError(
        "CTRIA3 $eid nonuniform corner thickness is supported for SOL101 only; modal and prestress laws are not implemented"))
    mid=Int(get(prop,"MID",0))
    mid>0 && Int(get(prop,"MID2",0))==mid && Int(get(prop,"MID3",0))==mid &&
        Int(get(prop,"MID4",0))==0 || throw(ArgumentError(
        "CTRIA3 $eid corner-thickness section requires common explicit MID1/MID2/MID3 and no MID4"))
    mat=get(get(model,"MATs",Dict()),string(mid),nothing)
    mat!==nothing && get(mat,"TYPE","MAT1")=="MAT1" || throw(ArgumentError(
        "CTRIA3 $eid nonuniform corner thickness requires a MAT1 section"))
    E,nu,G=get(mat,"E",NaN),get(mat,"NU",NaN),get(mat,"G",NaN)
    all(isfinite,(E,nu,G)) && E>0 && G>0 && -1<nu<0.5 || throw(ArgumentError(
        "CTRIA3 $eid corner thickness requires positive isotropic material energy"))
    br,tst=get(prop,"BEND_RATIO",1.),get(prop,"TS_T",5/6)
    all(isfinite,(br,tst)) && br>0 && tst>0 || throw(ArgumentError(
        "CTRIA3 $eid corner thickness requires positive bending and shear ratios"))
    for key in keys(ENV)
        any(prefix->startswith(key,prefix),("JFEM_TRIA3_","JFEM_PSHELL_","JFEM_MAT8_",
            "JFEM_KG_","JFEM_SOL101_","JFEM_PARAM_SNORM")) && throw(ArgumentError(
            "CTRIA3 $eid nonuniform corner thickness is not implemented with experimental option $key"))
    end
    return FEM.tria3_corner_thickness_section(data.thickness)
end
