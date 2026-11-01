using Test,WingFEGen,LinearAlgebra
const VI=WingFEGen
const VIVL=VI.VortexLattice

function interface_patch(xs,etas;side="right",element_name="fixed wing",offset=0.)
    es=side=="left" ? reverse(etas) : etas
    grid=Array{Float64}(undef,3,length(xs),length(es))
    for (j,e) in enumerate(es),(i,x) in enumerate(xs)
        grid[:,i,j]=[x+.2*e,(side=="left" ? -1 : 1)*e,.03sinpi(x)+.1*e+offset]
    end
    (grid=grid,etas=es,chord_coordinates=repeat(xs,1,length(es)),side=side,element_name=element_name)
end
interface_surfaces(patches;grids=[p.grid for p in patches])=[last(VIVL.grid_to_surface_panels(g)) for g in grids]
function interface_vertex(s,i,j)
    nc,ns=size(s)
    i<=nc ? (j==1 ? s[i,1].rtl : s[i,ns].rtr) : (j==1 ? s[nc,1].rbl : s[nc,ns].rbr)
end

@testset "Physical trailing edges make shared bound vortices conform" begin
    patches=[interface_patch([0.,.25,.5,.75,1.],[0.,.25,.5]),interface_patch([0.,.25,.5,.75],[.5,.75,1.])]
    surfaces=interface_surfaces(patches);old=deepcopy(surfaces);physical=deepcopy([p.grid for p in patches])
    @test norm(interface_vertex(surfaces[1],4,3)-interface_vertex(surfaces[2],4,1))>.06
    report=VI.aerodynamic_conform_vortex_interfaces!(surfaces,patches)
    @test report["corrected_vertices"]==report["corrected_vertex_instances"]==1
    @test report["updated_panels"]==2
    @test report["maximum_gap_before_m"]>.06
    @test report["maximum_gap_after_m"]==0.
    @test interface_vertex(surfaces[1],4,3)==interface_vertex(surfaces[2],4,1)==patches[2].grid[:,4,1]
    @test [p.grid for p in patches]==physical
    for (before,after) in zip(old,surfaces),i in eachindex(before)
        a,b=before[i],after[i]
        @test (a.rcp,a.ncp,a.chord,a.core_size)==(b.rcp,b.ncp,b.chord,b.core_size)
        @test b.rtc==(b.rtl+b.rtr)/2
        @test b.rbc==(b.rbl+b.rbr)/2
    end
    for (k,s) in enumerate(surfaces),j in axes(s,2)
        @test s[end,j].rbl==old[k][end,j].rbl
        @test s[end,j].rbr==old[k][end,j].rbr
    end
    # Both incident rings must use the same corrected boundary vertex.
    @test surfaces[1][3,2].rbr==surfaces[1][4,2].rtr
    @test VI.aerodynamic_conform_vortex_interfaces!(surfaces,patches)["corrected_vertices"]==0
end

@testset "Reflection and solver-coordinate transforms preserve topology" begin
    right=[interface_patch([0.,.25,.5,.75,1.],[0.,.25,.5]),interface_patch([0.,.25,.5,.75],[.5,.75,1.])]
    left=[interface_patch([0.,.25,.5,.75,1.],[0.,.25,.5];side="left"),interface_patch([0.,.25,.5,.75],[.5,.75,1.];side="left")]
    sr=interface_surfaces(right);sl=interface_surfaces(left)
    rr=VI.aerodynamic_conform_vortex_interfaces!(sr,right);rl=VI.aerodynamic_conform_vortex_interfaces!(sl,left)
    @test rr==rl
    mirror(v)=v.*[1.,-1.,1.]
    for k in eachindex(sr),i in axes(sr[k],1),j in axes(sr[k],2)
        a=sr[k][i,j];b=sl[k][i,size(sl[k],2)+1-j]
        @test mirror(a.rtl)==b.rtr
        @test mirror(a.rbl)==b.rbr
    end
    theta=.29;R=[cos(theta) 0. sin(theta);0. .97 0.;-sin(theta) 0. cos(theta)]
    grids=[reshape(R*reshape(p.grid,3,:),size(p.grid)) for p in right]
    transformed=interface_surfaces(right;grids=grids)
    report=VI.aerodynamic_conform_vortex_interfaces!(transformed,right;grids=grids)
    @test report["maximum_gap_after_m"]==0.
    @test interface_vertex(transformed[1],4,3)==grids[2][:,4,1]
    for k in eachindex(sr),i in eachindex(sr[k])
        @test transformed[k][i].rtl≈R*sr[k][i].rtl atol=1e-15
        @test transformed[k][i].rbr≈R*sr[k][i].rbr atol=1e-15
    end
