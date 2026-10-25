using Test, TOML, LinearAlgebra
isdefined(Main,:WingFEGen) || include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

shiftrow(eta,value)=Dict("eta"=>eta,"shift_percent"=>value)
function shift_fixture()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>8.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>7.,"planform.dihedral"=>3.,"planform.twist_tip"=>-2.,
        "planform.root_ref_x"=>2.,"planform.root_ref_y"=>3.,"planform.root_ref_z"=>4.,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.7,"box.stringer_pitch"=>.25,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>11,
        "leading_edge.enabled"=>true,"leading_edge.chord_elements"=>3,
        "properties.rib_stiffeners_enabled"=>false,"loads.cases"=>Any[],
        "fuel.enabled"=>true,"fuel.start_rib"=>1,"fuel.end_rib"=>0,
        "loads.fuel_percent"=>100.,"loads.structure_inertia"=>false))
end

suite=@testset "Vertical shift of the common lifting-surface loft" begin
@testset "Schema, validation and old definitions" begin
    p=shift_fixture();w=W.make_wing(p)
    @test p["loft.vertical_shift_stations"]==Any[]
    @test p["loft.vertical_shift_interpolation"]=="linear"
    @test W.SCHEMA_BY_KEY["loft.vertical_shift_stations"].kind===:loftstations
    delete!(p,"loft.vertical_shift_stations");delete!(p,"loft.vertical_shift_interpolation")
    old=W.make_wing(p);normalized,unknown=W.normalize_params(p)
    @test isempty(unknown)
    @test isempty(normalized["loft.vertical_shift_stations"])
    for eta in (0.,.21,.76,1.),xc in (.1,.4,.8)
        @test W.upper_point(w,eta,xc)==W.upper_point(old,eta,xc)
        @test W.lower_point(w,eta,xc)==W.lower_point(old,eta,xc)
        @test W.vertical_shift(w,eta)==0.
    end
    for rows in ([shiftrow(-.1,1.)],[shiftrow(.2,Inf)],[shiftrow(.2,NaN)],
                 [shiftrow(.2,true)],[shiftrow(true,2.)],
                 [shiftrow(.2,1.),shiftrow(.2,2.)],[Dict("eta"=>.2,"twist"=>1.)])
        @test_throws ArgumentError W.normalize_loft_stations(rows,"loft.vertical_shift_stations")
    end
    @test_throws ArgumentError W.normalize_params(merge(p,Dict("loft.vertical_shift_interpolation"=>"spline")))
    p["loft.vertical_shift_stations"]=[shiftrow(.8,-7.),shiftrow(.2,4.)]
    p["loft.vertical_shift_interpolation"]="cosine"
    normalized,unknown=W.normalize_params(p)
    @test normalized["loft.vertical_shift_stations"]==[shiftrow(.2,4.),shiftrow(.8,-7.)]
    restored,unknown=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(normalized))))
    @test isempty(unknown)
    for key in ("loft.vertical_shift_stations","loft.vertical_shift_interpolation")
        @test restored[key]==normalized[key]
    end
    json,_=W.normalize_params(W.JSON.parse(W.JSON.json(normalized)))
    @test json["loft.vertical_shift_stations"]==normalized["loft.vertical_shift_stations"]
end

