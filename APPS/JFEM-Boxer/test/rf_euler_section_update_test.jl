# julia --project=. APPS/JFEM-Boxer/test/rf_euler_section_update_test.jl PRIVATE_OUTPUT_DIRECTORY
using Test, LinearAlgebra, JSON, WingFEGen
const W=WingFEGen
length(ARGS)==1 || error("Provide a private output directory")
const OUT=abspath(only(ARGS));mkpath(OUT)

@testset "Fixed-load Euler metadata responds to local PBARL and skin edits" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"loads.cases"=>Any[],
        "stringers.model"=>"beam"))
    m=W.build_model(first(W.normalize_params(p)))
    original=deepcopy(m.params);xyz=copy(m.xyz)
    layout=W.stiffened_panel_layout(m.grid);panel=first(filter(row->row.upper&&row.bay==1,layout.panels))
    key=W.panel_key(panel);token=W.panel_layout_token(m.grid,layout)
    variants=Dict("baseline"=>Dict(),"stringer_height"=>Dict("stringer"=>Dict("height"=>.05)),
        "stringer_web"=>Dict("stringer"=>Dict("web_thickness"=>.004)),
        "skin_thickness"=>Dict("skin"=>Dict("thickness"=>.003)))
    updates=Dict{String,Any}()
    EI(station)=begin
        k=sum(reduce(vcat,permutedims.(part["axial_matrix"])) for part in station["parts"])
        eigmin(Symmetric(k[2:3,2:3]-k[2:3,1]*transpose(k[2:3,1])/k[1,1]))
    end
    for name in ("baseline","stringer_height","stringer_web","skin_thickness")
        edited=deepcopy(original)
        name=="baseline" || (edited["properties.panels"]=[merge(Dict("key"=>key,"layout_token"=>token),variants[name])])
        update=W.rf_section_update(m,edited)
        column=only(filter(row->row["key"]==key,update["stiffened_panels"]["euler_columns"]))
        @test column["status"]=="ready"
        @test update["fixed_geometry"]
        @test column["length_m"]>0
        updates[name]=Dict("column"=>column,"weakest_EI"=>minimum(EI(station) for station in column["stations"]),
            "panel"=>only(filter(row->row["key"]==key,update["stiffened_panels"]["panels"])))
        name=="baseline" || (@test updates[name]["weakest_EI"]>updates["baseline"]["weakest_EI"])
    end
    for name in ("stringer_height","stringer_web","skin_thickness")
        @test updates[name]["column"]["member_element_ids"]==updates["baseline"]["column"]["member_element_ids"]
        @test [station["force_terms"] for station in updates[name]["column"]["stations"]]==
            [station["force_terms"] for station in updates["baseline"]["column"]["stations"]]
    end
    @test updates["stringer_height"]["panel"]["stringer_dimensions_m"][2]==.05
    @test updates["stringer_web"]["panel"]["stringer_dimensions_m"][4]==.004
    @test updates["skin_thickness"]["panel"]["skin_thickness_m"]==.003
    @test m.xyz==xyz
    @test m.params==original
    write(joinpath(OUT,"sections.json"),JSON.json(updates))
end
