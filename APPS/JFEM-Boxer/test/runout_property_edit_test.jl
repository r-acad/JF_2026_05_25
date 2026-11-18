using Test,WingFEGen,LinearAlgebra
const W=WingFEGen
@testset "Shared P13 runout section editing" begin
    p=W.default_params()
    baseline=W.section_definition(p,13)
    @test baseline["type"]=="PBAR"
    @test baseline["area_m2"]==5e-6
    @test baseline["I1_m4"]==baseline["I2_m4"]==5e-6^2/12
    @test baseline["J_m4"]==.1406*5e-6^2
    @test W.property_minimum_gauge(p,13)["at_minimum"]
    original=deepcopy(p)
    edited=deepcopy(p);edited["properties.components"]=[Dict("key"=>"stringer_runout:1","side"=>.003,"material"=>2)]
    edited=first(W.normalize_params(edited))
    section=W.section_definition(edited,13)
    @test section["area_m2"]≈9e-6
    @test section["I1_m4"]≈.003^4/12
    @test section["J_m4"]≈.1406*.003^4
    @test section["offset_y_m"]==0
    @test W.bar_material_definition(edited,13)["id"]==2
    @test !W.property_minimum_gauge(edited,13)["at_minimum"]
    @test W.section_definition(edited,W.PID_STRINGER)==W.section_definition(p,W.PID_STRINGER)
    @test p==original
    saved=W.JSON.parse(W.JSON.json(Dict("parameters"=>edited)))
    loaded=first(W.normalize_params(saved["parameters"]))
    @test W.section_definition(loaded,13)==section
    below=deepcopy(p);below["properties.components"]=[Dict("key"=>"stringer_runout:1","side"=>.002)]
    @test_throws ArgumentError W.normalize_params(below)
    @test_throws ArgumentError W.validate_component_table_bounds(merge(p,Dict("properties.components"=>[Dict("key"=>"stringer_runout:2","side"=>.003)])),10)
    direction=W.sensitivity_analytic_section(section,[1.,1.])
    @test direction.darea≈.006
    @test direction.dI1≈.003^3/3
    @test direction.dJ≈.5624*.003^3
    step=1e-7
    sections=[W.section_definition(merge(edited,Dict("properties.components"=>[Dict("key"=>"stringer_runout:1","side"=>s)])),13) for s in (.003-step,.003+step)]
    @test (sections[2]["J_m4"]-sections[1]["J_m4"])/(2step)≈direction.dJ rtol=1e-8
    E=71e9;G=E/(2*(1+.33))
    K,dK=W.sensitivity_analytic_frame_stiffness(.2,direction,E,G,0.,0.)
    tangent_sections=[W.sensitivity_analytic_section(s) for s in sections]
    Ks=[first(W.sensitivity_analytic_frame_stiffness(.2,s,E,G,0.,0.)) for s in tangent_sections]
    @test norm(dK-(Ks[2]-Ks[1])/(2step))/norm(dK)<1e-8
    @test isinf(direction.As_y)&&isinf(direction.As_z)
    forces=Dict("axial"=>1000.,"shear_1"=>0.,"shear_2"=>0.,"torque"=>0.,"moment_a1"=>0.,"moment_a2"=>0.,"moment_b1"=>0.,"moment_b2"=>0.)
    prop(s)=Dict("TYPE"=>"BAR","DIMS"=>s["dimensions_m"],"A"=>s["area_m2"],"I1"=>s["I1_m4"],"I2"=>s["I2_m4"],"J"=>s["J_m4"])
    base_stress=W.beam_t_stress_envelope(prop(baseline),forces)["von_mises"]
    next_stress=W.beam_t_stress_envelope(prop(section),forces)["von_mises"]
    @test base_stress≈200e6
    @test next_stress≈1000/9e-6
    @test 300e6/(1.5next_stress)≈1.8
end
