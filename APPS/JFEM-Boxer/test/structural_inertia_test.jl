using Test, LinearAlgebra
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W=WingFEGen

@testset "Structural display mass moments" begin
    p=W.default_params()
    p["loads.method"]="analytic"
    p["box.rib_pitch"]=2.
    p["mesh.elements_between_ribs"]=1
    p["mesh.elements_between_stringers"]=1
    p["fuel.enabled"]=false
    m=W.build_model(W.normalize_params(p)[1]);rows=W.structural_inertia_payload(m)
    @test length(rows)==length(m.groups)
    @test sum(r["mass_kg"] for r in rows)≈W.weights_payload(m)["totals"]["structure_mass_kg"] rtol=1e-12
    for r in rows
        tensor=reduce(vcat,permutedims.(r["inertia_kg_m2"]))
        @test issymmetric(tensor)
        @test minimum(eigvals(Symmetric(tensor)))>=-1e-9*maximum(abs,tensor)
        @test r["center_of_gravity_m"]==r["reference_m"]
    end
    delta=[10.,-5.,3.]
    for (axis,d) in zip(("x","y","z"),delta)
        p["planform.root_ref_"*axis]=get(p,"planform.root_ref_"*axis,0.)+d
    end
    moved=W.structural_inertia_payload(W.build_model(W.normalize_params(p)[1]))
    @test length(moved)==length(rows)
    for (a,b) in zip(rows,moved)
        @test a["property_id"]==b["property_id"]
        @test a["mass_kg"]≈b["mass_kg"] rtol=1e-11
        @test a["reference_m"]+delta≈b["reference_m"] atol=1e-10
        @test reduce(vcat,a["inertia_kg_m2"])≈reduce(vcat,b["inertia_kg_m2"]) rtol=1e-8 atol=1e-8
    end
end
