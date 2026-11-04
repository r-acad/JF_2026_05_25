using Test, WingFEGen, LinearAlgebra
const WS = WingFEGen
const WSV = WS.VortexLattice

function safeguard_grid(xs, ys)
    g=zeros(3,length(xs),length(ys))
    for (i,x) in enumerate(xs),(j,y) in enumerate(ys)
        g[:,i,j].=(x,y,0.)
    end
    g
end

@testset "Wake trust region changes proposals, never stations or source geometry" begin
    grids=[safeguard_grid([1.,1.2,2.,5.],[0.,1.]),safeguard_grid([2.,2.1,3.],[-1.,0.,1.])]
    original=deepcopy(grids);step=fill(100.,sum(length,grids));saved=copy(step);core=.02
    bounded=WS.aerodynamic_wake_trust_step(grids,step,core)
    @test grids==original
    @test step==saved
    @test bounded!==step
    offset=0
    for g in grids
        n=length(g);d=reshape(view(bounded,offset+1:offset+n),size(g));offset+=n
        @test all(iszero,d[:,1,:])
        @test all(iszero,d[1,:,:])
        for j in axes(g,3),i in 2:size(g,2)
            adjacent=[g[1,i,j]-g[1,i-1,j]]
            i<size(g,2)&&push!(adjacent,g[1,i+1,j]-g[1,i,j])
            radius=max(2core,.25minimum(adjacent))
            @test norm(d[:,i,j])<=radius*(1+8eps())
            @test norm(d[:,i,j])>0
        end
    end
    tiny=zeros(length(step));offset=0
    for g in grids
        n=length(g);d=reshape(view(tiny,offset+1:offset+n),size(g));offset+=n
        d[2,2:end,:].=1e-9;d[3,2:end,:].=-1e-9
    end
    @test WS.aerodynamic_wake_trust_step(grids,tiny,core)==tiny
    @test WS.aerodynamic_wake_trust_step(grids,zero(tiny),core)==zero(tiny)
end

@testset "Initial invalid or weak convection is not accepted by safeguarding" begin
    # Zero-strength sheets isolate the physical streamwise-velocity check.
    grids=[safeguard_grid([0.,1.,2.],[0.,1.])]
    system=(surfaces=Matrix{Any}[],Γ=Float64[])
    strengths=[zeros(1)];speed=20.;core=.02
    for vx in (-2speed,-speed,-.99speed,NaN)
        @test_throws ArgumentError WS.aerodynamic_wake_targets(system,grids,strengths,
            point->WSV.SVector(vx,0.,0.),speed,core)
    end
    targets,alignment,displacement=WS.aerodynamic_wake_targets(system,grids,strengths,
        point->WSV.SVector(0.,0.,0.),speed,core)
    @test targets==grids
    @test alignment==0.
    @test displacement==0.
end

@testset "Local wake proposals preserve the full integrated stopping defect" begin
    g=safeguard_grid([0.,1.,3.],[0.,1.]);g[2,2,:].+=.3;g[2,3,:].-=.2
    original=copy(g);system=(surfaces=Matrix{Any}[],Γ=Float64[])
    speed=10.;velocity=WSV.SVector(speed,2.,0.)
    targets,alignment,displacement=WS.aerodynamic_wake_targets(system,[g],[zeros(1)],
        point->WSV.SVector(0.,2.,0.),speed,.02;local_target=true)
    @test g==original
    @test targets[1][:,1,:]==g[:,1,:]
    @test targets[1][2,2,1]≈.2
    # The third node is based on the CURRENT second node (.3), not on the
    # newly proposed second node (.2). The cumulative target would be .6.
    @test targets[1][2,3,1]≈.7
    @test displacement≈.8
    local_displacement=maximum(norm(targets[1][:,i,j]-g[:,i,j]) for i in axes(g,2),j in axes(g,3))
    @test local_displacement≈.9
    @test displacement!=local_displacement
    expected=maximum(norm(normalize(g[:,i+1,j]-g[:,i,j])-normalize(velocity)) for i in 1:2,j in axes(g,3))
    @test alignment≈expected
    aligned=safeguard_grid([0.,1.,3.],[0.,1.]);aligned[2,:,:].+=.2aligned[1,:,:]
    fixed,tangent,delta=WS.aerodynamic_wake_targets(system,[aligned],[zeros(1)],
        point->WSV.SVector(0.,2.,0.),speed,.02;local_target=true)
    @test fixed[1]≈aligned
    @test tangent<1e-14
    @test delta<1e-14
