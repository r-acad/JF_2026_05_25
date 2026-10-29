using Test,WingFEGen,LinearAlgebra
const TFW=WingFEGen
function trefftz_fixture(n=32;deform=false)
    g=zeros(3,5,n+1);gamma=Float64[]
    for j in 0:n
        y=-4+8j/n
        for i in 1:5
            g[:,i,j+1].=[2(i-1),y+(deform ? .15*(i-1)*sin(pi*y/8) : 0.),deform ? .08*(i-1)^2*(y/4)^2 : 0.]
        end
        j<n&&push!(gamma,sqrt(1-((-4+8(j+.5)/n)/4)^2))
    end
    return [g],[gamma]
end

@testset "Terminal Trefftz integral: classical limit and invariance" begin
    grids,strengths=trefftz_fixture();g=only(grids);gamma=only(strengths)
    cut=TFW.aerodynamic_trefftz_cut(grids,strengths,30.,8.)
    @test cut["valid"]&&cut["CDi"]>0
    # Independent primary-package Trefftz-panel oracle at the terminal cut.
    V=TFW.VortexLattice;panels=[V.TrefftzPanel(V.SVector(0.,g[2,end,j],g[3,end,j]),
        V.SVector(0.,(g[2,end,j]+g[2,end,j+1])/2,(g[3,end,j]+g[3,end,j+1])/2),
        V.SVector(0.,g[2,end,j+1],g[3,end,j+1]),gamma[j]) for j in eachindex(gamma)]
    ref=V.Reference(8.,1.,8.,zeros(3),30.)
    @test cut["CDi"] ≈ V.far_field_drag(panels,panels,ref,false) rtol=1e-13
    @test TFW.aerodynamic_trefftz_cut(grids,[2gamma],30.,8.)["CDi"] ≈ 4cut["CDi"]
    @test TFW.aerodynamic_trefftz_cut(grids,[-gamma],30.,8.)["CDi"] ≈ cut["CDi"]
    @test TFW.aerodynamic_trefftz_cut(grids,strengths,60.,8.)["CDi"] ≈ cut["CDi"]/4
    moved=deepcopy(grids);moved[1][2,:,:].+=123.;moved[1][3,:,:].-=57.
    @test TFW.aerodynamic_trefftz_cut(moved,strengths,30.,8.)["CDi"] ≈ cut["CDi"] rtol=1e-12
    rotated=deepcopy(grids);a=.7
    for i in axes(g,2),j in axes(g,3)
        rotated[1][2,i,j]=cos(a)*g[2,i,j]-sin(a)*g[3,i,j]
        rotated[1][3,i,j]=sin(a)*g[2,i,j]+cos(a)*g[3,i,j]
    end
    @test TFW.aerodynamic_trefftz_cut(rotated,strengths,30.,8.)["CDi"] ≈ cut["CDi"] rtol=1e-12
    split=[copy(g[:,:,1:17]),copy(g[:,:,17:end])];split[2][1,:,:].+=20.
    @test TFW.aerodynamic_trefftz_cut(split,[gamma[1:16],gamma[17:end]],30.,8.)["CDi"] ≈ cut["CDi"] rtol=1e-12
    @test TFW.aerodynamic_relaxed_trefftz(grids,strengths,30.,8.)["relative_cut_change"]<1e-13
    errors=Float64[]
    for n in [32,64,128]
        gs,ss=trefftz_fixture(n);cd=TFW.aerodynamic_trefftz_cut(gs,ss,30.,8.)["CDi"]
        cl=2sum(only(ss))*(8/n)/(30*8);e=TFW.inviscid_span_efficiency(cl,cd,8.)
        push!(errors,abs(e-1))
    end
    @test errors[3]<errors[2]<errors[1]
    @test errors[3]<.007
end

@testset "Rolled cross-section, zero loading and singular-cut guards" begin
    grids,strengths=trefftz_fixture(;deform=true)
    info=TFW.aerodynamic_relaxed_trefftz(grids,strengths,30.,8.)
    rigid=TFW.aerodynamic_relaxed_trefftz(trefftz_fixture()...,30.,8.)
    @test info["valid"]&&info["CDi"]>0
    @test !isapprox(info["CDi"],rigid["CDi"];rtol=1e-3)
    @test info["relative_cut_change"]>0
    @test occursin("hypothetical",info["sensitivity_note"])
    zero_cut=TFW.aerodynamic_trefftz_cut(grids,[zero(only(strengths))],30.,8.)
    @test zero_cut["CDi"]==0.
    @test TFW.inviscid_span_efficiency(0.,zero_cut["CDi"],8.)===nothing
    collapsed=deepcopy(grids);collapsed[1][2:3,end,2].=collapsed[1][2:3,end,1]
    @test !TFW.aerodynamic_trefftz_cut(collapsed,strengths,30.,8.)["valid"]
    @test TFW.aerodynamic_trefftz_cut(collapsed,strengths,30.,8.)["CDi"]===nothing
    # A second strip has its filament at the first strip's midpoint.
    a=zeros(3,3,2);a[1,2,:].=1.;a[1,3,:].=2.;a[2,:,2].=2.
    b=copy(a);b[2,:,1].=1.;b[2,:,2].=3.
    singular=TFW.aerodynamic_trefftz_cut([a,b],[[1.],[1.]],30.,8.)
    @test !singular["valid"]&&singular["CDi"]===nothing
    @test occursin("midpoint",singular["reason"])
end

@testset "Solved free-wake drag, efficiency and derivative integration" begin
    p=TFW.default_params();merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","movable_surfaces.items"=>Any[]))
    settings=Dict{String,Any}("wake_model"=>"relaxed","compressibility"=>"incompressible",
        "chord_spacing"=>"uniform","chord_panels"=>2,"span_panels"=>4,"speed"=>30.,"alpha"=>3.,
        "wake_length"=>1.5,"wake_rows"=>8,"wake_iterations"=>200,"derivatives"=>true)
    _,w,controls=TFW.aerodynamic_geometry(p);s=TFW.aerodynamic_settings(settings,controls);patches=TFW.aerodynamic_mesh(w,controls,s)
    rigid=TFW.aerodynamic_solve(w,patches,merge(s,Dict("wake_model"=>"straight")))
    fixed=TFW.aerodynamic_solve(w,patches,s;frozen_wake=true)
    @test fixed["CDi_trefftz"] ≈ rigid["CDi_trefftz"] rtol=1e-10
    @test fixed["span_efficiency"] ≈ rigid["span_efficiency"] rtol=1e-10
    for policy in ["frozen","relaxed"]
        result=TFW.run_aerodynamic_study(p,merge(settings,Dict("wake_derivatives"=>policy)));c=only(result["cases"])
        @test c["CDi_trefftz"]>0&&c["trefftz"]["valid"]
        cl=c["coefficients"]["wind"]["force"][3]
        @test c["span_efficiency"] ≈ cl^2/(pi*(c["span_m"]^2/c["area_m2"])*c["CDi_trefftz"])
        @test c["wake"]["trefftz"]===c["trefftz"]
        @test all(d["CDi_trefftz"] isa Real&&isfinite(d["CDi_trefftz"]) for d in c["derivatives"]["rows"])
        @test all(d["span_efficiency"] isa Real&&isfinite(d["span_efficiency"]) for d in c["derivatives"]["rows"])
        speed_derivative=only(filter(d->d["variable"]=="speed",c["derivatives"]["rows"]))
        @test abs(speed_derivative["CDi_trefftz"])<1e-8
        @test abs(speed_derivative["span_efficiency"])<1e-6
    end
end
