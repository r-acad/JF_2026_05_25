using Test,WingFEGen
const RW=WingFEGen
const RV=RW.VortexLattice

function recovery_work_fixture()
    p=RW.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>9.,"planform.dihedral"=>4.,"planform.twist_tip"=>-2.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","movable_surfaces.items"=>Any[]))
    p
end
recovery_work_settings(extra=Dict{String,Any}())=merge(Dict{String,Any}(
    "chord_spacing"=>"uniform","span_spacing"=>"uniform","chord_panels"=>2,"span_panels"=>4,
    "speed"=>30.,"atmosphere"=>"manual","density"=>1.225,"speed_of_sound"=>340.,
    "compressibility"=>"incompressible","alpha"=>4.,"beta"=>2.,"p"=>.3,"q"=>-.1,"r"=>.2),extra)

@testset "Straight velocity-only recovery matches the complete package field" begin
    # Two noncoplanar patches with different surface IDs exercise both native
    # self-edge exclusion and finite-core interactions with another surface.
    grids=map([0.,1.7]) do shift
        g=zeros(3,3,4)
        for j in axes(g,3),i in axes(g,2)
            x=[0.,.4,1.][i];y=[0.,.3,.8,1.2][j]+shift
            g[:,i,j].=(x+.13y,y,.07x+.04y+.02x*y)
        end
        g
    end
    function system()
        value=RV.System(grids)
        for (surface,grid) in zip(value.surfaces,grids)
            RV.update_surface_panels!(surface,grid;fcore=(c,ds)->.02)
        end
        value.Γ.=range(.2,1.4;length=length(value.Γ))
        value.surface_id.=[1,2];value.trailing_vortices.=true
        value
    end
    for omega in ([0.,0.,0.],[.02,-.01,.03])
        complete=system();velocity_only=system()
        ref=RV.Reference(8.,1.,8.,[.1,.2,.3],30.)
        fs=RV.Freestream(30.,.07,-.03,omega)
        known(x)=RV.SVector(.01x[2],-.02x[3],.015x[1])
        RV.near_field_forces!(complete.properties,complete.surfaces,complete.wakes,ref,fs,complete.Γ;
            dΓdt=nothing,additional_velocity=known,Vh=nothing,Vv=nothing,symmetric=complete.symmetric,
            nwake=complete.nwake,surface_id=complete.surface_id,wake_finite_core=complete.wake_finite_core,
            wake_shedding_locations=nothing,trailing_vortices=complete.trailing_vortices,xhat=complete.xhat[])
        RW.aerodynamic_straight_velocities!(velocity_only,ref,fs,known)
        for k in eachindex(complete.properties),i in eachindex(complete.properties[k])
            @test velocity_only.properties[k][i].velocity==complete.properties[k][i].velocity
            @test velocity_only.properties[k][i].gamma==complete.properties[k][i].gamma
        end
        @test !velocity_only.near_field_analysis[]
        @test !velocity_only.derivatives[]
    end
end

@testset "Coefficient-only probes retain complete physical coefficients" begin
    p=recovery_work_fixture();_,w,controls=RW.aerodynamic_geometry(p)
    for extra in (Dict{String,Any}(),Dict{String,Any}("compressibility"=>"prandtl_glauert","speed"=>70.))
        s=RW.aerodynamic_settings(recovery_work_settings(extra),controls)
        mesh=RW.aerodynamic_mesh(w,controls,s)
        full=RW.aerodynamic_solve(w,mesh,s)
        compact=RW.aerodynamic_solve(w,mesh,s;coefficients_only=true,geometry_interference=full["geometry_interference"])
        @test Set(keys(compact))==Set(["flight","coefficients","CDi_trefftz","span_efficiency"])
        @test compact["coefficients"]==full["coefficients"]
        @test compact["CDi_trefftz"]==full["CDi_trefftz"]
        @test compact["span_efficiency"]==full["span_efficiency"]
        @test compact["flight"]==full["flight"]
    end
end

@testset "Explicit derivative work and inactive manual altitude" begin
    p=recovery_work_fixture();raw=recovery_work_settings()
    defaults=RW.aerodynamic_settings(raw,Any[])
    @test !defaults["derivatives"]
    single=RW.run_aerodynamic_study(p,raw)
    @test single["work"]["base_solves"]==1
    @test single["work"]["derivative_solves"]==0
    @test !haskey(only(single["cases"]),"derivatives")
    derived=RW.run_aerodynamic_study(p,merge(raw,Dict("derivatives"=>true)))
    @test derived["settings"]["derivatives"]
    @test derived["work"]["base_solves"]==1
    @test derived["work"]["derivative_variables"]==7
    @test derived["work"]["derivative_solves"]==12
    @test derived["work"]["inactive_derivative_reuses"]==2
    @test derived["work"]["derivative_base_reuses"]==0
    altitude=only(filter(row->row["variable"]=="altitude",only(derived["cases"])["derivatives"]["rows"]))
    for frame in values(altitude["coefficients"]),kind in ("force","force_components","moment")
        @test all(iszero,frame[kind])
    end
    @test iszero(altitude["CDi_trefftz"])
    @test iszero(altitude["span_efficiency"])
    # At a one-sided angle/speed bound, use the solved center rather than
    # recomputing it. The two inactive manual-altitude probes remain reused.
    bound=RW.run_aerodynamic_study(p,merge(raw,Dict("derivatives"=>true,"alpha"=>30.,"speed"=>170.)))
    @test bound["work"]["derivative_solves"]==10
    @test bound["work"]["derivative_base_reuses"]==2
    @test bound["work"]["inactive_derivative_reuses"]==2
    sweep=RW.run_aerodynamic_study(p,merge(raw,Dict("mode"=>"sweep","sweeps"=>[
        Dict("variable"=>"alpha","start"=>1.,"stop"=>3.,"count"=>3)])))
    @test sweep["work"]["base_solves"]==3
    @test sweep["work"]["derivative_solves"]==0
    @test sweep["work"]["mesh_builds"]==1
    @test all(!haskey(c,"derivatives") for c in sweep["cases"])
    @test all(sweep["work"][key]>=0 for key in ("mesh_seconds","base_solve_seconds","derivative_seconds","total_seconds"))
end