end

@testset "Anderson weighting changes only the fit metric and preserves fixed points" begin
    x=[.7,2.,3.];f=[-.2,.4,.1];saved_x=copy(x);saved_f=copy(f)
    states=[[0.,1.,2.],[.5,1.5,2.8]];residuals=[[.5,.4,.2],[.1,.6,.15]]
    plain=WS.aerodynamic_anderson_step!(deepcopy(states),deepcopy(residuals),x,f,.25)
    uniform=WS.aerodynamic_anderson_step!(deepcopy(states),deepcopy(residuals),x,f,.25;weights=ones(3))
    @test uniform≈plain
    weighted=WS.aerodynamic_anderson_step!(deepcopy(states),deepcopy(residuals),x,f,.25;weights=[1.,10.,.1])
    @test all(isfinite,weighted)
    @test maximum(abs,weighted)<=5maximum(abs,f)*(1+8eps())
    @test WS.aerodynamic_anderson_step!(deepcopy(states),deepcopy(residuals),x,zeros(3),.25;weights=[1.,10.,.1])==zeros(3)
    @test x==saved_x
    @test f==saved_f
end

function safeguard_system_snapshot(system)
    (;AIC=copy(system.AIC),gamma=copy(system.Γ),rhs=copy(system.w),nwake=copy(system.nwake),
      panels=[[(Tuple(p.rtl),Tuple(p.rtr),Tuple(p.rbl),Tuple(p.rbr),p.core_size,p.gamma) for p in wake] for wake in system.wakes])
end

@testset "Exhausted rejected trials restore the last accepted coupled system" begin
    # One bound panel is sufficient to verify real AIC/Gamma/wake rollback.
    # The deterministic callback makes the initial wake valid and every later
    # trial invalid; no large model or fragile convergence timing is involved.
    grid=safeguard_grid([0.,1.],[-1.,1.]);system=WSV.System([grid];ratios=[reshape([.5,.75],2,1,1)])
    speed=20.;reference=WSV.Reference(2.,1.,2.,[0.,0.,0.],speed)
    fs=WSV.Freestream(speed,0.,0.,[0.,0.,0.])
    baseline_velocity(point)=WSV.SVector(0.,0.,1.)
    WSV.steady_analysis!(system,reference,fs;symmetric=false,derivatives=false,
        additional_velocity=baseline_velocity,surface_id=[1],xhat=[1.,0.,0.],fcore=(c,ds)->.02)
    settings=Dict{String,Any}("wake_core"=>.02,"wake_length"=>1.,"wake_rows"=>2,
        "wake_iterations"=>5,"wake_tolerance"=>1e-8,"wake_relaxation"=>.25,
        "wake_acceleration"=>"none","speed"=>speed)
    wake_calls=Ref(0);snapshot=Ref{Any}(nothing);retries=String[]
    function known(point)
        if point[1]>1.
            wake_calls[]+=1
            if wake_calls[]==4
                snapshot[]=safeguard_system_snapshot(system)
            elseif wake_calls[]>4
                return WSV.SVector(-2speed,0.,0.)
            end
        end
        baseline_velocity(point)
    end
    error=try
        WS.aerodynamic_free_wake!(system,reference,fs,known,settings,(span=2.,mac=1.,area=2.),
            identity,identity,(0.,0.,0.);progress=(message,done,total)->push!(retries,message))
        nothing
    catch exception
        exception
    end
    @test error isa ArgumentError
    @test occursin("could not find a valid",sprint(showerror,error))
    @test occursin("retained residual",sprint(showerror,error))
    @test occursin("tolerance",sprint(showerror,error))
    @test occursin("Last rejected trial: ArgumentError: Free-wake convection reverses",sprint(showerror,error))
    @test snapshot[]!==nothing
    @test any(occursin("retrying",message) for message in retries)
    if snapshot[]!==nothing
        restored=safeguard_system_snapshot(system)
        @test restored.AIC≈snapshot[].AIC rtol=1e-14 atol=1e-14
        @test restored.gamma≈snapshot[].gamma rtol=1e-14 atol=1e-14
        @test restored.rhs==snapshot[].rhs
        @test restored.nwake==snapshot[].nwake
        @test restored.panels==snapshot[].panels
    end
    @test grid==safeguard_grid([0.,1.],[-1.,1.])
