using Test, WingFEGen, LinearAlgebra
const W=WingFEGen

function span_chord_parameters(;leading=false,oblique=false,deflected=false)
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>8.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>.4,
        "planform.sweep"=>14.,"planform.dihedral"=>4.,"planform.twist_tip"=>-4.,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","airfoil.n_points"=>31,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.25,
        "mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"loads.structure_inertia"=>false,"loads.lift_total"=>1.))
    p["movable_surfaces.items"]=[Dict("name"=>"Narrow control","kind"=>oblique ? "aileron" : "flap",
        "edge"=>leading ? "leading" : "trailing","eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>leading ? .15 : .77,"hinge_end"=>leading ? .15 : .79,
        "front_spar_start"=>leading ? .1 : .90,"front_spar_end"=>leading ? .06 : .95,
        "hinge_z_start"=>0.,"hinge_z_end"=>0.,"deflection"=>45.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,
        Dict("surface"=>"Narrow control","span_bays"=>2,"span_elements"=>1,
            "chord_elements"=>3,"height_elements"=>2,"mesh_deflected"=>deflected))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,
        Dict("surface"=>"Narrow control","eta"=>eta,"spar"=>leading ? "front" : "rear",
            "fitting"=>oblique ? "shell_lugs" : "idealized","actuator"=>true)) for eta in (.26,.74)]
    first(W.normalize_params(p))
end

@testset "Movable span edges do not exceed their shortest control chord" begin
    for (leading,oblique,deflected) in ((false,false,false),(false,false,true),(true,false,false),(false,true,false))
        p=span_chord_parameters(;leading,oblique,deflected);m=W.build_model(p)
        surface=only(m.movable_structure["surfaces"]);s=only(m.params["movable_surfaces.items"])
        row=only(m.params["movable_structure.surfaces"]);edge=leading ? 0. : 1.
        original=W.movable_span_stations(m.wing,row,surface["rib_etas"])
        @test length(surface["eta_stations"])>length(original)
        @test all(in(Set(surface["eta_stations"])),original)
        @test length(surface["rib_sections"])==length(surface["rib_etas"])
        @test surface["maximum_span_edge_chord_ratio"]<=1+1e-10
        @test W.all_checks_pass(m)
        checked=0;node_etas=m.movable_structure["node_etas"]
        for group in m.groups
            family=group.pid÷1_000_000;family in (31,32)||continue
            @test group.kind===:quad
            pairs=family==31 ? ((2,3),(4,1)) : ((1,2),(3,4))
            for cell in eachcol(reshape(group.conn,4,:)),(a,b) in pairs
                n1,n2=cell[a],cell[b];e1,e2=node_etas[n1],node_etas[n2]
                lo,hi=minmax(e1,e2)
                probes=vcat(lo,filter(e->lo<e<hi,W.planform_breakpoints(m.wing)),hi)
                width=minimum(abs(edge-W.movable_chord_coordinate(s,"front_spar",eta))*W.chord(m.wing,eta) for eta in probes)
                distance=norm(m.xyz[3n1-2:3n1]-m.xyz[3n2-2:3n2])
                @test distance<=width*(1+1e-10)
                checked+=1
            end
        end
        @test checked>0
    end
end
