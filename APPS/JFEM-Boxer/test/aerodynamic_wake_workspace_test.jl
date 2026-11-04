using Test, WingFEGen, LinearAlgebra
const WW=WingFEGen
const WWV=WW.VortexLattice

function wake_workspace_fixture(nc,ns,rows)
    grid=zeros(3,nc+1,ns+1)
    for j in 1:ns+1,i in 1:nc+1
        grid[:,i,j].=((i-1)/nc,4(j-1)/ns,.01sinpi((i-1)/nc))
    end
    ratios=[zeros(2,nc,ns).+[.5,.75]]
    system=WWV.System([grid];ratios)
    WWV.update_surface_panels!(only(system.surfaces),grid;ratios=only(ratios),fcore=(c,ds)->.02)
    system.Γ.=sin.(eachindex(system.Γ)).*.03
    te=WWV.trailing_edge_points(only(system.surfaces));wake=zeros(3,rows+1,length(te))
    for j in eachindex(te),i in 0:rows
        wake[:,i+1,j].=te[j].+WWV.SVector(4(i/rows)^2,0.,0.)
    end
    strengths=[[system.Γ[nc*j] for j in 1:ns]]
    (;system,grids=[wake],strengths,core=.02)
end

@testset "Prepared wake geometry preserves current circulation and exact field" begin
    for (nc,ns,rows) in ((3,6,8),(6,24,24))
        f=wake_workspace_fixture(nc,ns,rows);system=f.system
        original=deepcopy(f.grids);bound_data=WW.aerodynamic_bound_filament_data(system)
        for streamwise in (false,true)
            direct=WW.aerodynamic_wake_filaments(system,f.grids,f.strengths;streamwise)
            cached=WW.aerodynamic_wake_filaments(system,f.grids,f.strengths;streamwise,bound_data)
            @test cached==direct
        end
        # Geometry is reusable; strengths must always follow the latest solve.
        system.Γ.=cos.(eachindex(system.Γ)).*.02
        strengths=[[system.Γ[nc*j] for j in 1:ns]]
        @test WW.aerodynamic_wake_filaments(system,f.grids,strengths;bound_data)==
              WW.aerodynamic_wake_filaments(system,f.grids,strengths)
        closed=similar(system.AIC)
        WW.aerodynamic_bound_influence!(closed,system,f.core)
        prepared=similar(closed)
        WW.aerodynamic_bound_influence!(prepared,system,f.core;bound_cores=bound_data.cores)
        @test prepared==closed
        @test WW.aerodynamic_bound_core_range(system,f.core;bound_cores=bound_data.cores)==
              WW.aerodynamic_bound_core_range(system,f.core)

        rhs=fill(-1.,length(system.Γ))
        reference=WW.aerodynamic_coupled_wake!(system,f.grids,closed,rhs,f.core)
        aic=copy(system.AIC);gamma=copy(system.Γ)
        for _ in 1:3
            cached=WW.aerodynamic_coupled_wake!(system,f.grids,closed,rhs,f.core;bound_data,threaded=true)
            @test cached==reference
            @test system.AIC==aic
            @test system.Γ==gamma
        end
        # The larger fixture crosses the threaded AIC work threshold.
        @test (length(gamma)*rows*ns>=32768)==(nc==6)
        strengths=reference[2]
        known(q)=WWV.SVector(.001q[2],.002q[1],.1)
        diagnostics=Dict{String,Any}()
        direct=WW.aerodynamic_wake_targets(system,f.grids,strengths,known,20.,f.core;diagnostics)
        for threaded in (false,true),local_target in (false,true)
            before=Dict{String,Any}()
            expected=WW.aerodynamic_wake_targets(system,f.grids,strengths,known,20.,f.core;diagnostics=before,local_target)
            after=Dict{String,Any}()
            actual=WW.aerodynamic_wake_targets(system,f.grids,strengths,known,20.,f.core;diagnostics=after,local_target,threaded,bound_data)
            @test actual==expected
            @test after==before
        end
        ref=WWV.Reference(4.,1.,4.,[0.,0.,0.],20.)
        WW.aerodynamic_wake_properties!(system,ref,known,f.grids,strengths,20.,f.core)
        properties=deepcopy(system.properties)
        @test system.near_field_analysis[]
        WW.aerodynamic_wake_properties!(system,ref,known,f.grids,strengths,20.,f.core;bound_data)
        @test system.properties==properties
        WW.aerodynamic_wake_properties!(system,ref,known,f.grids,strengths,20.,f.core;bound_data,velocity_only=true)
        @test !system.near_field_analysis[]
        @test !system.derivatives[]
        for (full,lean) in zip(only(properties),only(system.properties))
            @test lean.gamma==full.gamma
            @test lean.velocity==full.velocity
            @test iszero(lean.cfb)&&iszero(lean.cfl)&&iszero(lean.cfr)&&iszero(lean.velocity_from_streamwise)
        end
        @test f.grids==original
    end
end