end

@testset "Wake/body diagnostics identify the offending filament and body panel" begin
    hit=(patch=2,filament=7,row=3,tail=false,body_patch=4,chord=5,strip=6,point=(1.,2.,3.))
    message=WS.aerodynamic_wake_collision_message((count=2,samples=[hit]))
    @test occursin("2 wake/body crossings",message)
    @test occursin("wake patch 2, filament 7, row 3",message)
    @test occursin("body patch 4, chord 5, strip 6",message)
    @test occursin("filament 7, tail",WS.aerodynamic_wake_collision_message((count=1,samples=[merge(hit,(tail=true,))])))
    @test WS.aerodynamic_wake_collision_message((count=1,samples=NamedTuple[]))=="Wake/body intersection: 1 wake/body crossings"
end

@testset "Signed tangency rejects nearly opposite flow with positive X" begin
    G=WingFEGen;VL=G.VortexLattice
    body=zeros(3,2,2)
    body[:,1,1].=(0.,0.,0.);body[:,2,1].=(1.,0.,0.)
    body[:,1,2].=(0.,2.,0.);body[:,2,2].=(1.,2.,0.)
    system=VL.System([body]);VL.update_surface_panels!(only(system.surfaces),body)
    system.Γ.=0.;grid=zeros(3,2,2)
    for j in 1:2
        grid[:,1,j].=(1.,2(j-1),0.)
        grid[:,2,j].=(1.0+1e-6,2(j-1)+1.,0.)
    end
    velocity=VL.SVector(.1,-1000.,0.);speed=1.
    _,alignment,_=G.aerodynamic_wake_targets(system,[grid],[[0.]],x->velocity-VL.SVector(speed,0.,0.),speed,.02)
    delta=VL.SVector{3}(grid[:,2,1]-grid[:,1,1])
    @test velocity[1]>.05speed&&delta[1]>0
    @test norm(cross(delta,velocity))/(norm(delta)*norm(velocity))<.002
    @test alignment>1.99999
end

@testset "Integrated and local fallback defects have identical fixed points" begin
    g=safeguard_grid([0.,.2,1.],[0.,1.]);g[3,2,:].=.03;g[3,3,:].=.02
    system=(surfaces=Matrix{Any}[],Γ=Float64[])
    known(point)=WSV.SVector(0.,1.,2.)
    integrated,_,_=WS.aerodynamic_wake_targets(system,[g],[zeros(1)],known,10.,.02)
    local_targets,_,_=WS.aerodynamic_wake_targets(system,[g],[zeros(1)],known,10.,.02;local_target=true)
    defect=WS.aerodynamic_wake_local_defect([g],integrated)
    @test reshape(defect,size(g))≈local_targets[1]-g atol=1e-15
    @test all(iszero,reshape(defect,size(g))[:,1,:])
    aligned=safeguard_grid([0.,.2,1.],[0.,1.]);aligned[2,:,:].+=.1aligned[1,:,:];aligned[3,:,:].+=.2aligned[1,:,:]
    fixed,_,_=WS.aerodynamic_wake_targets(system,[aligned],[zeros(1)],known,10.,.02)
    @test maximum(abs,WS.aerodynamic_wake_local_defect([aligned],fixed))<1e-15
