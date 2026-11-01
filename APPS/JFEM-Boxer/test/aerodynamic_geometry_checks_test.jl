using WingFEGen,Test
const G=WingFEGen
isdefined(G,:aerodynamic_body_interference)||Base.include(G,joinpath(@__DIR__,"../src/aerodynamic_geometry_checks.jl"))
function check_patch(xs,ys,z;name="fixed wing")
    grid=zeros(3,length(xs),length(ys))
    for (i,x) in enumerate(xs),(j,y) in enumerate(ys);grid[:,i,j].=(x,y,z(x,y));end
    (;grid,element_name=name,name,side="right")
end
@testset "Actual body geometry distinguishes interference from shared edges" begin
    fixed=check_patch([0.,1.],[0.,1.],(x,y)->0.)
    cross=check_patch([.25,.75],[.25,.75],(x,y)->x-.5;name="control: flap")
    report=G.aerodynamic_body_interference([fixed,cross])
    @test !report["valid"]
    @test report["count"]==1
    @test only(report["contacts"])["intersection_length_m"]≈.5
    @test "control: flap" in report["affected_surfaces"]
    @test all(isfinite,only(report["contacts"])["point_m"])
    above=check_patch([.25,.75],[.25,.75],(x,y)->.2;name="control: flap")
    @test G.aerodynamic_body_interference([fixed,above])["valid"]
    overlap=check_patch([.25,.75],[.25,.75],(x,y)->0.;name="control: flap")
    coplanar=G.aerodynamic_body_interference([fixed,overlap])
    @test !coplanar["valid"]
    @test only(coplanar["contacts"])["coplanar_overlap_area_m2"]≈.25
    adjacent=check_patch([1.,2.],[0.,1.],(x,y)->0.)
    @test G.aerodynamic_body_interference([fixed,adjacent])["valid"]
    hinged=check_patch([1.,2.],[0.,1.],(x,y)->.3(x-1);name="control: flap")
    @test G.aerodynamic_body_interference([fixed,hinged])["valid"]
    distant=check_patch([10.,11.],[0.,1.],(x,y)->0.;name="control: flap")
    @test G.aerodynamic_body_interference([fixed,distant])["candidate_triangle_pairs"]==0
    @test G.aerodynamic_body_interference([fixed])["valid"]
    @test fixed.grid[3,:,:]==zeros(2,2)
end

@testset "Interference broadphase is independent of patch ordering" begin
    base=check_patch([0.,1.],[0.,1.],(x,y)->0.)
    crossing=check_patch([.25,.75],[.25,.75],(x,y)->x-.5;name="control: flap")
    far=[check_patch([10k,10k+1.],[0.,1.],(x,y)->0.;name="far $k") for k in 1:80]
    forward=G.aerodynamic_body_interference(vcat([base,crossing],far))
    reverse_order=G.aerodynamic_body_interference(reverse(vcat([base,crossing],far)))
    @test forward["count"]==reverse_order["count"]==1
    @test forward["candidate_triangle_pairs"]==reverse_order["candidate_triangle_pairs"]
    @test forward["candidate_triangle_pairs"]<=4
    @test only(forward["contacts"])["intersection_length_m"]≈only(reverse_order["contacts"])["intersection_length_m"]
    @test G.aerodynamic_body_interference(far)["candidate_triangle_pairs"]==0
end

@testset "Coplanar overlap is translation invariant" begin
    a=check_patch([0.,1.],[0.,1.],(x,y)->0.)
    b=check_patch([.25,.75],[.25,.75],(x,y)->0.;name="control: flap")
    reference=G.aerodynamic_body_interference([a,b])
    delta=reshape([1e8,-2e8,3e8],3,1,1)
    shifted=[merge(p,(grid=p.grid.+delta,)) for p in (a,b)]
    report=G.aerodynamic_body_interference(shifted)
    @test !report["valid"]
    @test report["count"]==reference["count"]
    @test only(report["contacts"])["coplanar_overlap_area_m2"]≈only(reference["contacts"])["coplanar_overlap_area_m2"]
end
