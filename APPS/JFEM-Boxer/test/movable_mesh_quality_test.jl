using Test, LinearAlgebra, WingFEGen
const W = WingFEGen

"""Generated fixture: a separate trailing control with physical attachment ribs."""
function quality_parameters(; kind="flap", secondary=.500001, refinement=7,
    hinge_z=0., hinge_x=.77, deflected=false, sweep=12.)
    p = merge(W.default_params(), Dict{String,Any}(
        "planform.area"=>2., "planform.aspect_ratio"=>2., "planform.taper_ratio"=>.8,
        "airfoil.root"=>"NACA2412", "airfoil.tip"=>"NACA2412", "planform.sweep"=>sweep,
        "planform.dihedral"=>2., "planform.twist_tip"=>-3., "box.end_eta"=>1.,
        "box.rib_pitch"=>.25, "box.stringer_pitch"=>.2, "mesh.elements_between_ribs"=>refinement,
        "mesh.elements_spar_height"=>2, "mesh.aero_chord_points"=>9, "airfoil.n_points"=>31,
        "loads.method"=>"analytic", "loads.lift_total"=>1., "loads.structure_inertia"=>false,
        "fuel.enabled"=>false, "loads.cases"=>Any[]))
    p["movable_surfaces.items"] = [Dict("name"=>"Control", "kind"=>kind, "edge"=>"trailing",
        "eta_start"=>.05, "eta_end"=>.95, "hinge_start"=>hinge_x, "hinge_end"=>hinge_x+.02,
        "front_spar_start"=>.78, "front_spar_end"=>.80, "hinge_z_start"=>hinge_z,
        "hinge_z_end"=>hinge_z, "deflection"=>15., "color"=>"#29b6d1")]
    p["movable_structure.surfaces"] = [merge(W.MOVABLE_STRUCTURE_DEFAULTS,
        Dict("surface"=>"Control", "span_bays"=>4, "span_elements"=>2, "chord_elements"=>4,
            "height_elements"=>2, "secondary_spar"=>secondary, "mesh_deflected"=>deflected))]
    p["movable_structure.attachments"] = [merge(W.MOVABLE_ATTACHMENT_DEFAULTS,
        Dict("surface"=>"Control", "eta"=>eta, "fitting"=>"shell_lugs",
             "actuator"=>true)) for eta in (.26,.74)]
    first(W.normalize_params(p))
end

"""Measure actual 3D skin edges/corners; parameter spacing alone misses distortion."""
function skin_quality(m)
    aspects=Float64[]; angles=Float64[]; jacobians=Float64[]
    for g in m.groups
        g.pid÷1_000_000 in (31,32) || continue
        n = g.kind===:quad ? 4 : 3
        for j in eachindex(g.eids)
            ns=g.conn[(j-1)*n+1:j*n]; p=[m.xyz[3v-2:3v] for v in ns]
            lengths=[norm(p[i%n+1]-p[i]) for i in 1:n]
            push!(aspects, maximum(lengths)/minimum(lengths))
            normal=sum(cross(p[i],p[i%n+1]) for i in 1:n); normal/=norm(normal)
            for i in 1:n
                a=p[i]-p[mod1(i-1,n)]; b=p[i%n+1]-p[i]
                push!(angles, acosd(clamp(dot(-a,b)/(norm(a)*norm(b)),-1.,1.)))
                push!(jacobians,dot(cross(a,b),normal)/(norm(a)*norm(b)))
            end
        end
    end
    (; max_aspect=maximum(aspects), min_angle=minimum(angles),
       min_jacobian=minimum(jacobians), elements=length(aspects))
end

function skin_coordinates(m)
    [m.xyz[3n-2:3n] for g in m.groups if g.pid÷1_000_000 in (31,32) for n in g.conn]
end

