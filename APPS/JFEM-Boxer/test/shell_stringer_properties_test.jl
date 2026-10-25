# julia --project=. APPS/JFEM-Boxer/test/shell_stringer_properties_test.jl <private-output-directory>
using Test, LinearAlgebra, JSON
using WingFEGen, OpenJFEM
const W=WingFEGen
const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)

function test_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "planform.sweep"=>12.,"planform.twist_tip"=>-3.,"box.end_eta"=>1.,"box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.18,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>2,"mesh.elements_stringer_height"=>2,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,"fuel.enabled"=>false,
        "leading_edge.enabled"=>false,"loads.cases"=>Any[],"aero.enabled"=>false,
        "loads.structure_inertia"=>true,"loads.fuel_accel_z"=>-1.,"output.solution"=>"101"))
    p
end

function native_mass(m,name)
    path=joinpath(out,name*".bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    native=N.bdf_to_model(path)
    ids=sort(parse.(Int,collect(keys(native["GRIDs"]))))
    index=Dict(id=>i for (i,id) in enumerate(ids))
    xyz=reduce(vcat,[transpose(Float64.(native["GRIDs"][string(id)]["X"])) for id in ids])
    rotations=[Matrix{Float64}(I,3,3) for _ in ids]
    matrix=N.Solver.assemble_mass(native,index,xyz,rotations,6length(ids))
    translations=[begin v=zeros(6length(ids));v[axis:6:end].=1;dot(v,matrix*v) end for axis in 1:3]
    rigid=zeros(6length(ids),6)
    for i in eachindex(ids)
        rigid[6i-5:6i-3,1:3].=Matrix{Float64}(I,3,3)
        rigid[6i-5:6i-3,4:6].=-N.Solver.skew3(xyz[i,:])
        rigid[6i-2:6i,4:6].=Matrix{Float64}(I,3,3)
    end
    native,translations,rigid'*matrix*rigid
end

tests=@testset "Shell stringer properties, export and conserved mass" begin
    p=test_params();beam=W.build_model(W.normalize_params(p)[1])
    @test !W.shell_stringers(beam.params)
    @test_throws ArgumentError W.normalize_params(merge(p,Dict("properties.stringer_flange_width"=>0.)))
    @test all(!W.is_shell_stringer_pid(g.pid) for g in beam.groups)
    @test any(W.component_base_pid(g.pid)==W.PID_STRINGER&&g.kind===:bar for g in beam.groups)
    p["stringers.model"]="shell"
    @test_throws ArgumentError W.normalize_params(merge(p,Dict("properties.stringer_flange_thickness"=>0.)))
    only(filter(row->row["component"]=="stringer",p["materials.bars"]))["material"]=2
    m0=W.build_model(W.normalize_params(p)[1])
    panels=W.stiffened_panels_payload(m0)
    @test panels["count"]>0
    @test all(W.component_base_pid(g.pid)!=W.PID_STRINGER for g in m0.groups)
    properties=Dict(row["pid"]=>row for row in W.model_property_definitions(m0))
    for panel in panels["panels"]
        @test !isempty(panel["stringer_web_eids"])
        @test !isempty(panel["stringer_flange_eids"])
        @test isempty(intersect(panel["skin_eids"],panel["stringer_eids"]))
        @test sort(vcat(panel["stringer_web_eids"],panel["stringer_flange_eids"]))==panel["stringer_eids"]
        for (field,thickness) in (("stringer_web_pid",p["properties.stringer_web_thickness"]),("stringer_flange_pid",p["properties.stringer_flange_thickness"]))
            prop=properties[panel[field]]
            if field=="stringer_web_pid"
                @test prop["type"]=="PSHELL"
                @test prop["material_id"]==2
                @test prop["thickness_m"]==thickness
            else
                @test prop["type"]=="PCOMP"
                @test [ply["material_id"] for ply in prop["plies"]]==[2,1]
                @test prop["thickness_m"]==thickness+panel["skin_thickness_m"]
            end
        end
    end
    annotations=W.physical_annotations(m0)
    @test sum(length(row["eids"])-length(row["runout_eids"]) for row in annotations["stringers"])==sum(length(row["stringer_eids"]) for row in panels["panels"])
    p["nonstructural.stringer"]=.37
    m=W.build_model(W.normalize_params(p)[1])
    weights=W.weights_payload(m);weights0=W.weights_payload(m0)
    expected=.37sum(row["stringer_length_m"] for row in panels["panels"])
    @test weights["totals"]["nonstructural_mass_kg"]≈expected rtol=1e-12
    @test weights["totals"]["structure_mass_kg"]-weights0["totals"]["structure_mass_kg"]≈expected rtol=1e-12
    @test weights["totals"]["material_mass_kg"]≈weights0["totals"]["structure_mass_kg"] rtol=1e-12
    @test only(filter(row->row["id"]=="stringers",weights["components"]))["kind"]=="shell"
    @test sum(row["mass_kg"] for row in W.structural_inertia_payload(m))≈weights["totals"]["structure_mass_kg"] rtol=1e-11
    @test sum(W.structural_mass_data(m).nodal_mass)≈weights["totals"]["structure_mass_kg"] rtol=1e-11
    native,translations,_=native_mass(m,"shell_stringers")
    @test native["PARAM_COUPMASS"]==1
    @test all(isapprox(value,weights["totals"]["structure_mass_kg"];rtol=1e-10) for value in translations)
    for prop in W.model_property_definitions(m)
        W.is_shell_stringer_pid(prop["pid"])||continue
        card=native["PSHELLs"][string(prop["pid"])]
        if prop["type"]=="PSHELL"
            @test card["MID"]==2
        else
            @test card["TYPE"]=="PCOMP_CLT"
            @test [parse(Int,string(ply["mid"])) for ply in card["PLY_DATA"]]==[ply["material_id"] for ply in prop["plies"]]
        end
        @test card["T"]≈prop["thickness_m"]
        @test card["NSM"]≈prop["nonstructural_mass_kg_m2"]
        @test !haskey(native["PBARLs"],string(prop["pid"]))
    end
    # Bay CONM2 export must retain the complete shell-stringer mass, CG and
    # rotary inertia while removing every distributed material/NSM copy.
    concentrated=W.build_model(W.normalize_params(merge(p,Dict("mass.structural_representation"=>"bay_concentrated")))[1])
    cnative,ctranslations,crigid=native_mass(concentrated,"shell_stringers_bay_concentrated")
    @test !haskey(cnative,"PARAM_COUPMASS")
    moments=[W.structural_element_mass_moments(m,g,e) for g in m.groups for e in eachindex(g.eids)]
    mass=sum(row.mass for row in moments);first_moment=sum(row.first for row in moments);second=sum(row.second for row in moments)
    expected_rigid=zeros(6,6)
    expected_rigid[1:3,1:3].=mass.*Matrix{Float64}(I,3,3)
    expected_rigid[1:3,4:6].=-N.Solver.skew3(first_moment)
    expected_rigid[4:6,1:3].=N.Solver.skew3(first_moment)
    expected_rigid[4:6,4:6].=tr(second).*Matrix{Float64}(I,3,3)-second
    @test crigid≈expected_rigid rtol=1e-11 atol=1e-10
    @test all(isapprox(value,mass;rtol=1e-11) for value in ctranslations)
    @test length(cnative["CONM2s"])==length(concentrated.grid.ribs)-1
    @test all(get(mat,"RHO",0.)==0. for mat in values(cnative["MATs"]))
    @test all(get(prop,"NSM",0.)==0. for key in ("PSHELLs","PBARs","PBARLs") for prop in values(get(cnative,key,Dict())))
    # A per-panel blade keeps independent material/web thickness and no flange property.
    firstpanel=first(panels["panels"])
    # Zero-width local blades require an explicitly zero family width minimum.
    # Keep every other panel's original flange to test mixed construction.
    nominal_flange_width=p["properties.stringer_flange_width"]
    p["properties.stringer_flange_width"]=0.
    p["properties.panels"]=[Dict("key"=>firstpanel["key"],"layout_token"=>panels["layout_token"],
        "stringer"=>Dict("flange_width"=>0.,"flange_thickness"=>0.,"web_thickness"=>.003,"material"=>1))]
    for panel in panels["panels"]
        panel["key"]==firstpanel["key"]&&continue
        push!(p["properties.panels"],Dict("key"=>panel["key"],"layout_token"=>panels["layout_token"],
            "stringer"=>Dict("flange_width"=>nominal_flange_width)))
    end
    mixed=W.build_model(W.normalize_params(p)[1]);mixedpanels=W.stiffened_panels_payload(mixed)
    changed=only(filter(row->row["key"]==firstpanel["key"],mixedpanels["panels"]))
    @test changed["stringer_flange_pid"]===nothing
    @test isempty(changed["stringer_flange_eids"])
    prop=W.shell_material_definition(mixed.params,changed["stringer_web_pid"])
    @test prop["material_id"]==1
    @test prop["thickness_m"]==.003
    @test !any(row["pid"]==W.panel_stringer_flange_pid(firstpanel["id"]) for row in W.model_property_definitions(mixed))
    # Width zero globally produces only blades and preserves input line NSM.
    p["properties.panels"]=Any[];p["properties.stringer_flange_width"]=0.;p["properties.stringer_flange_thickness"]=0.
    blade=W.build_model(W.normalize_params(p)[1]);bladepanels=W.stiffened_panels_payload(blade)
    @test all(W.component_base_pid(g.pid)!=W.PID_STRINGER_FLANGE for g in blade.groups)
    @test all(isempty(row["stringer_flange_eids"]) for row in bladepanels["panels"])
    @test W.weights_payload(blade)["totals"]["nonstructural_mass_kg"]≈.37sum(row["stringer_length_m"] for row in bladepanels["panels"]) rtol=1e-12
    blade_native,blade_translations,_=native_mass(blade,"blade_stringers")
    @test all(isapprox(value,W.weights_payload(blade)["totals"]["structure_mass_kg"];rtol=1e-10) for value in blade_translations)
    @test !any(W.component_base_pid(parse(Int,pid))==W.PID_STRINGER_FLANGE for pid in keys(blade_native["PSHELLs"]))
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