@testset "Interpolation and rigid section translation" begin
    p=shift_fixture()
    p["loft.thickness_stations"]=[Dict("eta"=>0.,"tc"=>.17),Dict("eta"=>1.,"tc"=>.11)]
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>3.),Dict("eta"=>.7,"twist"=>-7.)]
    original=W.make_wing(p)
    for method in ("linear","cosine")
        p["loft.vertical_shift_interpolation"]=method
        p["loft.vertical_shift_stations"]=[shiftrow(.2,4.),shiftrow(.8,-7.)]
        w=W.make_wing(p)
        for eta in (0.,.2,.35,.5,.8,1.)
            t=clamp((eta-.2)/.6,0.,1.);weight=method=="linear" ? t : (1-cospi(t))/2
            dz=w.semispan/100*(4*(1-weight)-7weight)
            @test W.vertical_shift(w,eta)≈dz atol=1e-14
            @test collect(W.reference_point(w,eta))≈collect(W.reference_point(original,eta))+[0.,0.,dz] atol=1e-14
            @test W.base_reference_point(w,eta)==W.base_reference_point(original,eta)
            for xc in (.03,.32,.77)
                for point in (W.upper_point,W.lower_point,W.camber_point)
                    a,b=point(original,eta,xc),point(w,eta,xc)
                    @test a[1:2]==b[1:2]
                    @test b[3]≈a[3]+dz atol=2e-14
                end
                @test W.box_height(w,eta,xc)≈W.box_height(original,eta,xc) atol=2e-14
                @test W.zup(w,eta,xc)==W.zup(original,eta,xc)
                @test W.zlo(w,eta,xc)==W.zlo(original,eta,xc)
            end
        end
        @test W.vertical_shift_slope(w,0.)==0.
        @test W.vertical_shift_slope(w,1.)==0.
        slope=(-11/100)/.6*(method=="linear" ? 1. : (pi/2)*sinpi(.25))
        @test W.vertical_shift_slope(w,.35)≈slope atol=1e-14
        @test W.vertical_shift_slope(w,.35)≈(W.vertical_shift(w,.350001)-W.vertical_shift(w,.349999))/(.000002w.semispan) rtol=1e-9
        @test all(e->e in W.with_planform_stations(w,[0.,1.]),(.2,.8))
        @test all(e->e in W.loft_integration_etas(w),(.2,.8))
        @test all(e->e in W.vlm_mesh(w,2,4).etas,(.2,.8))
    end
    p["loft.vertical_shift_stations"]=[shiftrow(.3,-9.)]
    w=W.make_wing(p)
    @test all(e->W.vertical_shift(w,e)==-.09w.semispan,(0.,.2,.8,1.))
    @test W.reference_point(w,0.)[3]≈p["planform.root_ref_z"]-.09w.semispan
    p["planform.leading_edge_points"]=[Dict("eta"=>.5,"dxc"=>-.02)]
    refined=W.make_wing(p);base=W.base_wing(refined)
    @test base!==refined
    @test base.vertical_shift_values==refined.vertical_shift_values
    @test W.vertical_shift(base,.6)==W.vertical_shift(refined,.6)
end

