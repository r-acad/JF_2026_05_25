# De Marco & Coiro, Quaderno 1 (2017.a), sections 1.8-1.12.
# Geometry/FE vectors use construction C: X aft, Y right, Z up.
# B, A, S and Wind W' are forward/right/down frames.
# All rotations act on DIMENSIONAL vectors before coefficient normalization.
const AERODYNAMIC_FRAME_NAMES=Dict("body"=>"Body B", "aerodynamic"=>"Aerodynamic A",
    "wind"=>"Wind W'", "stability"=>"Stability S (fixed alpha0)")
function aerodynamic_frame_matrices(s)
    a=deg2rad(s["alpha"]);b=deg2rad(s["beta"]);a0=deg2rad(s["stability_alpha"])
    pitch(t)=[cos(t) 0. sin(t);0. 1. 0.;-sin(t) 0. cos(t)]
    # Wind W-prime: X along aircraft air-relative velocity; Z in the
    # symmetry plane. This is NOT the book's gravity/trajectory wind W.
    yaw=[cos(b) -sin(b) 0.;sin(b) cos(b) 0.;0. 0. 1.]
    Q=diagm([-1.,1.,-1.])
    Dict("body"=>Q,"aerodynamic"=>Q*pitch(a),"wind"=>Q*yaw*pitch(a),"stability"=>Q*pitch(a0))
end
function aerodynamic_frame_geometry(s)
    rotations=aerodynamic_frame_matrices(s)
    frames=Dict{String,Any}(name=>Dict("label"=>AERODYNAMIC_FRAME_NAMES[name],
        "axes_in_construction"=>[collect(T[i,:]) for i in 1:3]) for (name,T) in rotations)
    frames["construction"]=Dict("label"=>"Construction C","axes_in_construction"=>[[1.,0.,0.],[0.,1.,0.],[0.,0.,1.]])
    frames
end
function aerodynamic_coefficients(force,moment,s,qS,span,mac)
    lengths=[span,mac,span]
    Dict{String,Any}(name=>begin
        F=T*collect(force);M=T*collect(moment);components=F./qS
        # Preserve conventional positive drag/lift reporting in W-prime.
        # force_components always contains the actual signed vector components.
        shown=name=="wind" ? [-components[1],components[2],-components[3]] : components
        Dict("force"=>shown,"force_components"=>components,"moment"=>M./qS./lengths,
            "force_N"=>F,"moment_Nm"=>M,"frame"=>AERODYNAMIC_FRAME_NAMES[name],
            "force_labels"=>(name=="wind" ? ["CDi near","CY","CL"] : ["CX","CY","CZ"]))
    end for (name,T) in aerodynamic_frame_matrices(s))
end

# Quaderno 1, Fig. 1.26 and pp. 28-29: elevator/aileron trailing edge down;
# rudder trailing edge toward the pilot's left (negative construction Y).
# Meshing constructs the right half before Y reflection, so rudder commands
# require opposite hinge-angle signs on the two physical fins.
function aerodynamic_command_angle(w,row,side,angle)
    row["kind"]=="rudder"||return angle
    iszero(angle)&&return angle
    h0,h1=movable_hinge_endpoints(w,row);axis=h1.-h0
    abs(axis[3])>1e-8*norm3(axis)||throw(ArgumentError("A rudder command requires a hinge with a vertical component; use Other for a nonconventional surface"))
    angle*(side=="right" ? -sign(axis[3]) : sign(axis[3]))
end
