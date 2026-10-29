using Test,WingFEGen,LinearAlgebra
const FW=WingFEGen
function free_wake_fixture()
    p=FW.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "movable_surfaces.items"=>Any[]))
    p
end
free_wake_settings(;kw...)=merge(Dict{String,Any}("compressibility"=>"incompressible",
    "wake_model"=>"relaxed","wake_length"=>1.5,"wake_rows"=>12,"wake_iterations"=>100,
    "chord_spacing"=>"uniform","chord_panels"=>3,"span_panels"=>8,
    "derivatives"=>false,"speed"=>30.,"alpha"=>5.),Dict(String(k)=>v for (k,v) in kw))

@testset "Regularized convection kernel and steady wake guards" begin
    V=FW.VortexLattice.SVector
    a=V(0.,0.,0.);b=V(0.,1.,0.);point=V(.3,.4,.7);core=.02
    # Independent quadrature of the softened Biot-Savart integral.
    n=2000;ds=(b-a)/n;quad=zero(point)
    for i in 1:n
        r=point-(a+(i-.5)*ds)
        quad+=cross(ds,r)/(sum(abs2,r)+core^2)^1.5/(4pi)
    end
    @test FW.aerodynamic_core_segment(point,a,b,1.,core) ≈ quad rtol=1e-7
    @test FW.aerodynamic_core_segment((a+b)/2,a,b,1.,core)==zero(point)
    @test all(isfinite,FW.aerodynamic_core_segment(a,a,b,1.,core))
    @test FW.aerodynamic_core_segment(point,a,b,1.,1e-7) ≈ FW.VortexLattice.bound_induced_velocity(point-a,point-b,false,0.) rtol=1e-10
    @test all(isfinite,FW.aerodynamic_core_tail(a,a,1.,core))
    p=free_wake_fixture();_,_,rows=FW.aerodynamic_geometry(p)
    @test_throws ArgumentError FW.aerodynamic_settings(Dict("wake_model"=>"relaxed"),rows)
    @test_throws ArgumentError FW.aerodynamic_settings(free_wake_settings(wake_rows=0),rows)
    @test_throws ArgumentError FW.aerodynamic_settings(free_wake_settings(wake_core=0),rows)
end

@testset "Circulation-coupled straight limit and rolled-up steady solution" begin
    p=free_wake_fixture();_,w,rows=FW.aerodynamic_geometry(p)
    s=FW.aerodynamic_settings(free_wake_settings(),rows);patches=FW.aerodynamic_mesh(w,rows,s)
    rigid=FW.aerodynamic_solve(w,patches,merge(s,Dict("wake_model"=>"straight")))
    fixed=FW.aerodynamic_solve(w,patches,s;frozen_wake=true)
    @test fixed["force_N"] ≈ rigid["force_N"] rtol=1e-9 atol=1e-9
    @test fixed["moment_Nm"] ≈ rigid["moment_Nm"] rtol=1e-9 atol=1e-9
    zero_case=only(FW.run_aerodynamic_study(p,free_wake_settings(alpha=0.))["cases"])
    @test norm(zero_case["force_N"])<1e-10
    @test zero_case["wake"]["converged"]
    @test zero_case["wake"]["iterations"]==1
    c=only(FW.run_aerodynamic_study(p,s)["cases"]);wake=c["wake"]
    @test wake["converged"]&&wake["residual"]<=s["wake_tolerance"]
    @test c["residual_over_V"]<1e-10
    @test c["CDi_trefftz"]>0&&c["span_efficiency"]>0
    @test c["coefficients"]["wind"]["force"][3]>0
    @test abs(c["force_N"][2])<1e-8*norm(c["force_N"])
    @test norm(c["force_N"]-rigid["force_N"])>1e-4
    for sheet in wake["sheets"]
        patch=patches[sheet["patch"]]
        for (j,line) in enumerate(sheet["lines"])
            @test line[1] ≈ patch.grid[:,end,j]
            @test all(all(isfinite,point) for point in line)
        end
        for j in eachindex(sheet["circulation_m2_s"])
            panels=filter(p->p["patch"]==sheet["patch"]&&p["strip"]==j,c["panels"])
            @test sheet["circulation_m2_s"][j] ≈ panels[argmax(p["chord"] for p in panels)]["circulation_m2_s"]
        end
    end
    lines=vcat([sheet["lines"] for sheet in wake["sheets"]]...)
    @test maximum(norm(cross(line[end]-line[1],line[2]-line[1])) for line in lines)>1e-4
    # Mirror the entire computed line, not just the load resultant.
    for line in lines
        mirror=[[v[1],-v[2],v[3]] for v in line]
        @test minimum(maximum(norm(a-b) for (a,b) in zip(mirror,other)) for other in lines)<1e-7
    end
    longer=only(FW.run_aerodynamic_study(p,free_wake_settings(wake_length=3.,wake_rows=24))["cases"])
    @test longer["coefficients"]["wind"]["force"][3] ≈ c["coefficients"]["wind"]["force"][3] rtol=.03
    @test_throws ArgumentError FW.run_aerodynamic_study(p,free_wake_settings(wake_iterations=2,wake_tolerance=1e-5))
