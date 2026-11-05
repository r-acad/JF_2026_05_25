using Test, WingFEGen
const SG=WingFEGen

@testset "Quarter-chord strip metadata follows the authored wing" begin
    p=SG.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>.8,
        "planform.sweep"=>10.,"planform.dihedral"=>6.,"planform.twist_tip"=>-3.,
        "planform.root_ref_x"=>2.,"planform.root_ref_y"=>3.,"planform.root_ref_z"=>1.,
        "loft.vertical_shift_stations"=>[Dict("eta"=>0.,"shift_percent"=>1.),Dict("eta"=>1.,"shift_percent"=>3.)],
        "movable_surfaces.items"=>Any[],"airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA0012"))
    before=deepcopy(p)
    _,w,controls=SG.aerodynamic_geometry(p)
    settings=SG.aerodynamic_settings(Dict{String,Any}("derivatives"=>false,"chord_panels"=>2,"span_panels"=>4,
        "chord_spacing"=>"uniform","span_spacing"=>"uniform","compressibility"=>"incompressible"),controls)
    patches=SG.aerodynamic_mesh(w,controls,settings)
    payload=SG.aerodynamic_mesh_payload(patches,w,settings)
    rows=payload["strip_geometry"]
    @test length(rows)==sum(size(patch.metrics,2) for patch in patches)
    @test length(rows)<length(payload["panels"])
    @test Set(row["side"] for row in rows)==Set(["left","right"])
    @test length(Set((row["side"],row["patch"],row["strip"]) for row in rows))==length(rows)
    for row in rows
        patch=patches[row["patch"]];j=row["strip"]
        @test row["eta_bounds"]==patch.etas[j:j+1]
        @test row["region"]==patch.name
        for (eta,point) in zip([row["eta_bounds"]...,(sum(row["eta_bounds"])/2)],
                [row["quarter_chord_bounds"]...,row["quarter_chord_position"]])
            expected=collect(SG.section_point(w,eta,.25,0.))
            row["side"]=="left"&&(expected[2]=2w.root_ref_y-expected[2])
            @test point≈expected
            @test all(isfinite,point)
        end
    end
    lookup=Set((row["side"],row["patch"],row["strip"]) for row in rows)
    @test all(panel->(panel["side"],panel["patch"],panel["strip"]) in lookup,payload["panels"])
    @test p==before
end
