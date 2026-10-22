# Shared by native recovery and Boxer result import. No stiffness or solver
# state is modified here. Units follow the input model (Pa for Boxer SI data).
# Classical thin-wall VQ/I shear flow and Saint-Venant open-section torsion:
# https://www.ae.msstate.edu/tupas/SA2/chA14.7_text.html
# https://www.ae.msstate.edu/tupas/SA2/chA14.8_text.html
# https://www.ae.msstate.edu/tupas/SA2/chA6.6_text.html

"""Conservative equivalent-stress envelope within a thin-walled T beam model.

Normal stress uses the actual finite-thickness polygon, centroid and inertias.
Wall-parallel shear uses VQ/I, starting at each free edge. Triangle bounds
combine the two transverse components and the free-warping Saint-Venant
torsion |T|t/J. The possible torque from the centroid/shear-centre offset is
also bounded, not discarded. The largest normal and shear magnitudes may
occur at different locations: their combination is a conservative envelope,
not a pointwise von Mises maximum. Junction concentrations, restrained
warping and transverse normal stress are outside this beam-section model.
"""
function beam_t_stress_envelope(prop::AbstractDict, forces::AbstractDict;
        material_type="MAT1", varying_section=false, distributed_loading=false)
    unavailable(reason)=Dict{String,Any}("von_mises_recovery"=>Dict{String,Any}(
        "status"=>"unavailable","method"=>"thin_walled_t_section_envelope","reason"=>reason))
    uppercase(string(material_type))=="MAT1"||return unavailable("The T-section equivalent-stress envelope requires an isotropic MAT1 material.")
    uppercase(string(get(prop,"TYPE","")))=="T"||return unavailable("Equivalent-stress recovery is not defined for this beam section; the current section-envelope method supports PBARL T only.")
    varying_section&&return unavailable("The T-section equivalent-stress envelope requires a constant section; tapered/station-varying beams need interior recovery.")
    distributed_loading&&return unavailable("Distributed beam loading requires interior force/stress recovery before a complete equivalent-stress envelope can be reported.")
    numeric(v)=v isa Real&&!(v isa Bool)&&isfinite(v)
    dims=get(prop,"DIMS",nothing)
    dims isa AbstractVector&&length(dims)==4&&all(numeric,dims)||return unavailable("The four physical T-section dimensions are missing or nonfinite.")
    b,h,tf,tw=Float64.(dims);hw=h-tf
    b>tw>0&&h>tf>0||return unavailable("T-section dimensions must define a positive nonoverlapping flange and web.")
    max(tf/b,tw/hw)<=.1*(1+1e-12)||return unavailable("The thin-wall stress model requires flange thickness/full width and web thickness/clear height no greater than 0.10; use shell or solid recovery for thicker sections.")
    area=b*tf+hw*tw;yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/area;yf=hw+tf/2
    i1=tw*hw^3/12+hw*tw*(yc-hw/2)^2+b*tf^3/12+b*tf*(yf-yc)^2
    i2=hw*tw^3/12+tf*b^3/12;j=(hw*tw^3+b*tf^3)/3
    for (key,expected) in (("A",area),("I1",i1),("I2",i2),("J",j))
        value=get(prop,key,nothing)
        numeric(value)&&value>0&&isapprox(value,expected;rtol=1e-8,atol=0.)||return unavailable("Beam $key is inconsistent with its physical T dimensions; equivalent-stress recovery cannot invent a compatible section.")
    end
    i12=get(prop,"I12",0.)
    numeric(i12)&&abs(i12)<=1e-12*sqrt(i1*i2)||return unavailable("The symmetric T-section stress model requires zero product of inertia.")
    required=("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2")
    missing=[key for key in required if !numeric(get(forces,key,nothing))]
    isempty(missing)||return unavailable("Incomplete beam force recovery: missing/nonfinite "*join(missing,", ")*". Axial stress alone is not an equivalent-stress check.")
    n,vy,vz,t=Float64.([forces[k] for k in required[1:4]])
    polygon=((h-yc,-b/2),(h-yc,b/2),(hw-yc,b/2),(hw-yc,tw/2),
             (-yc,tw/2),(-yc,-tw/2),(hw-yc,-tw/2),(hw-yc,-b/2))
    normal=maximum(abs(n/area-forces["moment_$(ending)1"]*y/i1-forces["moment_$(ending)2"]*z/i2)
        for ending in ("a","b") for (y,z) in polygon)
    # Integrate Q from each free edge. Maxima of the web's quadratic flow
    # occur at an end or at y=yc. Flange bounds add the vertical-load linear
    # flow and horizontal-load quadratic flow, so their signs cannot cancel
    # an unexamined local maximum. The small web-width contribution is kept.
    web_q=max(abs(yc*hw-hw^2/2),abs(yc*clamp(yc,0.,hw)-clamp(yc,0.,hw)^2/2))
    web_shear=abs(vy)*web_q/i1+abs(vz)*tw^2/(8i2)
    flange_shear=abs(vy)*abs(yf-yc)*b/(2i1)+abs(vz)*b^2/(8i2)
    # For a symmetric thin T the shear centre lies on the web/flange
    # intersection. Native section torque is about the centroid. Bounding
    # both terms avoids a sign-convention-dependent underprediction.
    torque_bound=abs(t)+abs(vz)*abs(yf-yc)
    web_torsion=torque_bound*tw/j;flange_torsion=torque_bound*tf/j
    shear=max(web_shear+web_torsion,flange_shear+flange_torsion)
    equivalent=hypot(normal,sqrt(3.)*shear)
    all(isfinite,(normal,shear,equivalent))||return unavailable("T-section equivalent-stress envelope exceeds the finite numeric range.")
    description="Conservative thin-walled T-section equivalent-stress envelope: maximum total axial+bending normal stress at both ends and all polygon vertices, combined with bounded VQ/I transverse shear and free-warping Saint-Venant torsion. Maxima may occur at different points. Includes centroid/shear-centre eccentricity; excludes junction concentrations, restrained warping and transverse normal stresses."
    return Dict{String,Any}("von_mises"=>equivalent,"von_mises_recovery"=>Dict{String,Any}(
        "status"=>"complete","method"=>"thin_walled_t_section_envelope","description"=>description,
        "units"=>Dict("stress"=>"source stress units","moment"=>"source force-length units"),
        "normal_bound"=>normal,"transverse_shear_bound"=>max(web_shear,flange_shear),
        "torsional_shear_bound"=>max(web_torsion,flange_torsion),"combined_shear_bound"=>shear,
        "section_torque_bound"=>torque_bound,"flange_thickness_to_width"=>tf/b,
        "web_thickness_to_clear_height"=>tw/hw,"reason"=>""))
end
