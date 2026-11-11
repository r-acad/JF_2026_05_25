using Test, LinearAlgebra, WingFEGen
const W = WingFEGen

function root_alignment_params(; reference="front_spar", angled=false, twist=4.0, model="beam")
    p = merge(W.default_params(), Dict{String,Any}(
        "planform.area"=>4.0, "planform.aspect_ratio"=>4.0,
        "planform.taper_ratio"=>0.8, "planform.sweep"=>0.0,
        "planform.dihedral"=>0.0, "planform.twist_tip"=>-3.0,
        "loft.twist_stations"=>[Dict("eta"=>0.0,"twist"=>twist),Dict("eta"=>1.0,"twist"=>-3.0)],
        "airfoil.root"=>"NACA2412", "airfoil.tip"=>"NACA2412",
        "airfoil.n_points"=>41, "box.end_eta"=>1.0,
        "box.rib_pitch"=>0.4, "box.stringer_pitch"=>0.12,
        "box.stringer_angle_reference"=>reference, "box.stringer_angle"=>0.0,
        "mesh.elements_between_ribs"=>3, "mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>2, "mesh.aero_chord_points"=>9,
        "stringers.model"=>model, "leading_edge.enabled"=>false,
        "fuel.enabled"=>false, "aero.enabled"=>false, "loads.cases"=>Any[]))
    angled && (p["ribs.masters"]=[Dict("eta"=>0.5,"mode"=>"rear_spar_angle","angle"=>85.0,"pitch"=>0.4)])
    first(W.normalize_params(p))
end

function root_alignment_grid(p)
    w=W.make_wing(p);xcs,_=W.chord_stations(w,p);etas,ribs,_=W.span_stations(w,p)
    W.stringer_grid(w,p,xcs,etas,ribs,2)
end

"""Physical skin attachment nodes must follow the prescribed projected path, including R1."""
function check_path(g)
    path=g.rib_layout.path; roots=g.rib_layout.roots
    for (ordinal,i) in enumerate(g.stringer_indices), upper in (false,true), j in 0:W.nj(g)
        iszero(g.collapsed[i+1,j+1]) || continue
        xyz=W.grid_point(g,i,j,upper ? g.nh : 0)
        eta=(xyz[2]-g.wing.root_ref_y)/g.wing.semispan
        expected=roots[ordinal+1]+W.stringer_offset(path,eta)
        @test isapprox(xyz[1],expected;atol=3e-11,rtol=0.0)
    end
end

@testset "Root stringers use the same surface-plane intersections as every other row" begin
    for angled in (false,true), reference in ("front_spar","rear_spar","global_y"), twist in (-4.0,4.0)
        p=root_alignment_params(;angled,reference,twist)
        g=root_alignment_grid(p)
        check_path(g)
        # Constant projected slopes cannot acquire an unrequested first-segment kink.
        for i in g.stringer_indices, upper in (false,true)
            all(iszero,g.collapsed[i+1,1:3]) || continue
            k=upper ? g.nh : 0
            a,b,c=(W.grid_point(g,i,j,k) for j in 0:2)
            @test isapprox((b[1]-a[1])/(b[2]-a[2]),(c[1]-b[1])/(c[2]-b[2]);atol=5e-10)
        end
    end
end

@testset "Requested stringer kinks and rib-datum runouts remain physical" begin
    p=root_alignment_params()
    p["box.stringer_angle_reference"]="global_y"
    p["ribs.masters"]=[Dict("eta"=>0.5,"mode"=>"flight_direction","angle"=>90.0,"pitch"=>0.4)]
    p["box.stringer_segment_angles"]=[0.0,5.0]
    g=root_alignment_grid(p);check_path(g)
    @test 0.5 in g.rib_layout.path.kink_etas
    @test W.stringer_slope(g.rib_layout.path,0.49)==0.0
    @test W.stringer_slope(g.rib_layout.path,0.51)≈tand(5.0)
    @test any(!iszero,g.collapsed)
    for i in g.stringer_indices
        first_collapsed=findfirst(!iszero,view(g.collapsed,i+1,:))
        first_collapsed===nothing && continue
        @test first_collapsed-2 in g.ribs
    end
end

@testset "Generated PBARL and shell stringer attachments preserve the root path" begin
    for model in ("beam","shell")
        p=root_alignment_params(;model)
        m=W.build_model(p)
        check_path(m.grid)
        @test W.all_checks_pass(m)
    end
end
