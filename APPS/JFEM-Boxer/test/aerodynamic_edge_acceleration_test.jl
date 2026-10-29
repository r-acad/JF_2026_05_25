using Test, WingFEGen, LinearAlgebra
const EA=WingFEGen

@testset "Bounded edge grading" begin
    for cosine_chord in (false,true)
        t=collect(range(0.,1.;length=41))
        x=EA.aerodynamic_span_fraction.(t,"cosine";cosine_chord)
        @test first(x)==0. && last(x)==1.
        @test all(diff(x).>0)
        @test x+reverse(x) ≈ ones(length(x))
        @test first(diff(x)) < diff(x)[20]
        @test last(diff(x)) < diff(x)[20]
        @test EA.aerodynamic_span_fraction.(t,"uniform";cosine_chord)==t
    end
    p=EA.default_params();merge!(p,Dict("planform.area"=>8.,"planform.aspect_ratio"=>8.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012"))
    _,w,rows=EA.aerodynamic_geometry(p)
    for spacing in ("cosine","uniform")
        s=EA.aerodynamic_settings(Dict("chord_panels"=>4,"span_panels"=>8,
            "chord_spacing"=>spacing,"derivatives"=>false),rows)
        patches=EA.aerodynamic_mesh(w,rows,s)
        for patch in patches
            d=abs.(diff(patch.etas))
            @test first(d)<maximum(d) && last(d)<maximum(d)
            @test maximum(last(EA.aerodynamic_aspect(m)) for m in patch.metrics)<=1.5+1e-8
            spacing=="uniform" && @test minimum(first(EA.aerodynamic_aspect(m)) for m in patch.metrics)>=.7-1e-8
        end
    end
end

@testset "Bounded Anderson acceleration preserves the fixed point" begin
    states=Vector{Float64}[];residuals=Vector{Float64}[]
    matrix=[.95 0.;0. .9];x=[1.,-.7];plain=copy(x)
    for iteration in 1:100
        f=matrix*x-x
        step=EA.aerodynamic_anderson_step!(states,residuals,x,f,.1)
        @test all(isfinite,step)
        @test maximum(abs,step)<=5maximum(abs,f)+1e-12
        x+=step;plain+=.1*(matrix*plain-plain)
    end
    @test norm(matrix*x-x)<1e-8
    @test norm(matrix*plain-plain)>.01
    @test length(states)<=7 && length(states)==length(residuals)
    p=EA.default_params();_,_,rows=EA.aerodynamic_geometry(p)
    @test_throws ArgumentError EA.aerodynamic_settings(Dict("wake_acceleration"=>"invalid"),rows)
end