end

@testset "Stiff convection finds admissible steps below the former ten-trial limit" begin
    # A resolved coupled circulation solve with zero circulation isolates the
    # geometric iteration. A steep but finite restoring velocity requires a
    # smaller step than 1/512; physical X convection stays positive throughout.
    grid=safeguard_grid([0.,1.],[-1.,1.]);system=WSV.System([grid];ratios=[reshape([.5,.75],2,1,1)])
    speed=20.;reference=WSV.Reference(2.,1.,2.,[0.,0.,0.],speed)
    fs=WSV.Freestream(speed,0.,0.,[0.,0.,0.])
    known(point)=WSV.SVector(0.,0.,point[1]>1. ? 1. - 4e6*point[3] : 0.)
    WSV.steady_analysis!(system,reference,fs;symmetric=false,derivatives=false,
        additional_velocity=known,surface_id=[1],xhat=[1.,0.,0.],fcore=(c,ds)->.02)
    settings=Dict{String,Any}("wake_core"=>.02,"wake_length"=>1.,"wake_rows"=>2,
        "wake_iterations"=>100,"wake_tolerance"=>1e-7,"wake_relaxation"=>.25,
        "wake_acceleration"=>"anderson","speed"=>speed)
    wake=WS.aerodynamic_free_wake!(system,reference,fs,known,settings,(span=2.,mac=1.,area=2.),
        identity,identity,(0.,0.,0.))
    @test wake["converged"]
    @test wake["residual"]<=settings["wake_tolerance"]
    @test wake["iterations"]<=10
    accepted=[h["accepted_step_fraction"] for h in wake["history"] if haskey(h,"accepted_step_fraction")]
    @test !isempty(accepted)
    @test minimum(accepted)<1/512
    @test all(h["minimum_streamwise_velocity_over_V"]>.05 for h in wake["history"])
    @test all(isfinite,system.Γ)
    @test norm(system.Γ)<1e-12
    @test maximum(abs,system.AIC*system.Γ-system.w)<1e-12
end

@testset "Stationary coupled wake confirms circulation without spurious motion" begin
    grid=safeguard_grid([0.,1.],[-1.,1.]);system=WSV.System([grid];ratios=[reshape([.5,.75],2,1,1)])
    speed=20.;reference=WSV.Reference(2.,1.,2.,[0.,0.,0.],speed)
    fs=WSV.Freestream(speed,0.,0.,[0.,0.,0.]);known(point)=WSV.SVector(0.,0.,0.)
    WSV.steady_analysis!(system,reference,fs;symmetric=false,derivatives=false,
        additional_velocity=known,surface_id=[1],xhat=[1.,0.,0.],fcore=(c,ds)->.02)
    system.Γ.=1. # Deliberately stale initial circulation, not a geometric error.
    settings=Dict{String,Any}("wake_core"=>.02,"wake_length"=>1.,"wake_rows"=>2,
        "wake_iterations"=>2,"wake_tolerance"=>1e-8,"wake_relaxation"=>.25,
        "wake_acceleration"=>"anderson","speed"=>speed)
    wake=WS.aerodynamic_free_wake!(system,reference,fs,known,settings,(span=2.,mac=1.,area=2.),
        identity,identity,(0.,0.,0.))
    @test wake["converged"]
    @test wake["iterations"]==2
    @test wake["rejected_trials"]==0
    @test all(h["alignment"]==0. && h["displacement"]==0. for h in wake["history"])
    @test WS.aerodynamic_wake_defect_location(Dict{String,Any}())==""
    message=WS.aerodynamic_wake_defect_location(Dict("worst_tangent"=>Dict(
        "patch"=>2,"filament"=>7,"row"=>16,"rows"=>16,"streamwise_step_over_core"=>157.8)))
    @test occursin("wake patch 2, filament 7, row 16/16",message)
    @test occursin("terminal finite-wake segment",message)
end