@testset "Mesh, airfoils, fuel, mass and reference coordinates" begin
    p=shift_fixture();p["loft.vertical_shift_stations"]=[shiftrow(0.,0.)]
    m0=W.build_model(p)
    p["loft.vertical_shift_stations"]=[shiftrow(0.,6.)]
    m1=W.build_model(p);dz=.06m1.wing.semispan
    @test m1.grid.etas==m0.grid.etas
    @test m1.grid.ribs==m0.grid.ribs
    @test m1.node_keys==m0.node_keys
    @test [(gr.pid,gr.conn) for gr in m1.groups]==[(gr.pid,gr.conn) for gr in m0.groups]
    @test m1.xyz[1:3:end]==m0.xyz[1:3:end]
    @test m1.xyz[2:3:3m1.n_struct]==m0.xyz[2:3:3m0.n_struct]
    # Integrated fuel reference centroids may differ by roundoff in unchanged x/y.
    @test m1.xyz[2:3:end]≈m0.xyz[2:3:end] atol=1e-13
    @test m1.xyz[3:3:end]≈m0.xyz[3:3:end].+dz atol=1e-12
    @test m1.aero_xyz[1:3:end]==m0.aero_xyz[1:3:end]
    @test m1.aero_xyz[2:3:end]==m0.aero_xyz[2:3:end]
    @test m1.aero_xyz[3:3:end]≈m0.aero_xyz[3:3:end].+dz atol=1e-12
    @test W.fuel_summary(m1)["gross_volume_m3"]≈W.fuel_summary(m0)["gross_volume_m3"] rtol=1e-12
    for (a,b) in zip(W.fuel_geometry_bays(m0),W.fuel_geometry_bays(m1))
        @test b.center≈a.center+[0.,0.,dz] atol=1e-11
        @test b.full≈a.full rtol=1e-10 atol=1e-12
    end
    for (a,b) in zip(W.structural_bay_mass_properties(m0),W.structural_bay_mass_properties(m1))
        @test b["mass_kg"]≈a["mass_kg"] rtol=1e-13
        @test b["center_of_gravity_m"]≈a["center_of_gravity_m"]+[0.,0.,dz] atol=1e-11
        @test b["conm2_inertia_kg_m2"]≈a["conm2_inertia_kg_m2"] atol=1e-10
    end
    # A bent loft inserts its physical kink into structural and aero rows.
    p["loft.vertical_shift_stations"]=[shiftrow(0.,0.),shiftrow(.43,3.),shiftrow(1.,-2.)]
    m=W.build_model(p);g=m.grid
    @test .43 in g.etas
    @test g.etas[g.ribs.+1]==m0.grid.etas[m0.grid.ribs.+1]
    @test all(check->check[3],m.checks)
    for (id,(i,j,k)) in enumerate(m.node_keys[1:m.n_struct])
        0<=i<=W.ni(g)&&0<=j<=W.nj(g)&&0<=k<=g.nh||continue
        @test m.xyz[3id-2:3id]≈collect(W.grid_point(g,i,j,k)) atol=1e-12
    end
    for sp in m.rbe3
        @test m.xyz[3sp.ref-2:3sp.ref]≈collect(W.section_point(m.wing,sp.eta,Float64(p["rbe3.ref_xc"]),0.)) atol=1e-12
    end
    # Shared metadata and explicit airfoil loops follow the shifted loft.
    @test any(row->row[1]=="Loft vertical shift"&&occursin("BASIC +Z",row[2]),m.info)
    for (a,b) in zip(W.airfoil_sections_payload(m0.wing),W.airfoil_sections_payload(m1.wing))
        xa=reinterpret(Float32,a["xyz"].bytes);xb=reinterpret(Float32,b["xyz"].bytes)
        @test xb[3:3:end]≈xa[3:3:end].+Float32(dz) atol=2e-6
    end
    # Angled ribs still lie in their actual planes when crossing a shift kink.
    p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>87.,"pitch"=>.7)]
    angled=W.build_model(p)
    @test W.oriented_ribs(angled.grid)
    @test W.validate_main_rib_mesh(angled)
    @test .43 in W.rib_intersection_cuts(angled.wing,angled.grid.rib_layout,1.)
end

@testset "Constant shift preserves VLM forces and translates global moments" begin
    p=shift_fixture();merge!(p,Dict("loads.method"=>"vortex_lattice","loads.load_factor"=>1.,
        "aero.atmosphere"=>"manual","aero.speed"=>90.,"aero.speed_of_sound"=>340.,
        "aero.alpha"=>2.,"aero.chord_panels"=>2,"aero.span_panels"=>5))
    a=W.solve_vlm(W.make_wing(p),p)
    p["loft.vertical_shift_stations"]=[shiftrow(0.,-8.)]
    w=W.make_wing(p);b=W.solve_vlm(w,p);translation=[0.,0.,-.08w.semispan]
    @test a.summary["CL"]≈b.summary["CL"] rtol=1e-12
    @test a.summary["CDi"]≈b.summary["CDi"] rtol=1e-12
    @test a.summary["force_N"]≈b.summary["force_N"] rtol=1e-12
    @test b.summary["moment_Nm"]≈a.summary["moment_Nm"]+cross(translation,a.summary["force_N"]) rtol=1e-12
    for (pa,pb) in zip(a.panels,b.panels)
        @test collect(pb.position)≈collect(pa.position)+translation atol=1e-12
        @test collect(pb.force)≈collect(pa.force) rtol=1e-12
        @test collect(pb.moment)≈collect(pa.moment) atol=1e-10
    end
end
end

if !isempty(ARGS)
    mkpath(ARGS[1]);write(joinpath(ARGS[1],"vertical_shift_summary.json"),W.JSON.json(Dict(
        "passed"=>true,"test_counts"=>string(Test.get_test_counts(suite)),
        "semispan_percent"=>true,"basic_z_translation"=>true,"default_unchanged"=>true,
        "toml_and_json_round_trip"=>true,"structural_aero_fuel_mass_congruent"=>true,
        "rib_topology_preserved"=>true,"vlm_translation_invariance"=>true,"fe_solver_runs"=>0),2))
end
