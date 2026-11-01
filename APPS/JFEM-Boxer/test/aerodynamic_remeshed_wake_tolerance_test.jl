using Test, WingFEGen, LinearAlgebra
const RWT=WingFEGen
struct RemeshedWakeToleranceObserved <: Exception end

@testset "Neutral control remeshing uses the reported relaxed derivative tolerance" begin
    p=RWT.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012"))
    p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Offset flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>0.,"eta_end"=>1.,"front_spar_start"=>.7,"front_spar_end"=>.7,
        "hinge_start"=>.8,"hinge_end"=>.8,"hinge_z_start"=>-.5,"hinge_z_end"=>-.5,
        "deflection"=>0.,"color"=>"#ffcc00")]
    _,w,controls=RWT.aerodynamic_geometry(p)
    s=RWT.aerodynamic_settings(Dict{String,Any}("compressibility"=>"incompressible",
        "wake_model"=>"relaxed","wake_derivatives"=>"relaxed","wake_length"=>.5,
        "wake_rows"=>4,"wake_iterations"=>300,"wake_tolerance"=>.002,"wake_core"=>.12,
        "wake_relaxation"=>.25,"chord_spacing"=>"uniform","span_spacing"=>"uniform",
        "chord_panels"=>2,"span_panels"=>4,"control_chord_panels"=>1,
        "derivatives"=>false,"speed"=>30.,"alpha"=>0.),controls)
    mesh=RWT.aerodynamic_mesh(w,controls,s)
    base=RWT.aerodynamic_solve(w,mesh,s)
    active=Ref("");control_tolerances=Float64[]
    function progress(stage,done,total)
        variable=match(r"^Computing derivatives: (.+) \(",stage)
        variable===nothing||(active[]=variable.captures[1])
        if active[]=="control:Offset flap"
            iteration=match(r"^Free wake iteration .* / ([0-9.eE+-]+) \(tangent",stage)
            if iteration!==nothing
                push!(control_tolerances,parse(Float64,iteration.captures[1]))
                # Stop after observing the actual kernel setting. This test
                # checks policy propagation, not convergence of a tiny slot.
                throw(RemeshedWakeToleranceObserved())
            end
        end
    end
    @test RWT.aerodynamic_control_gap(w,only(controls))
    @test all(q.element_name=="fixed wing" for q in mesh)
    @test_throws RemeshedWakeToleranceObserved RWT.aerodynamic_derivatives(w,controls,mesh,s,base;progress)
    # Read the real wake iteration's requested tolerance, not only metadata.
    @test !isempty(control_tolerances)
    @test all(==(min(s["wake_tolerance"],1e-5)),control_tolerances)
    @test base["wake"]["tolerance"]==.002
end
