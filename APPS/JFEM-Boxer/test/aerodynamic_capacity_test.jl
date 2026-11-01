using Test, WingFEGen
const AC=WingFEGen

function capacity_fixture()
    p=AC.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "movable_surfaces.items"=>Any[]))
    p
end

@testset "Authored geometry has no station or coordinate count ceiling" begin
    p=capacity_fixture();n=105
    p["planform.leading_edge_points"]=[Dict("eta"=>i/(n+1),"dxc"=>0.) for i in 1:n]
    p["loft.vertical_shift_stations"]=[Dict("eta"=>i/(n+1),"shift_percent"=>0.) for i in 1:n]
    p["airfoil.stations"]=[Dict("eta"=>i/(n+1),"source"=>"naca","code"=>"NACA0012") for i in 1:n]
    p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Control $i","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>(i-1)/n,"eta_end"=>i/n,"hinge_start"=>.75,"hinge_end"=>.75,
        "deflection"=>0.,"color"=>"#ffcc00") for i in 1:n]
    parsed,w,controls=AC.aerodynamic_geometry(p)
    @test length(parsed["planform.leading_edge_points"])==n
    @test length(parsed["loft.vertical_shift_stations"])==n
    @test length(parsed["airfoil.stations"])==n
    @test length(controls)==n
    @test length(AC.aerodynamic_settings(Dict(),controls)["controls"])==n
    drawings=AC.normalize_drawings(AC.JSON.json(Dict("airfoil-station-105"=>Dict("version"=>1))))
    @test haskey(AC.JSON.parse(drawings),"airfoil-station-105")
    # Actual local coordinate parsing exceeds the former per-surface and file
    # ceilings without building an FE grid or solving an aerodynamic system.
    x=collect(range(0.,1.;length=20001));z=.06 .* sinpi.(x)
    profile=Dict("version"=>1,"source_kind"=>"file","id"=>"large.dat","filename"=>"large.dat",
        "raw_sha256"=>repeat("a",64),"imported_at"=>"2026-10-30T00:00:00Z",
        "xu"=>x,"zu"=>z,"xl"=>x,"zl"=>-z)
    @test length(AC.airfoil_from_profile(profile;expected_source="file").xu)==20001
    p["airfoil.root_source"]="file"
    profile["name"]=repeat("x",2_000_001)
    p["airfoil.root_profile"]=AC.JSON.json(profile)
    @test length(AC.embedded_airfoil(p,"root").xu)==20001
    text="# "*repeat("x",2_000_001)*"\nLarge section\n"*join(
        ["$u $v" for (u,v) in vcat(collect(zip(reverse(x),reverse(z))),collect(zip(x[2:end],-z[2:end])))],"\n")
    @test length(AC.parse_coordinate_airfoil(text;id="large.dat",source_kind="file")["xu"])==20001
    bad=deepcopy(p["loft.vertical_shift_stations"]);bad[end]["eta"]=bad[end-1]["eta"]
    @test_throws ArgumentError AC.normalize_loft_stations(bad,"loft.vertical_shift_stations")
end

@testset "Mesh and wake capacity without application budgets" begin
    p=capacity_fixture();_,w,controls=AC.aerodynamic_geometry(p)
    # Full-wing preview exceeds both former hard 4096 and saved 2048 caps.
    # This tests actual validated mesh output without allocating a dense solve.
    raw=Dict{String,Any}("chord_panels"=>32,"span_panels"=>128,
        "chord_spacing"=>"uniform","span_spacing"=>"uniform","derivatives"=>false,
        "max_panels"=>2048,"wake_model"=>"relaxed","compressibility"=>"incompressible",
        "wake_rows"=>100,"wake_length"=>12.,"wake_iterations"=>600)
    result=AC.run_aerodynamic_study(p,raw;mesh_only=true)
    mesh=only(result["cases"])
    @test mesh["panel_count"]>4096
    @test mesh["panel_count"]==length(mesh["panels"])
    @test result["settings"]["max_panels"]==0
    @test .7-1e-9<=mesh["min_panel_aspect_ratio"]<=mesh["max_panel_aspect_ratio"]<=1.5+1e-9
    @test mesh["max_warp_deg"]<=result["settings"]["max_panel_warp"]
    @test mesh["max_normal_error_deg"]<=result["settings"]["max_normal_error"]
    @test all(isfinite(v) for panel in mesh["panels"] for corner in panel["corners"] for v in corner)
    patches=AC.aerodynamic_mesh(w,controls,result["settings"])
    @test sum((result["settings"]["wake_rows"]+1)*size(patch.grid,3) for patch in patches)>12000
    # The load-transfer VLM shares geometry validation but had a second 4096 cap.
    half=AC.vlm_mesh(w,33,129)
    @test length(half.metrics)>4096
    @test all(m.warp_deg<=AC.VLM_MAX_PANEL_WARP_DEG for m in half.metrics)
    println("Large preview: ",mesh["panel_count"]," full-wing panels; legacy half-wing mesh: ",length(half.metrics)," panels")
end

@testset "Resolution, Cartesian sweeps and integer safety" begin
    p=capacity_fixture();_,_,controls=AC.aerodynamic_geometry(p)
    raw=Dict{String,Any}("chord_panels"=>81,"span_panels"=>161,"control_chord_panels"=>31,
        "wake_rows"=>81,"wake_iterations"=>301,"wake_length"=>20.,"max_panels"=>16)
    s=AC.aerodynamic_settings(raw,controls)
    for key in ("chord_panels","span_panels","control_chord_panels","wake_rows","wake_iterations","wake_length")
        @test s[key]==raw[key]
    end
    @test s["max_panels"]==0
    p["aero.span_panels"]=65;p["aero.chord_panels"]=25
    @test AC.validate_params(p)===nothing
    sweeps=[Dict("variable"=>key,"start"=>0.,"stop"=>1.,"count"=>count)
        for (key,count) in (("alpha",102),("beta",2),("p",2),("q",2))]
    expanded=AC.aerodynamic_conditions(AC.aerodynamic_settings(Dict("mode"=>"sweep","sweeps"=>sweeps),controls),controls)
    @test length(expanded)==816
    @test first(expanded)["alpha"]==0. && last(expanded)["alpha"]==1.
    for bad in (0,-1,1.5,Inf,NaN,true,typemax(Int))
        @test_throws ArgumentError AC.aerodynamic_settings(Dict("chord_panels"=>bad),controls)
    end
    @test_throws ArgumentError AC.aerodynamic_settings(Dict("wake_rows"=>3),controls)
    @test_throws ArgumentError AC.aerodynamic_settings(Dict("wake_length"=>Inf),controls)
    @test_throws ArgumentError AC.vlm_checked_size("test",typemax(Int),2)
    huge=[Dict("variable"=>key,"start"=>0.,"stop"=>1.,"count"=>2^32) for key in ("alpha","beta")]
    huge_settings=AC.aerodynamic_settings(Dict("mode"=>"sweep","sweeps"=>huge),controls)
    @test_throws ArgumentError AC.aerodynamic_conditions(huge_settings,controls)
end
