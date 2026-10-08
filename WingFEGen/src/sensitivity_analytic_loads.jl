# Exact property tangents of the generated dead body loads and native shell mass.
# Directions are SI derivatives with respect to one displayed design variable.
using LinearAlgebra
using SparseArrays

function sensitivity_pid_direction(directions,pid)
    get(directions,Int(pid),get(directions,string(pid),nothing))
end
sensitivity_direction_value(direction,key,default=0.) =
    direction isa NamedTuple ? get(direction,Symbol(key),default) : get(direction,key,get(direction,Symbol(key),default))

"""Global BASIC dF, ordered like m.node_ids, after the fixed bay-reference transfer.

Shell directions contain `areal_mass`. Bar directions contain `area`, `density`,
and `offset_y`. Current design variables affect structural properties only:
fuel fill/density, aerodynamic loads, geometry and RBE3 interpolation stay fixed.
"""
function sensitivity_analytic_load_tangent(m::Model,directions;params=m.params)
    acceleration=structure_acceleration(params)
    force=zeros(6length(m.node_ids));nodal_mass=zeros(m.n_struct);offset_mass=zeros(3,m.n_struct)
    if all(iszero,acceleration)
        return (;force,node_ids=copy(m.node_ids),diagnostics=Dict("method"=>"analytic_structural_body_loads","affected_elements"=>0))
    end
    affected=0
    for gr in m.groups
        direction=sensitivity_pid_direction(directions,gr.pid);direction===nothing&&continue
        if gr.kind===:bar
            da=Float64(sensitivity_direction_value(direction,"area"));drho=Float64(sensitivity_direction_value(direction,"density"));doffset=Float64(sensitivity_direction_value(direction,"offset_y"))
            all(iszero,(da,drho,doffset))&&continue
            section=section_definition(m.params,gr.pid);area=Float64(section["area_m2"])
            rho=Float64(bar_material_definition(m.params,gr.pid)["rho"])
            for e in 1:n_elements(gr)
                nodes=gr.conn[2*e-1:2*e];points=element_points(m,gr,e);length_e=norm3(points[2].-points[1])
                x=unit3(points[2].-points[1]);v=ntuple(k->gr.orient[3*e-3+k],3)
                y=unit3(v.-sum(x.*v).*x);offset=bar_section_offset(m,gr,e);delta_offset=doffset.*y
                mass=length_e*area*rho;delta_mass=length_e*(rho*da+area*drho)
                for node in nodes
                    nodal_mass[node]+=.5delta_mass
                    for k in 1:3;offset_mass[k,node]+=.5*(delta_mass*offset[k]+mass*delta_offset[k]);end
                end
                affected+=1
            end
        else
            areal=Float64(sensitivity_direction_value(direction,"areal_mass"));iszero(areal)&&continue
            n=gr.kind===:quad ? 4 : gr.kind===:tria ? 3 : error("Unsupported structural-load tangent element kind $(gr.kind)")
            for e in 1:n_elements(gr)
                nodes=gr.conn[n*(e-1)+1:n*e];points=element_points(m,gr,e)
                normal=unit3(n==4 ? cross3(points[3].-points[1],points[4].-points[2]) : cross3(points[2].-points[1],points[3].-points[1]))
                # The native body-load path uses bilinear Q4 shape integrals,
                # not modal lumped-mass corner weights or a triangle diagonal.
                weights=n==4 ? quad_body_shape_weights(points,normal) : fill(abs(sum(cross3(points[2].-points[1],points[3].-points[1]).*normal))/6,3)
                for (node,weight) in zip(nodes,weights);nodal_mass[node]+=weight*areal;end
                affected+=1
            end
        end
    end
    source=[(position=Tuple(m.xyz[3node-2:3node]),force=nodal_mass[node].*acceleration,
        moment=cross3(ntuple(k->offset_mass[k,node],3),acceleration)) for node in 1:m.n_struct
        if !iszero(nodal_mass[node])||any(!iszero,view(offset_mass,:,node))]
    targets=[Tuple(m.xyz[3sp.ref-2:3sp.ref]) for sp in m.fuel_rbe3]
    routed=transfer_load_wrenches(targets,source;target_label="Structural inertia derivative")
    for (i,sp) in enumerate(m.fuel_rbe3)
        force[6(sp.ref-1).+(1:3)].=routed.force[i]
        force[6(sp.ref-1).+(4:6)].=routed.moment[i]
    end
    diagnostics=routing_source_diagnostics(source,targets,routed)
    diagnostics["method"]="analytic_structural_body_loads";diagnostics["affected_elements"]=affected
    all(isfinite,force)||error("Structural body-load derivative contains nonfinite entries")
    return (;force,node_ids=copy(m.node_ids),diagnostics)
