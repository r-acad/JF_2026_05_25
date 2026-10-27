# From the repository root:
# julia --project=. APPS/JFEM-Boxer/test/kink_bay_mass_test.jl PRIVATE_OUTPUT
using Test, LinearAlgebra, WingFEGen, OpenJFEM
const KB = WingFEGen
length(ARGS)==1||error("Usage: kink_bay_mass_test.jl PRIVATE_OUTPUT")
const KINK_OUT=abspath(only(ARGS));mkpath(KINK_OUT)

function kink_mass_params(;shell=false,angled=false)
    p=merge(KB.default_params(),Dict{String,Any}(
        "planform.area"=>4.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>.85,
        "planform.sweep"=>12.,"planform.dihedral"=>2.,"planform.twist_tip"=>-2.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.12,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>3,"leading_edge.enabled"=>true,
        "leading_edge.chord_elements"=>5,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>100.,"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"loads.cases"=>Any[],"mass.structural_representation"=>"bay_concentrated"))
    # Both kinks lie after an interior physical rib and before its next
    # optional FE row. Their first split segments retain that rib's row key.
    p["box.front_spar_points"]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.29,"dxc"=>.015),Dict("eta"=>1.,"dxc"=>0.)]
    p["box.rear_spar_points"]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.30,"dxc"=>.01),Dict("eta"=>1.,"dxc"=>0.)]
    shell&&(p["stringers.model"]="shell";p["properties.stringer_flange_width"]=.025)
    angled&&(p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>92.,"pitch"=>.5)])
    first(KB.normalize_params(p))
end

@testset "Local kink elements retain their physical rib-bay mass" begin
    for shell in (false,true),angled in (false,true)
        m=KB.build_model(kink_mass_params(;shell,angled));g=m.grid
        @test KB.all_checks_pass(m)
        bays=KB.structural_bay_mass_properties(m)
        masses=zeros(length(bays));moments=[zeros(3) for _ in bays];seconds=[zeros(3,3) for _ in bays]
        affected=Dict(:bar=>0,:tria=>0)
        for gr in m.groups,e in eachindex(gr.eids)
            n=gr.kind===:bar ? 2 : gr.kind===:tria ? 3 : 4
            nodes=gr.conn[n*(e-1)+1:n*e];rows=[m.node_keys[id][2] for id in nodes]
            lo,hi=extrema(rows);rib=findfirst(==(lo),g.ribs)
            ownership=KB.structural_element_bay_weights(m,gr,e)
            # Independent geometric oracle for the ambiguous same-key case:
            # the skin attachment path lies outboard of its own bounding rib
            # and before the next one. Nose ribs have their own orientation;
            # blade extrusion can legitimately depart the skin's rib plane.
            if lo==hi&&rib!==nothing&&1<rib<length(g.ribs)&&any(id->m.node_keys[id][3]<0,nodes)
                leading=KB.component_base_pid(gr.pid) in (KB.PID_LE_SKIN,KB.PID_LE_RIB)
                ribplane(j)=leading ? KB.leading_edge_effective_rib_plane(m,j) : KB.main_rib_plane(g,m.params,j)
                plane=ribplane(lo)
                points=[g.shell_columns===nothing ? Tuple(m.xyz[3id-2:3id]) :
                    get(g.shell_columns.blade_bases,id,Tuple(m.xyz[3id-2:3id])) for id in nodes]
                ds=[sum(plane.normal.*(point.-plane.origin)) for point in points]
                if maximum(abs,ds)>2e-11*max(m.wing.semispan,m.wing.chord_root,1.)
                    following=ribplane(g.ribs[rib+1])
                    @test minimum(ds)>-1e-10
                    @test all(point->sum(following.normal.*(point.-following.origin))<1e-10,points)
                    @test ownership==[(rib,1.)]
                    affected[gr.kind]=get(affected,gr.kind,0)+1
                end
            end
            # True interior rib webs and their stiffeners still share equally.
            if lo==hi&&rib!==nothing&&1<rib<length(g.ribs)&&KB.component_base_pid(gr.pid) in (KB.PID_RIB_WEB,KB.PID_RIB_STIFFENER)
                @test ownership==[(rib-1,.5),(rib,.5)]
            end
            raw=KB.structural_element_mass_moments(m,gr,e)
            for (bay,fraction) in ownership
                masses[bay]+=fraction*raw.mass;moments[bay].+=fraction.*raw.first;seconds[bay].+=fraction.*raw.second
            end
        end
        @test affected[:bar]>0
        @test affected[:tria]>0
        for (i,bay) in enumerate(bays)
            center=bay["center_of_gravity_m"];inertia=reduce(vcat,permutedims.(bay["inertia_kg_m2"]))
            @test bay["mass_kg"]≈masses[i] rtol=2e-12
            @test bay["mass_kg"]*center≈moments[i] rtol=2e-12
            @test tr(inertia)/2*I-inertia+bay["mass_kg"]*center*center'≈seconds[i] rtol=2e-12
        end
        # Read the exported concentrated model and verify each individual
        # CONM2, including its CG offset and full inertia, against its bay.
        path=joinpath(KINK_OUT,"kink_mass_$(shell ? "shell" : "beam")_$(angled ? "angled" : "normal").bdf")
        open(path,"w") do io;KB.write_deck(IOContext(io,:full_precision=>true),m);end
        native=OpenJFEM.bdf_to_model(path)
        @test length(native["CONM2s"])==length(bays)
        for (bay,spider) in zip(bays,m.fuel_rbe3)
            point=native["CONM2s"][string(KB.structural_conm2_eid(m,spider))]
            @test point["M"]≈bay["mass_kg"] rtol=2e-12
            @test Float64.(point["X"])≈bay["offset_m"] atol=1e-12
            @test Float64.(point["I"])≈bay["conm2_inertia_kg_m2"] atol=1e-12
        end
    end
end
