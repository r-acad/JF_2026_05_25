using Test, JSON
isdefined(Main,:WingFEGen) || include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

endpoint_row(eta,dxc)=Dict("eta"=>eta,"dxc"=>dxc)
suite=@testset "Short planform endpoint feature diagnostics" begin
    p=W.default_params()
    @test isempty(W.planform_endpoint_warnings(p))
    p["planform.leading_edge_points"]=[endpoint_row(.4,0.),endpoint_row(.999,.2)]
    before=deepcopy(p);geometry=W.planform_geometry(p)
    warning=only(W.planform_endpoint_warnings(p,geometry))
    @test p==before
    @test warning["code"]=="ABRUPT_ENDPOINT_RETURN"
    @test warning["edge"]=="leading"
    @test warning["end"]=="tip"
    @test warning["eta"]==.999
    @test warning["endpoint_eta"]==1.
    @test !warning["endpoint_explicit"]
    @test warning["gap_m"]≈.001geometry.semispan
    @test warning["return_m"]>4warning["gap_m"]
    @test occursin("implicit nominal tip",warning["message"])
    @test geometry.chord_tip≈geometry.base_chord_tip rtol=1e-14
    push!(p["planform.leading_edge_points"],endpoint_row(1.,0.))
    explicit=only(W.planform_endpoint_warnings(p))
    @test explicit["endpoint_explicit"]
    @test occursin("explicit tip",explicit["message"])
    @test explicit["return_m"]==warning["return_m"]
    # Endpoints may intentionally make a feature: diagnose, never move them.
    @test W.planform_geometry(p).leading_etas==geometry.leading_etas
    p["planform.leading_edge_points"]=[endpoint_row(.4,0.),endpoint_row(1.,.2)]
    @test isempty(W.planform_endpoint_warnings(p))
    @test W.planform_geometry(p).chord_tip≈.8geometry.base_chord_tip
    for (eta,dxc) in ((.95,.2),(.999,1e-10))
        p["planform.leading_edge_points"]=[endpoint_row(eta,dxc)]
        @test isempty(W.planform_endpoint_warnings(p))
    end
    p["planform.leading_edge_points"]=Any[]
    p["planform.trailing_edge_points"]=[endpoint_row(.001,.2)]
    root=only(W.planform_endpoint_warnings(p))
    @test root["edge"]=="trailing"
    @test root["end"]=="root"
    @test !root["endpoint_explicit"]
    p["planform.trailing_edge_points"]=Any[];p["planform.sweep"]=80.
    @test isempty(W.planform_endpoint_warnings(p))
    # Collinear short-segment handles are not physical end kinks.
    p["planform.leading_edge_points"]=[endpoint_row(0.,.2),endpoint_row(.999,.2),endpoint_row(1.,.2)]
    @test isempty(W.planform_endpoint_warnings(p))
end
if abspath(PROGRAM_FILE)==(@__FILE__) && !isempty(ARGS)
    write(joinpath(ARGS[1],"planform_endpoint_diagnostic_summary.json"),JSON.json(Dict(
        "passed"=>true,"test_counts"=>string(Test.get_test_counts(suite)),
        "geometry_autocorrected"=>false,"solver_runs"=>0),2))
end
