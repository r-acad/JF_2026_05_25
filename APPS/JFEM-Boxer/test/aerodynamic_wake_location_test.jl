using Test, WingFEGen
const WL=WingFEGen

@testset "Wake diagnostics identify physical surfaces and stations" begin
    patches=[
        (side="left",element_name="fixed wing",active=Dict{String,Any}[],etas=[.1,.05,0.]),
        (side="right",element_name="fixed wing",active=[Dict("name"=>"Inboard flap")],etas=[.1,.2,.38]),
        (side="right",element_name="control: Inboard flap",active=[Dict("name"=>"Inboard flap")],etas=[.1,.25,.38])]
    text="Wake/body intersection: wake patch 2, filament 1, row 2 crosses body patch 1, chord 3, strip 1"
    result=WL.aerodynamic_wake_error_context(text,patches)
    @test startswith(result,text)
    @test occursin("Right fixed wing beside Inboard flap at eta 0.1 (eta 0.1–0.38)",result)
    @test occursin("Left fixed wing (eta 0.0–0.1)",result)
    @test WL.aerodynamic_wake_error_context(result,patches)==result
    @test WL.aerodynamic_wake_error_context("Nonfinite circulation",patches)=="Nonfinite circulation"
    @test WL.aerodynamic_wake_error_context("Unknown patch 90, filament 2",patches)=="Unknown patch 90, filament 2"
    @test occursin("control: Inboard flap at eta 0.25",WL.aerodynamic_wake_error_context("wake patch 3, filament 2",patches))
    @test occursin("at eta 0.1",WL.aerodynamic_wake_error_context("patch 1, filament 1",patches))
    @test !occursin(" at eta ",WL.aerodynamic_wake_error_context("patch 3, filament 99",patches))
    twice=WL.aerodynamic_wake_error_context("wake patch 2, filament 1; wake patch 2, filament 1",patches)
    @test length(findall("= Right fixed wing",twice))==1
end

@testset "Actual wake failure retains residual and adds physical context" begin
    p=WL.default_params()
    merge!(p,Dict("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012"))
    _,w,controls=WL.aerodynamic_geometry(p)
    s=WL.aerodynamic_settings(Dict("chord_panels"=>2,"span_panels"=>2,
        "chord_spacing"=>"uniform","span_spacing"=>"uniform","alpha"=>5.,
        "wake_model"=>"relaxed","compressibility"=>"incompressible",
        "wake_iterations"=>2,"derivatives"=>false),controls)
    patches=WL.aerodynamic_mesh(w,controls,s)
    error=try
        WL.aerodynamic_solve(w,patches,s)
        nothing
    catch exception
        exception
    end
    @test error isa ArgumentError
    message=sprint(showerror,error)
    @test occursin("did not converge after 2 iterations",message)
    @test occursin("tolerance 0.002",message)
    @test occursin("Aerodynamic mesh locations:",message)
    @test occursin("fixed wing",message)
    @test occursin("eta",message)
end
