module PandeatorModelTests

using Test
using LinearAlgebra
include(joinpath(@__DIR__,"..","..","APPS","PANDEATOR_APP","panel_model.jl"))
using .PandeatorModel

const SMALL=Dict{String,Any}("nx"=>4,"ny"=>3,"nz"=>2,"nf"=>2)

@testset "Canonical panel laminate notation" begin
    @test parse_laminate("(45/-45/0/90)S")==[45.,-45.,0.,90.,90.,0.,-45.,45.]
    @test parse_laminate("(45/-45/0/90)\$")==[45.,-45.,0.,90.,0.,-45.,45.]
    @test parse_laminate("2(0/90)")==[0.,90.,0.,90.]
    @test parse_laminate("2((0/90)S)")==[0.,90.,90.,0.,0.,90.,90.,0.]
    @test parse_laminate("-45,0,45")==[-45.,0.,45.]
    @test_throws ArgumentError parse_laminate("(0/90")
    @test_throws ArgumentError parse_laminate("0/abc")
end

@testset "One conforming combined flange footprint" begin
    m=build_panel_model(SMALL)
    @test length(m.nodes)==55
    @test length(m.elements)==40
    @test count(e->e["pid"]==3,m.elements)==8
    @test count(e->e["pid"]==1,m.elements)==24
    @test count(e->e["pid"]==2,m.elements)==8
    @test m.properties[3]["thickness"]==4.
    @test m.properties[3]["type"]=="PSHELL"
    @test length(Set(Tuple(sort(e["n"])) for e in m.elements))==length(m.elements)
    @test all(frame->frame'*frame≈I&&det(frame)≈1.,values(m.frames))
    @test all(frame->frame[:,3]==[1.,0.,0.],values(m.frames))
    @test m.report["boundary"]["final_rigid_rank"]==6
    @test m.report["boundary"]["physical_rigid_rank"]==5
    @test length(m.report["boundary"]["anchors"])==1
    @test all(row->all(d->d<=3,row["components"]),m.constraints)
    # Tangential membrane displacement is not locked over the skin perimeter.
    edge=Set(vcat(m.edges["edgeY0"],m.edges["edgeY1"]))
    @test all(row->!(row["nid"] in edge&&2 in row["components"]),m.constraints)
    skinarea=sum(e["area"] for e in m.elements if e["pid"]!=2)
    footarea=sum(e["area"] for e in m.elements if e["pid"]==3)
    expected=(skinarea*2+footarea*2+800*40*2)*2.7e-9
    @test m.report["mass_tonnes"]≈expected rtol=2e-14
    @test norm(m.report["loads"]["net_force_N"])<1e-8
    @test norm(m.report["loads"]["net_moment_Nmm"])<1e-6
    payload=panel_mesh_payload(m)
    @test payload["geometry"]["counts"]["nQuads"]==40
    @test payload["mass_tonnes"]==m.report["mass_tonnes"]
    @test occursin("CORD2R",payload["bdf"])
    @test !occursin("CORD2C",payload["bdf"])
    @test !occursin("ZOFFS",payload["bdf"])
end

@testset "Flange offsets, composite layers and material continuity" begin
    shifted=build_panel_model(merge(SMALL,Dict("shell_offsets"=>true)))
    @test shifted.properties[3]["type"]=="PCOMP"
    @test shifted.properties[3]["z0"]==-1.
    @test shifted.properties[3]["reference_offset"]==1.
    @test panel_property_directions(shifted,"tFoot")[3]["z0"]==0.
    @test panel_property_directions(shifted,"tSkin")[3]["z0"]==-.5
    @test panel_property_directions(shifted,"tSkin")[1]["thickness"]==1.
    @test panel_property_directions(shifted,"tSkin")[3]["thickness"]==1.
    comp=build_panel_model(merge(SMALL,Dict("material_mode"=>"composite","shell_offsets"=>true)))
    @test length(comp.properties[3]["layers"])==16
    @test all(layer->layer["role"]=="skin",comp.properties[3]["layers"][1:8])
    @test all(layer->layer["role"]=="foot",comp.properties[3]["layers"][9:16])
    @test comp.properties[3]["z0"]≈-8*.18/2
    @test [row["id"] for row in panel_variables(comp)]==["scaleSkin","scaleWeb","scaleFoot"]
    mixed=build_panel_model(merge(SMALL,Dict("footMaterial"=>101,"materials"=>[
        Dict("id"=>101,"type"=>"MAT1","E"=>50000.,"nu"=>.25,"rho"=>2.0e-9)])))
    @test mixed.properties[3]["type"]=="PCOMP"
    @test [layer["material_id"] for layer in mixed.properties[3]["layers"]]==[100,101]
    @test occursin("PCOMP,3",panel_bdf(mixed))
end

@testset "Membrane tractions and exact stiffness-allocation derivatives" begin
    for R in (0.,1000.),key in ("Nx","Ny","Nxy")
        m=build_panel_model(merge(SMALL,Dict("R"=>R,"Nx"=>0.,"Ny"=>0.,"Nxy"=>0.,key=>123.)))
        @test norm(m.report["loads"]["net_force_N"])<1e-8
        @test norm(m.report["loads"]["net_moment_Nmm"])<1e-5
        if key=="Nx"
            @test sum(get(m.forces,id,zeros(3))[1] for id in unique(vcat(m.edges["edgeX0"],m.edges["webX0"])))≈123*600 rtol=2e-14
        end
    end
    for mode in ("iso","composite"),offset in (false,true)
        m=build_panel_model(merge(SMALL,Dict("material_mode"=>mode,"shell_offsets"=>offset,"Nx"=>123.,"Nxy"=>37.,"Ny"=>19.)))
        for var in panel_variables(m)
            id=var["id"];h=1e-5*max(abs(var["value"]),1.)
            plus=build_panel_model(merge(m.params,Dict(id=>var["value"]+h)))
            minus=build_panel_model(merge(m.params,Dict(id=>var["value"]-h)))
            @test [e["n"] for e in plus.elements]==[e["n"] for e in m.elements]
            @test [n["z"] for n in plus.nodes]==[n["z"] for n in m.nodes]
            d=panel_property_directions(m,id);df=panel_load_direction(m,id)
            for pid in keys(m.properties)
                @test d[pid]["thickness"]≈(plus.properties[pid]["thickness"]-minus.properties[pid]["thickness"])/(2h) rtol=2e-9 atol=1e-10
                @test d[pid]["z0"]≈(plus.properties[pid]["z0"]-minus.properties[pid]["z0"])/(2h) rtol=2e-9 atol=1e-10
            end
            ids=union(keys(plus.forces),keys(minus.forces),keys(df))
            fd=reduce(vcat,[(get(plus.forces,n,zeros(3))-get(minus.forces,n,zeros(3)))/(2h) for n in ids])
            exact=reduce(vcat,[get(df,n,zeros(3)) for n in ids])
            @test norm(fd-exact)/max(norm(fd),1.)<2e-8
        end
    end
end

@testset "Flat/bare models and explicit invalid inputs" begin
    bare=build_panel_model(merge(SMALL,Dict("R"=>0.,"bladeH"=>0.,"footW"=>0.)))
    @test length(bare.elements)==4*6
    @test Set(e["pid"] for e in bare.elements)==Set([1])
    @test bare.report["boundary"]["physical_rigid_rank"]==3
    @test length(bare.report["boundary"]["anchors"])==3
    @test [v["id"] for v in panel_variables(bare)]==["tSkin"]
    curved=build_panel_model(merge(SMALL,Dict("bladeH"=>0.,"footW"=>0.)))
    @test curved.report["boundary"]["physical_rigid_rank"]==4
    @test length(curved.report["boundary"]["anchors"])==2
    zero=build_panel_model(merge(SMALL,Dict("Nx"=>0.,"Ny"=>0.,"Nxy"=>0.)))
    @test isempty(zero.forces)
    @test !zero.report["analysis_allowed"]
    @test_throws ArgumentError panel_bdf(zero)
    @test occursin("SOL 105",panel_mesh_payload(zero)["bdf"])
    @test !occursin("FORCE,",panel_mesh_payload(zero)["bdf"])
    odd=build_panel_model(merge(SMALL,Dict("nf"=>3)))
    @test odd.report["mesh_counts"]["flange_width"]==4
    @test count(e->e["pid"]==3,odd.elements)==16
    @test !isempty(odd.warnings)
    nearlyflat=build_panel_model(merge(SMALL,Dict("R"=>1e12,"bladeH"=>0.,"footW"=>0.)))
    @test all(node->all(isfinite(node[key]) for key in ("x","y","z")),nearlyflat.nodes)
    @test nearlyflat.report["boundary"]["final_rigid_rank"]==6
    clamped=build_panel_model(merge(SMALL,Dict("boundary_mode"=>"clamped")))
    @test any(row->any(d->d>3,row["components"]),clamped.constraints)
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("E"=>1e308,"tSkin"=>1e308)))
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("footW"=>601.)))
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("R"=>10.)))
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("buckling_policy_factor"=>0.)))
    ortho=Dict{String,Any}("id"=>100,"type"=>"MAT8","E1"=>140000.,"E2"=>9000.,"nu12"=>.3,"G12"=>5000.,"rho"=>1.6e-9)
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("material_mode"=>"composite","materials"=>[merge(ortho,Dict("G13"=>-1.))])))
    @test_throws ArgumentError build_panel_model(merge(SMALL,Dict("material_mode"=>"composite","materials"=>[merge(ortho,Dict("G23"=>0.))])))
    @test_throws ArgumentError parse_laminate("1000(0/90)")
end

end