end

@testset "Ordinary wings and disconnected material remain unchanged" begin
    full=[0.,.25,.5,.75,1.]
    patches=[interface_patch(full,[0.,.25,.5]),interface_patch(full,[.5,.75,1.])]
    surfaces=interface_surfaces(patches);old=deepcopy(surfaces)
    report=VI.aerodynamic_conform_vortex_interfaces!(surfaces,patches)
    @test report["corrected_vertices"]==report["updated_panels"]==0
    @test surfaces==old
    for other in (interface_patch(full,[.5,.75,1.];offset=.001),
                  interface_patch(full,[.5,.75,1.];element_name="control: detached"),
                  interface_patch([.75,1.],[.5,.75,1.]))
        p=[interface_patch([0.,.25,.5,.75],[0.,.25,.5]),other]
        s=interface_surfaces(p);before=deepcopy(s)
        @test VI.aerodynamic_conform_vortex_interfaces!(s,p)["corrected_vertices"]==0
        @test s==before
    end
end

@testset "Sealed control span ends retain their common fixed edge" begin
    full=[0.,.25,.5,.75,1.]
    patches=[interface_patch(full,[0.,.25,.5]),interface_patch(full,[.5,.75,1.])]
    # The hinge at x/c=.75 is shared. The outer sheet bends aft of it,
    # so its fixed edge ends there without terminating the chord array.
    patches[2].grid[3,end,:].+=.05
    surfaces=interface_surfaces(patches);original=deepcopy(surfaces)
    report=VI.aerodynamic_conform_vortex_interfaces!(surfaces,patches)
    @test report["corrected_vertices"]==1
    @test report["corrected_vertex_instances"]==2
    @test report["maximum_gap_after_m"]==0.
    @test interface_vertex(surfaces[1],4,3)==interface_vertex(surfaces[2],4,1)==patches[1].grid[:,4,3]
    for (old,new) in zip(original,surfaces),i in eachindex(old)
        @test (old[i].rcp,old[i].ncp)==(new[i].rcp,new[i].ncp)
    end
    @test surfaces[1][end,end].rbr==original[1][end,end].rbr
    @test surfaces[2][end,1].rbl==original[2][end,1].rbl
end

@testset "System initialization retains canonical records for both wake paths" begin
    patches=[interface_patch([0.,.25,.5,.75,1.],[0.,.25,.5]),interface_patch([0.,.25,.5,.75],[.5,.75,1.])]
    grids=[p.grid for p in patches]
    ref=VIVL.Reference(1.,1.,1.,[0.,0.,0.],10.);fs=VIVL.Freestream(10.,.1,0.,[0.,0.,0.])
    known=r->VIVL.SVector(0.,0.,0.)
    expected=interface_surfaces(patches);VI.aerodynamic_conform_vortex_interfaces!(expected,patches)
    for relaxed in (false,true)
        ratios=[zeros(2,size(g,2)-1,size(g,3)-1).+[.5,.75] for g in grids]
        system=VIVL.System(grids;ratios=ratios)
        report=VI.aerodynamic_initialize_system!(system,patches,grids,ref,fs,[1,1],known,1e-3;relaxed=relaxed)
        @test report["corrected_vertices"]==1
        @test report["maximum_gap_after_m"]==0.
        @test system.surfaces==expected
        @test system.grids==grids
        @test system.near_field_analysis[]==!relaxed
        @test !system.derivatives[]
        if relaxed
            @test all(iszero,system.Γ)
        else
            @test all(isfinite,system.Γ)
            @test norm(system.AIC*system.Γ-system.w)<1e-10
            @test norm(system.Γ)>0.
        end
        @test VI.aerodynamic_conform_vortex_interfaces!(system.surfaces,patches;grids=grids)["corrected_vertices"]==0
    end
end
