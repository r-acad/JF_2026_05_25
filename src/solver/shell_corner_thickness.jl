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
    data.uniform || length(data.thickness)==4 || throw(ArgumentError(
        "Shell $eid nonuniform corner thickness requires CQUAD4"))
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
    FEM.quad4_is_axis_aligned_rectangle(coords) || throw(ArgumentError(
        "CQUAD4 $eid nonuniform corner thickness currently requires an affine rectangular element"))
    (coords3d===nothing || FEM.quad4_finite_warp_displacement_map(coords,coords3d)===nothing) ||
        throw(ArgumentError("CQUAD4 $eid nonuniform corner thickness is not implemented for warped elements"))
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
        "CQUAD4 $(get(el,"ID","?")) nonuniform corner thickness requires ordinary planar MacNeal kinematics"))
    all(C->all(isfinite,C)&&isposdef(Symmetric(C)),(Cm,Cb,Cs)) || throw(ArgumentError(
        "CQUAD4 $(get(el,"ID","?")) nonuniform corner thickness requires positive membrane, bending and shear laws"))
    return FEM.quad4_variable_thickness_packet(coords,Cm,Cb,Cs,data.reference_thickness,Eref,data.thickness;
        k6rot=k6rot,drill_scale=drill_scale,bend_ratio=Float64(get(prop,"BEND_RATIO",1.)))
end