end

@testset "Frozen wake derivatives and independent sweep cases" begin
    p=free_wake_fixture()
    r=FW.run_aerodynamic_study(p,free_wake_settings(derivatives=true,alpha=3.,span_panels=4,chord_panels=2,wake_rows=8))
    c=only(r["cases"])
    @test c["derivatives"]["wake_policy"]=="frozen"
    @test occursin("geometry frozen",c["derivatives"]["method"])
    @test length(c["derivatives"]["rows"])==7
    alpha=only(filter(d->d["variable"]=="alpha",c["derivatives"]["rows"]))
    @test alpha["coefficients"]["wind"]["force"][3]>0
    @test all(all(isfinite,d["coefficients"]["wind"]["force"]) for d in c["derivatives"]["rows"])
    swept=FW.run_aerodynamic_study(p,free_wake_settings(mode="sweep",sweeps=[Dict("variable"=>"alpha","start"=>2.,"stop"=>4.,"count"=>2)],span_panels=4,chord_panels=2,wake_rows=8))
    @test length(swept["cases"])==2
    @test all(c["wake"]["converged"] for c in swept["cases"])
    @test swept["cases"][1]["coefficients"]["wind"]["force"][3]<swept["cases"][2]["coefficients"]["wind"]["force"][3]
    relaxed=only(FW.run_aerodynamic_study(p,free_wake_settings(derivatives=true,
        wake_derivatives="relaxed",alpha=3.,span_panels=4,chord_panels=2,wake_rows=8,
        wake_iterations=200))["cases"])
    @test relaxed["derivatives"]["wake_policy"]=="relaxed"
    @test relaxed["derivatives"]["wake_tolerance"]==1e-5
    @test all(all(isfinite,d["coefficients"]["wind"]["force"]) for d in relaxed["derivatives"]["rows"])
    dalpha=only(filter(d->d["variable"]=="alpha",relaxed["derivatives"]["rows"]))
    @test dalpha["coefficients"]["wind"]["force"][3]>0
end

@testset "Sideslip reflection and deflected-control free wakes" begin
    p=free_wake_fixture();p["planform.dihedral"]=5.
    settings=free_wake_settings(chord_panels=2,span_panels=4,wake_rows=8,alpha=3.)
    plus=only(FW.run_aerodynamic_study(p,merge(settings,Dict("beta"=>3.)))["cases"])
    minus=only(FW.run_aerodynamic_study(p,merge(settings,Dict("beta"=>-3.)))["cases"])
    @test plus["force_N"] ≈ minus["force_N"].*[1,-1,1] rtol=1e-7 atol=1e-7
    @test plus["moment_Nm"] ≈ minus["moment_Nm"].*[-1,1,-1] rtol=1e-7 atol=1e-7
    @test abs(plus["force_N"][2])>1e-4
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>.25,"eta_end"=>.75,"hinge_start"=>.75,"hinge_end"=>.75,
        "deflection"=>6.,"color"=>"#ffcc00")]
    # Refined edge grids use the same smoother starting preset as the UI.
    smooth=merge(settings,Dict("wake_length"=>.5,"wake_rows"=>16,"wake_iterations"=>300,"wake_core"=>.12,"wake_relaxation"=>.1))
    controlled=only(FW.run_aerodynamic_study(p,smooth)["cases"])
    @test controlled["wake"]["converged"]
    @test controlled["condition"]["controls"]["Flap"]["right"]==6.
    @test controlled["residual_over_V"]<1e-9
end
