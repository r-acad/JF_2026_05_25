# Shared by native recovery and Boxer result import. No stiffness or solver
# state is modified here. Units follow the input model (Pa for Boxer SI data).
# Classical VQ/(I b) shear, nominal limb flow and Saint-Venant torsion:
# https://www.ae.msstate.edu/tupas/SA2/chA14.7_text.html
# https://www.ae.msstate.edu/tupas/SA2/chA14.8_text.html
# https://www.ae.msstate.edu/tupas/SA2/chA6.6_text.html
# https://www.ae.msstate.edu/tupas/SA2/chA6.4_text.html

"""Saint-Venant torsion constant of a finite solid rectangle.

The odd Fourier series is the elasticity solution, not the thin-strip
approximation. Ninety-nine terms keep its square-section truncation error
below 2e-9 relative. The function is also usable with local AD scalars.
"""
function beam_rectangle_torsion_constant(width,height)
    a,b=max(width,height),min(width,height)
    series=sum(tanh(k*pi*a/(2b))/k^5 for k in 1:2:197)
    a*b^3/3*(1-192b/(pi^5*a)*series)
end

"""Nominal equivalent-stress envelope for a finite-thickness T beam.

Normal stress uses the actual finite-thickness polygon, centroid and inertias.
The VQ/(I b) envelope retains the finite flange's vertical shear and the
central web's transverse strip shear. Free-warping torsion uses compatible
rectangular limbs and their finite-rectangle torsion constants. For each
limb, tau_max <= G*twist*limb_thickness; using their summed rigidity bounds
the nominal limb shear without the t/b <= 0.10 thin-wall restriction.
This is a conservative combination WITHIN this stated nominal limb model,
not a rigorous pointwise bound for a 3D T junction. Sharp-junction stress
concentrations, restrained warping and transverse normal stress are excluded.
"""
function beam_t_stress_envelope(prop::AbstractDict, forces::AbstractDict;
        material_type="MAT1", varying_section=false, distributed_loading=false)
    uppercase(string(get(prop,"TYPE","")))=="BAR"&&return beam_rectangular_stress_envelope(prop,forces;material_type,varying_section,distributed_loading)
    unavailable(reason)=Dict{String,Any}("von_mises_recovery"=>Dict{String,Any}(
        "status"=>"unavailable","method"=>"finite_thickness_t_nominal_envelope","reason"=>reason))
    uppercase(string(material_type))=="MAT1"||return unavailable("The T-section equivalent-stress envelope requires an isotropic MAT1 material.")
    uppercase(string(get(prop,"TYPE","")))=="T"||return unavailable("Equivalent-stress recovery is not defined for this beam section; section envelopes support dimension-defined PBARL T and solid rectangular BAR sections.")
    varying_section&&return unavailable("The T-section equivalent-stress envelope requires a constant section; tapered/station-varying beams need interior recovery.")
    distributed_loading&&return unavailable("Distributed beam loading requires interior force/stress recovery before a complete equivalent-stress envelope can be reported.")
    numeric(v)=v isa Real&&!(v isa Bool)&&isfinite(v)
    dims=get(prop,"DIMS",nothing)
    dims isa AbstractVector&&length(dims)==4&&all(numeric,dims)||return unavailable("The four physical T-section dimensions are missing or nonfinite.")
    b,h,tf,tw=Float64.(dims);hw=h-tf
    b>tw>0&&h>tf>0||return unavailable("T-section dimensions must define a positive nonoverlapping flange and web.")
    area=b*tf+hw*tw;yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/area;yf=hw+tf/2
    i1=tw*hw^3/12+hw*tw*(yc-hw/2)^2+b*tf^3/12+b*tf*(yf-yc)^2
    i2=hw*tw^3/12+tf*b^3/12;j=(hw*tw^3+b*tf^3)/3
    if get(prop,"TORSION_FORMULATION","")=="saint_venant_2d"
        j=get(prop,"J",nothing)
        numeric(j)&&j>0||return unavailable("The finite-thickness section torsion constant must be positive and finite.")
    end
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
    # The two transverse components are bounded before combination. Retain
    # both the flange-parallel shear flow and its finite vertical component;
    # the latter is often discarded in a thin-wall calculation.
    web_q=max(abs(yc*hw-hw^2/2),abs(yc*clamp(yc,0.,hw)-clamp(yc,0.,hw)^2/2))
    web_horizontal_q=(tf*(b^2-tw^2)+h*tw^2)/(8h)
    flange_y=clamp(yc,hw,h)
    flange_vertical_q=max(abs((h-yc)^2-(hw-yc)^2),abs((h-yc)^2-(flange_y-yc)^2))/2
    web_shear=abs(vy)*web_q/i1+abs(vz)*web_horizontal_q/i2
    flange_shear=abs(vy)*(abs(yf-yc)*b/2+flange_vertical_q)/i1+abs(vz)*b^2/(8i2)
    # The nominal symmetric-limb shear centre is at the flange midline.
    # Bound the section torque and the transfer couple before adding shear.
    torque_bound=abs(t)+abs(vz)*abs(yf-yc)
    nominal_j=beam_rectangle_torsion_constant(b,tf)+beam_rectangle_torsion_constant(tw,hw)
    nominal_j>0&&isfinite(nominal_j)||return unavailable("The finite rectangular-limb torsion model is unresolved.")
    web_torsion=torque_bound*tw/nominal_j;flange_torsion=torque_bound*tf/nominal_j
    shear=max(web_shear+web_torsion,flange_shear+flange_torsion)
    equivalent=hypot(normal,sqrt(3.)*shear)
    all(isfinite,(normal,shear,equivalent))||return unavailable("T-section equivalent-stress envelope exceeds the finite numeric range.")
    description="Finite-thickness nominal T-section engineering envelope: exact polygon axial+bending normal stress at both ends; finite-section VQ/(I b) shear components; compatible rectangular-limb Saint-Venant torsion with finite-rectangle rigidities. Maxima may occur at different points and their combination is conservative within this nominal beam model. Includes the nominal centroid/shear-centre transfer couple. Excludes T-junction concentrations, restrained warping and transverse normal stresses; it is not a pointwise 3D junction-stress prediction."
    return Dict{String,Any}("von_mises"=>equivalent,"von_mises_recovery"=>Dict{String,Any}(
        "status"=>"complete","method"=>"finite_thickness_t_nominal_envelope","description"=>description,
        "units"=>Dict("stress"=>"source stress units","moment"=>"source force-length units"),
        "normal_bound"=>normal,"transverse_shear_bound"=>max(web_shear,flange_shear),
        "torsional_shear_bound"=>max(web_torsion,flange_torsion),"combined_shear_bound"=>shear,
        "section_torque_bound"=>torque_bound,"flange_thickness_to_width"=>tf/b,
        "nominal_torsion_constant"=>nominal_j,"nominal_section_model"=>"finite rectangular limbs; sharp junction and restrained warping excluded",
        "web_thickness_to_clear_height"=>tw/hw,"reason"=>""))