@testset "Movable skin grid keeps meaningful spacing and conforming attachment ribs" begin
    for kind in ("flap","aileron"), deflected in (false,true)
        p=quality_parameters(;kind,deflected)
        m=W.build_model(p); q=skin_quality(m)
        @test W.all_checks_pass(m)
        @test q.max_aspect < 20
        @test q.min_angle > 25
        @test q.min_jacobian > .4
        # Refining the main wing must not introduce unrelated thin strips into
        # the independently specified control mesh.
        coarse=deepcopy(p);coarse["mesh.elements_between_ribs"]=1
        other=W.build_model(coarse)
        @test all(a≈b for (a,b) in zip(skin_coordinates(other),skin_coordinates(m)))
        @test skin_quality(other).elements==q.elements
        surface=only(m.movable_structure["surfaces"])
        for joint in m.movable_structure["attachments"]
            rib=surface["rib_sections"][joint["master_rib_index"]]
            @test rib["front_upper"]==joint["actuator_nodes"][2]
            @test all(abs(dot(m.xyz[3n-2:3n]-joint["origin"],joint["lug_plane_normal"]))<1e-9
                for n in rib["perimeter_nodes"])
            # Attached rib skin nodes are actual skin connectivity, not a
            # disconnected locally remeshed patch or interpolation duplicate.
            skin_nodes=Set(n for g in m.groups if g.pid÷1_000_000 in (31,32) for n in g.conn)
            @test all(in(skin_nodes),vcat(rib["upper_nodes"],rib["lower_nodes"]))
        end
    end
end

@testset "Physical geometry stations do not silently create slivers" begin
    p=quality_parameters(;secondary=.5)
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),
        Dict("eta"=>.500001,"twist"=>-1.),Dict("eta"=>1.,"twist"=>-3.)]
    # Keep both exact stations. A valid thin strip is reported as poor quality;
    # it must never be silently merged, or confused with an invalid/folded cell.
    m=W.build_model(p);surface=only(m.movable_structure["surfaces"])
    @test .5 in surface["eta_stations"]
    @test .500001 in surface["eta_stations"]
    @test surface["maximum_span_edge_chord_ratio"]<=1+1e-10
    issues=filter(i->get(i,"rib_reference","")=="movable",m.mesh_quality["issues"])
    @test any(i->i["severity"]=="warning"&&i["maximum_edge_ratio"]>1000,issues)
end

@testset "Fitting selection follows the airfoil lower contour and reaches both spars" begin
    for z in (0.,-.499,-.5,-.501,-2.), aft in (false,true)
        p=quality_parameters(;secondary=.5,hinge_z=z,hinge_x=aft ? .83 : .77)
        # Rectangular, symmetric, untwisted foil makes the exact z/t=-0.5
        # boundary unambiguous; the general curved/oblique case is above.
        merge!(p,Dict("airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
            "planform.taper_ratio"=>1.,"planform.twist_tip"=>0.,"planform.dihedral"=>0.,"planform.sweep"=>0.))
        s=only(p["movable_surfaces.items"]);s["hinge_end"]=s["hinge_start"];s["front_spar_end"]=s["front_spar_start"]
        m=W.build_model(p);surface=only(m.movable_structure["surfaces"])
        for joint in m.movable_structure["attachments"]
            @test joint["underside_lug"]==(z<-.5)
            rib=surface["rib_sections"][joint["master_rib_index"]]
            @test rib["front_lower"] in joint["surface_nodes"]
            if z>=-.5
                @test rib["front_upper"] in joint["surface_nodes"]
                @test joint["control_lug_attachment"]=="front spar"
            else
                @test all(in(Set(rib["lower_nodes"])),joint["surface_nodes"])
                lugs=only(filter(g->g.pid==joint["lug_pid"],m.groups))
                @test rib["front_lower"] in lugs.conn
                @test rib["secondary_lower"] in joint["surface_nodes"]
                @test rib["secondary_lower"] in lugs.conn
                # The skin-to-fitting boundary is a continuous chain of the
                # actual rib edges, through the subspar; no nearest-cell stub.
                through=findfirst(==(rib["secondary_lower"]),rib["lower_nodes"])
                edges=Set(Tuple(sort([a,b])) for tri in eachcol(reshape(lugs.conn,3,:)) for (a,b) in zip(tri,circshift(tri,-1)))
                @test all(Tuple(sort(rib["lower_nodes"][i:i+1])) in edges for i in 1:through-1)
            end
        end
    end
end
