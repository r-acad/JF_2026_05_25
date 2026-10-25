# Physical, massless interpolation grids for aerodynamic span beyond the box.
# These RBE3s introduce no artificial elastic extension of the structural box.

function add_unboxed_aero_references!(reg,g,p,spiders,eid)
    isempty(spiders) && return eid
    terminal=last(spiders)
    start=max(last(g.etas),terminal.eta)
    start>=1-1e-10 && return eid
    intervals=max(1,round(Int,reference_length(g.wing)/p["box.rib_pitch"]))*p["mesh.elements_between_ribs"]
    stations=sort!(unique(vcat([j/intervals for j in 1:intervals if j/intervals>start+1e-10],1.0)))
    for eta in stations
        point=section_point(g.wing,eta,Float64(p["rbe3.ref_xc"]),0.)
        ref=add_free_node!(reg,point)
        # Negative station marks a virtual span reference, not another rib.
        push!(spiders,RBE3Spider(eid,ref,copy(terminal.dep),-1,eta));eid+=1
    end
    return eid
end

"""Bind unboxed loft rows to the same solved RBE3 grids that carry their loads."""
function bind_unboxed_aero_points!(mapping,weights,xyz,g,spiders,aero_etas,nloop)
    first_virtual=findfirst(sp->sp.station<0,spiders)
    first_virtual===nothing && return nothing
    references=spiders[max(1,first_virtual-1):end]
    etas=[sp.eta for sp in references]
    stride=length(mapping)÷(length(xyz)÷3)
    for (j,eta) in enumerate(aero_etas)
        eta>last(g.etas)+1e-10 || continue
        lo=clamp(searchsortedlast(etas,eta),1,length(etas)-1);hi=lo+1
        t=clamp((eta-etas[lo])/(etas[hi]-etas[lo]),0.,1.)
        for chord in 1:nloop
            point=(j-1)*nloop+chord;offset=stride*(point-1)
            for k in 1:stride
                mapping[offset+k]=references[lo].ref;weights[offset+k]=0.
            end
            mapping[offset+2]=references[hi].ref
            weights[offset+1]=1-t;weights[offset+2]=t
        end
    end
    return nothing
end

"""Work-conjugate deformation of arbitrary aerodynamic points from FE results.

Translations/rotations are BASIC, three rows per GRID. This is the kinematic
dual of the force-plus-moment transfer, not a new aerodynamic equilibrium solve.
It can be applied to VLM vertices/control points as well as the display loft.
"""
function aerodynamic_point_displacements(m,points,translations,rotations)
    length(translations)==length(m.xyz)==length(rotations) ||
        throw(ArgumentError("Aerodynamic interpolation requires BASIC translations and rotations for every FE GRID"))
    isempty(m.rbe3) && throw(ArgumentError("Aerodynamic interpolation requires RBE3 reference grids"))
    routing=aerodynamic_routing(m)
    return [begin
        eta=(point[2]-m.wing.root_ref_y)/m.wing.semispan
        displacement=(0.,0.,0.)
        for (j,weight) in aerodynamic_target_weights(routing,point;eta)
            ref=routing.refs[j].ref
            origin=Tuple(m.xyz[3ref-2:3ref]);u=Tuple(translations[3ref-2:3ref]);rotation=Tuple(rotations[3ref-2:3ref])
            displacement=displacement.+weight.*(u.+cross3(rotation,Tuple(point).-origin))
        end
        displacement
    end for point in points]
end
