"""Add a physical, axial actuator between existing upper spar-cap nodes.

Stiffness is force per relative axial displacement, in N/m. Hinge torsional
stiffness from earlier Studies is a separate quantity and is never reused here.
The generated record uses one-based mesh indices; viewport payloads convert them.
"""
function add_movable_actuator!(reg,record,main_upper,control_upper,index,eid)
    get(record,"actuator",false)&&record["kind"]=="hinge"||return eid
    stiffness=get(record,"actuator_stiffness",1e7)
    stiffness>0||return eid
    pa=reg.xyz[3main_upper-2:3main_upper];pb=reg.xyz[3control_upper-2:3control_upper]
    delta=pb.-pa;length_m=sqrt(sum(abs2,delta))
    scale=max(sqrt(sum(abs2,pa)),sqrt(sum(abs2,pb)),1.)
    length_m>1e-12*scale||throw(ArgumentError("$(record["surface"]): the axial actuator's two upper spar-cap nodes coincide. Separate the main rear spar and movable front spar, or disable this actuator."))
    axis=delta./length_m
    arm=sum(axis.*cross3(Tuple(record["axis"]),Tuple(pb.-record["origin"])))
    merge!(record,Dict{String,Any}("actuator_eid"=>eid,"actuator_pid"=>38_000_000+index,
        "actuator_cid"=>81_000_000+index,"actuator_nodes"=>[main_upper,control_upper],
        "actuator_axis"=>axis,"actuator_origin"=>collect(pa),"actuator_length_m"=>length_m,
        "actuator_hinge_arm_m"=>arm,"actuator_effective_hinge_stiffness_Nm"=>stiffness*arm^2,
        "K1_N_per_m"=>Float64(stiffness)))
    eid+1
end

function movable_actuator_frame(record)
    x=Tuple(record["actuator_axis"])
    y=unit3(cross3(abs(x[3])<.9 ? (0.,0.,1.) : (1.,0.,0.),x));z=cross3(x,y)
    (;origin=Tuple(record["actuator_origin"]),x,y,z)
end

function write_movable_actuator(io,m,record)
    haskey(record,"actuator_eid")||return nothing
    f=movable_actuator_frame(record);cid=record["actuator_cid"];pid=record["actuator_pid"]
    comment!(io,"Axial actuator: upper main rear spar to upper movable front spar; K1 in N/m")
    card!(io,"CORD2R",(cid,0,f.origin...,(f.origin.+f.z)...,(f.origin.+f.x)...))
    card!(io,"PBUSH",(pid,"K",record["K1_N_per_m"],0.,0.,0.,0.,0.))
    nodes=record["actuator_nodes"]
    card!(io,"CBUSH",(record["actuator_eid"],pid,m.node_ids[nodes[1]],m.node_ids[nodes[2]],nothing,nothing,nothing,cid))
    nothing
end

function movable_actuator_coordinates(record)
    f=movable_actuator_frame(record)
    coordinate_usage!(Dict{String,Any}("id"=>record["actuator_cid"],"type"=>"RECTANGULAR","card"=>"CORD2R",
        "origin"=>collect(f.origin),"x"=>collect(f.x),"y"=>collect(f.y),"z"=>collect(f.z),
        "properties"=>Dict{String,Any}("Role"=>"Axial actuator axes; x from main rear upper spar cap to movable front upper spar cap",
            "Surface"=>record["surface"],"CBUSH"=>record["actuator_eid"],"Reference ID"=>0,"Reference type"=>"RECTANGULAR")),coordinate_usage_record())
end

"""A dead-center axial actuator does not restrain first-order hinge rotation.

Allow its geometry/deck/modal analysis, but diagnose the actual generated arm
before static, preload or nonlinear equilibrium. Ordinary parameter validation
handles missing/disabled attachments separately.
"""
function validate_movable_actuator_paths(m;solution=String(get(m.params,"output.solution","101")))
    String(solution) in ("101","105","106")||return nothing
    data=movable_structure_data(m);attachments=get(data,"attachments",Any[])
    for surface in get(data,"surfaces",Any[])
        aa=filter(a->a["surface"]==surface["name"],attachments)
        isempty(aa)&&continue
        any(a->a["kind"]=="rigid"||(a["fitting"]=="idealized"&&a["hinge_stiffness"]>0),aa)&&continue
        active=filter(a->haskey(a,"actuator_eid"),aa)
        isempty(active)&&continue # Parameter preflight explains the free hinge.
        any(a->abs(a["actuator_hinge_arm_m"])>1e-10*max(a["actuator_length_m"],1e-12),active)&&continue
        throw(ArgumentError("$(surface["name"]): the axial actuator lines pass through the hinge axis and have no first-order lever arm. Change hinge z/t or the spar positions, or provide a rigid attachment. Static equilibrium remains unrestrained even with a positive axial stiffness; geometry and SOL103 remain available."))
    end
    nothing
end