end

"""Conservative isotropic solid-rectangle equivalent-stress envelope.

The rectangular Saint-Venant coefficient in tau_max=T/(c*a*b^2), a>=b,
ranges from approximately 0.208 for a square to 1/3 for a thin rectangle.
Use c=0.20 as a conservative bound, not the circular T*r/J formula.
Reference: Mississippi State Structural Analysis II, Section A6.4, Table A6.1:
https://www.ae.msstate.edu/tupas/SA2/chA6.4_text.html
The normal, transverse-shear and torsion maxima need not coincide; combining
their bounds deliberately overestimates the pointwise von Mises maximum.
"""
function beam_rectangular_stress_envelope(prop::AbstractDict,forces::AbstractDict;
        material_type="MAT1",varying_section=false,distributed_loading=false)
    unavailable(reason)=Dict{String,Any}("von_mises_recovery"=>Dict{String,Any}(
        "status"=>"unavailable","method"=>"solid_rectangular_section_envelope","reason"=>reason))
    numeric(x)=x isa Real&&!(x isa Bool)&&isfinite(x)
    uppercase(string(material_type))=="MAT1"||return unavailable("Rectangular beam equivalent stress requires an isotropic MAT1 material.")
    varying_section&&return unavailable("A varying rectangular section requires interior stress recovery.")
    distributed_loading&&return unavailable("Distributed beam loading requires interior force/stress recovery.")
    dims=get(prop,"DIMS",nothing)
    dims isa AbstractVector&&length(dims)==2&&all(numeric,dims)&&all(>(0),dims)||return unavailable("Two positive physical rectangular-section dimensions are required.")
    b,h=Float64.(dims);area=b*h;i1=b*h^3/12;i2=h*b^3/12
    for (key,expected) in (("A",area),("I1",i1),("I2",i2))
        value=get(prop,key,nothing)
        numeric(value)&&isapprox(value,expected;rtol=1e-8,atol=0.)||return unavailable("Rectangular beam $key differs from its physical dimensions.")
    end
    i12=get(prop,"I12",0.)
    numeric(i12)&&abs(i12)<=1e-12*sqrt(i1*i2)||return unavailable("The rectangle requires centroidal principal section axes.")
    required=("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2")
    all(k->numeric(get(forces,k,nothing)),required)||return unavailable("Complete beam resultants and both end moments are required; axial stress alone is not an equivalent-stress check.")
    axial=forces["axial"]/area
    normal=maximum(abs(axial-forces["moment_$(ending)1"]*y/i1-forces["moment_$(ending)2"]*z/i2)
        for ending in ("a","b") for y in (-h/2,h/2) for z in (-b/2,b/2))
    transverse=1.5*(abs(forces["shear_1"])+abs(forces["shear_2"]))/area
    torsion=5abs(forces["torque"])/(max(b,h)*min(b,h)^2)
    shear=transverse+torsion;equivalent=hypot(normal,sqrt(3.)*shear)
    all(isfinite,(normal,shear,equivalent))||return unavailable("Rectangular stress envelope exceeds the finite numeric range.")
    return Dict{String,Any}("von_mises"=>equivalent,"von_mises_recovery"=>Dict{String,Any}(
        "status"=>"complete","method"=>"solid_rectangular_section_envelope","reason"=>"",
        "description"=>"Conservative solid-rectangle envelope: both-end axial+bending corner bound, 1.5(|Vy|+|Vz|)/A transverse shear and Saint-Venant torsion with conservative coefficient 0.20. Elastic constant-section beam model; excludes local concentrations and restrained warping.",
        "normal_bound"=>normal,"transverse_shear_bound"=>transverse,"torsional_shear_bound"=>torsion,
        "combined_shear_bound"=>shear,"section_torque_bound"=>abs(forces["torque"]),
        "torsion_stress_coefficient"=>.20,"units"=>Dict("stress"=>"source stress units","moment"=>"source force-length units")))
end