end

"""Apply fixed GRID output rotations and the native MPC transpose to a load tangent."""
function sensitivity_analytic_reduce_load(native,op,tangent)
    values=zeros(op.ndof)
    for (row,gid) in enumerate(tangent.node_ids)
        haskey(op.id_map,gid)||error("Load derivative GRID $gid is absent from the native model")
        i=op.id_map[gid]
        for components in (1:3,4:6)
            values[6(i-1).+components].=op.node_R[i]'*tangent.force[6(row-1).+components]
        end
    end
    native.Solver._adjoint_reduce_rhs(values,op.rbe3_map)
end

"""Physical (pre-MPC) native shell dM for fixed element frames and connectivity.

Each PID direction supplies `mass_moments=(dm0,dm1,dm2)` about the actual shell
reference plane. The root property mapper differentiates layer boundaries,
densities and total-thickness overrides. `areal_mass` is accepted for lumped
mass. Signed tangents bypass the positive physical-density skip in the kernels.
"""
function sensitivity_analytic_shell_mass(native,op,directions)
    S=native.Solver;F=S.FEM;model=op.model
    consistent=S.sol103_shell_mass_formulation(model)===:coupled_consistent
    I=Int[];J=Int[];V=Float64[]
    for el in values(model["CSHELLs"])
        direction=sensitivity_pid_direction(directions,el["PID"]);direction===nothing&&continue
        moments=sensitivity_direction_value(direction,"mass_moments",nothing)
        if moments===nothing
            consistent&&error("Consistent shell mass requires exact zeroth, first and second mass-moment tangents")
            moments=(sensitivity_direction_value(direction,"areal_mass"),0.,0.)
        end
        dm=Tuple(Float64.(moments));length(dm)==3&&all(isfinite,dm)||error("Invalid shell mass-moment derivative")
        all(iszero,dm)&&continue
        ids=el["NODES"];n=length(ids);n in (3,4)||error("Analytic shell mass supports CTRIA3/CQUAD4 only")
        indices=[op.id_map[id] for id in ids];points=[S.SVector{3,Float64}(op.X[i,:]) for i in indices]
        v1,v2,v3=n==4 ? S.shell_element_frame_quad4(points...,:bisect) : S.shell_element_frame_fast(points[1],points[2],points[3],points[3],3)
        rotation=transpose(hcat(v1,v2,v3));center=sum(points)/n
        coords=[dot(point-center,axis) for point in points,axis in (v1,v2)]
        local_mass=if consistent
            n==4 ? F.consistent_mass_quad4(coords,1.,1.;mass_moments=dm) : F.consistent_mass_tria3(coords,1.,1.;mass_moments=dm)
        else
            dm[1].*(n==4 ? F.nastran_lumped_mass_quad4(coords,1.,1.) : F.nastran_lumped_mass_tria3(coords,1.,1.))
        end
        transform=zeros(6n,6n);dofs=Int[]
        for (k,i) in enumerate(indices)
            block=rotation*op.node_R[i]
            for components in (1:3,4:6);transform[6(k-1).+components,6(k-1).+components].=block;end
            append!(dofs,6(i-1).+(1:6))
        end
        delta=transform'*local_mass*transform
        for j in eachindex(dofs),i in eachindex(dofs)
            iszero(delta[i,j])&&continue
            push!(I,dofs[i]);push!(J,dofs[j]);push!(V,delta[i,j])
        end
    end
    sparse(I,J,V,op.ndof,op.ndof)
end
