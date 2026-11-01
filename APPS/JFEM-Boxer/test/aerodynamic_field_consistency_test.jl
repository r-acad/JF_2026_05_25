using WingFEGen,Test,LinearAlgebra
const FC=WingFEGen
const FVL=FC.VortexLattice

function field_fixture()
    grid=zeros(3,3,4)
    # Sweep, twist and translation prevent accidental axis-aligned host tests.
    for j in 1:4,i in 1:3
        x=[.13,.71,1.83][i];y=[-.72,-.1,.8,1.31][j]
        grid[:,i,j].=(x+.17y+2.3,y-.8,.081x+.193y+.037x*y+.41)
    end
    system=FVL.System([grid]);surface=only(system.surfaces)
    FVL.update_surface_panels!(surface,grid)
    gamma=[1.2,.8,.72,.31,1.17,.63];system.Γ.=gamma
    te=FVL.trailing_edge_points(surface);wake=zeros(3,5,length(te))
    for j in eachindex(te),i in 1:5
        x=[0.,.2,.8,2.,5.][i]
        wake[:,i,j].=te[j]+[x,.02x,-.07x/(1+x)]
    end
    system,[wake],[[gamma[2],gamma[4],gamma[6]]]
end

@testset "One finite-core field satisfies its solved body boundary condition" begin
    system,grids,_=field_fixture();speed=20.;core=.08
    known(x)=FVL.SVector(.01x[2],-.02x[3],.015x[1])
    prescribed(x)=FVL.SVector(speed,0.,0.)+known(x)
    rhs=[-dot(prescribed(FVL.controlpoint(p)),FVL.normal(p)) for surface in system.surfaces for p in surface]
    closed=similar(system.AIC);FC.aerodynamic_bound_influence!(closed,system,core)
    _,strengths=FC.aerodynamic_coupled_wake!(system,grids,closed,rhs,core)
    segments,rays=FC.aerodynamic_wake_filaments(system,grids,strengths)
    # A second path evaluates merged physical filaments, not matrix entries.
    residual=[dot(prescribed(FVL.controlpoint(p))+FC.aerodynamic_wake_velocity(FVL.controlpoint(p),segments,rays,core),FVL.normal(p)) for surface in system.surfaces for p in surface]
    @test maximum(abs,residual)/speed<1e-12
    @test maximum(abs,residual-(system.AIC*system.Γ-rhs))/speed<1e-12
    ref=FVL.Reference(3.,1.,3.,[0.,0.,0.],speed)
    FC.aerodynamic_wake_properties!(system,ref,known,grids,strengths,speed,core)
    for (surface,properties) in zip(system.surfaces,system.properties),index in CartesianIndices(surface)
        p=surface[index];x=FVL.top_center(p)
        expected=prescribed(x)+FC.aerodynamic_wake_velocity(x,segments,rays,core;host=(p.rtl,p.rtr))
        @test properties[index].velocity*speed≈expected atol=2e-13
        @test all(isfinite,properties[index].cfb)
    end
end

@testset "Trailing-edge cancellation and host force recovery have the classical limit" begin
    system,grids,strengths=field_fixture();surface=only(system.surfaces)
    panels=only(FC.aerodynamic_wake_panels(grids,strengths,.02))
    segments,rays=FC.aerodynamic_wake_filaments(system,grids,strengths)
    points=[FVL.SVector(3.2,-.49,1.11),FVL.SVector(4.4,-1.18,.58),FVL.SVector(9.3,-.3,-.39)]
    for point in points
        reference=FVL.induced_velocity(point,surface,system.Γ;finite_core=false,trailing_vortices=false)+FVL.induced_velocity(point,panels;finite_core=false,trailing_vortices=true)
        @test FC.aerodynamic_wake_velocity(point,segments,rays,0.)≈reference atol=2e-12
        @test FC.aerodynamic_wake_velocity(point,segments,rays,1e-7)≈reference atol=2e-12
    end
    for index in CartesianIndices(surface)
        p=surface[index];point=FVL.top_center(p)
        reference=FVL.induced_velocity(index,surface,system.Γ;finite_core=false,trailing_vortices=false)+FVL.induced_velocity(point,panels;finite_core=false,trailing_vortices=true)
        actual=FC.aerodynamic_wake_velocity(point,segments,rays,0.;host=(p.rtl,p.rtr))
        @test actual≈reference atol=2e-12
        # Canonical edge merging may reverse endpoint order.
        @test actual==FC.aerodynamic_wake_velocity(point,segments,rays,0.;host=(p.rtr,p.rtl))
        @test all(isfinite,actual)
    end
end

@testset "Bound-edge cores follow local resolution and preserve cancellations" begin
    system,grids,strengths=field_fixture();surface=only(system.surfaces)
    fine=FC.aerodynamic_bound_core_map(system;fraction=.025)
    nominal=FC.aerodynamic_bound_core_map(system;fraction=.05)
    @test Set(keys(fine))==Set(keys(nominal))
    @test all(fine[k]≈.5nominal[k] for k in keys(nominal))
    @test all(isfinite(r)&&r>0 for r in values(nominal))
    @test length(nominal)<4length(surface)
    # The shared chord-row edge is one geometric filament, even with different
    # collocation distances on its two incident panels.
    a,b=surface[1,2].rbr,surface[1,2].rbl
    key=FC.aerodynamic_edge_key(a,b)
    @test key==FC.aerodynamic_edge_key(surface[2,2].rtl,surface[2,2].rtr)
    dist(p)=begin
        x=FVL.controlpoint(p);e=b-a
        norm(x-(a+clamp(dot(x-a,e)/sum(abs2,e),0.,1.)*e))
    end
    @test nominal[key]≈min(.5norm(b-a),.05dist(surface[1,2]),.05dist(surface[2,2]))
    segments,_=FC.aerodynamic_wake_filaments(system,grids,strengths)
    terminal=Set(FC.aerodynamic_edge_key(p.rbr,p.rbl) for p in surface[end,:])
    @test all(!(FC.aerodynamic_edge_key(s[1],s[2]) in terminal) for s in segments)
    @test any(isfinite(s[4]) for s in segments)
    @test any(isinf(s[4]) for s in segments)
    @test_throws ArgumentError FC.aerodynamic_bound_core_map(system;fraction=0.)
    @test_throws ArgumentError FC.aerodynamic_bound_core_map(system;fraction=NaN)
end
