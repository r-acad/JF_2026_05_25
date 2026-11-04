using Test, WingFEGen
const WP=WingFEGen
const WPV=WP.VortexLattice

function parallel_wake_grid(xs,ys;offset=0.)
    g=zeros(3,length(xs),length(ys))
    for (i,x) in enumerate(xs),(j,y) in enumerate(ys)
        g[:,i,j].=(x,y,offset*sin(x)*cos(y))
    end
    g
end

@testset "Threaded wake targets preserve physical fields and diagnostic ordering" begin
    system=(surfaces=Matrix{Any}[],Γ=Float64[])
    grids=[parallel_wake_grid([0.,.07,.4,1.8],collect(range(-2.,2.;length=49));offset=.004),
        parallel_wake_grid([.2,.3,.8,2.],collect(range(3.,4.;length=17));offset=-.003)]
    original=deepcopy(grids);strengths=[[.01sin(j) for j in 1:size(g,3)-1] for g in grids]
    known(q)=WPV.SVector(.003q[2],.02q[1],.15+.01q[2])
    for local_target in (false,true)
        serial_diag=Dict{String,Any}()
        serial=WP.aerodynamic_wake_targets(system,grids,strengths,known,20.,.02;diagnostics=serial_diag,local_target)
        for _ in 1:20
            parallel_diag=Dict{String,Any}()
            parallel=WP.aerodynamic_wake_targets(system,grids,strengths,known,20.,.02;diagnostics=parallel_diag,local_target,threaded=true)
            @test serial==parallel
            @test serial_diag==parallel_diag
            @test all(t[:,1,:]==g[:,1,:] for (t,g) in zip(parallel[1],grids))
            @test all(t->all(isfinite,t),parallel[1])
        end
    end
    @test grids==original

    # Identical constant-flow defects select the first physical column even
    # when workers finish in a different order.
    flat=[parallel_wake_grid([0.,.2,1.],collect(0.:.1:2.))]
    gamma=[zeros(20)];diag=Dict{String,Any}()
    target,tangent,displacement=WP.aerodynamic_wake_targets(system,flat,gamma,
        q->WPV.SVector(0.,0.,2.),20.,.02;diagnostics=diag,threaded=true)
    @test target[1][3,end,:]≈fill(.1,21) atol=1e-15
    @test tangent>0
    @test displacement≈.1
    @test diag["worst_tangent"]["patch"]==1
    @test diag["worst_tangent"]["filament"]==1
    aliased=[flat[1],flat[1]]
    independent=WP.aerodynamic_wake_targets(system,aliased,[gamma[1],gamma[1]],
        q->WPV.SVector(0.,0.,2.),20.,.02;threaded=true)[1]
    @test independent[1]!==independent[2]
    @test independent[1]==independent[2]
    @test all(iszero,flat[1][3,:,:])

    function capture(callback;threaded=false)
        try
            WP.aerodynamic_wake_targets(system,flat,gamma,callback,20.,.02;threaded)
            nothing
        catch error
            error
        end
    end
    invalid(q)=q[2]==0. ? (sleep(.005);WPV.SVector(-40.,0.,0.)) : WPV.SVector(NaN,0.,0.)
    serial_error=capture(invalid);parallel_error=capture(invalid;threaded=true)
    @test serial_error isa ArgumentError
    @test parallel_error isa ArgumentError
    @test sprint(showerror,parallel_error)==sprint(showerror,serial_error)
    @test occursin("patch 1, filament 1, row 1",sprint(showerror,parallel_error))
    @test occursin("reverses downstream",sprint(showerror,parallel_error))
    arbitrary(q)=throw("intentional callback value")
    @test capture(arbitrary)=="intentional callback value"
    @test capture(arbitrary;threaded=true)=="intentional callback value"
    calls=Ref(0)
    stateful(q)=(calls[]+=1;throw(ArgumentError("stop immediately")))
    @test capture(stateful) isa ArgumentError
    @test calls[]==1
end
