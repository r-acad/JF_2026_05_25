using Test, WingFEGen, LinearAlgebra
const WC=WingFEGen

function clearance_grid(xs,ys;z=x->0.)
    g=zeros(3,length(xs),length(ys))
    for (i,x) in enumerate(xs),(j,y) in enumerate(ys);g[:,i,j].=(x,y,z(x));end
    g
end

@testset "Internal panel edges and straight tails cannot hide penetration" begin
    # The physical crossing lies on both chordwise and spanwise mesh edges.
    body=[clearance_grid([1.,1.5,2.],[-1.,.2,1.];z=x->.6-.4x)]
    triangles=WC.aerodynamic_wake_body_triangles(body)
    @test WC.aerodynamic_wake_collisions([clearance_grid([0.,3.],[.2])],triangles).count==1
    # Finite wake is short: the penetration occurs on its semi-infinite tail.
    short=[clearance_grid([0.,.25,.5],[.2])]
    original=deepcopy(short)
    report=WC.aerodynamic_wake_collisions(short,triangles)
    @test report.count==1
    @test report.segment_count==2
    @test report.tail_segment_count==1
    @test only(report.samples).tail
    WC.aerodynamic_seed_clear_wake!(short,triangles,1.;core=.05)
    @test WC.aerodynamic_wake_collisions(short,triangles).count==0
    @test short[1][1,:,:]==original[1][1,:,:]
    @test short[1][:,1,:]==original[1][:,1,:]
    splitbody=[clearance_grid([1.,2.],[-1.,0.];z=x->.6-.4x),
        clearance_grid([1.,2.],[0.,1.];z=x->.6-.4x)]
    splittriangles=WC.aerodynamic_wake_body_triangles(splitbody)
    @test WC.aerodynamic_wake_collisions([clearance_grid([0.,3.],[0.])],splittriangles).count==1
    @test WC.aerodynamic_wake_collisions([clearance_grid([0.,3.],[1.])],splittriangles).count==0
end

@testset "Physical-panel wake intersections and conservative initial clearance" begin
    body=[clearance_grid([1.,2.],[-1.,1.];z=x->.6-.4x)]
    originalbody=deepcopy(body);triangles=WC.aerodynamic_wake_body_triangles(body)
    @test length(triangles)==2
    # The centre filament crosses exactly on the artificial triangle diagonal.
    wakes=[clearance_grid([0.,.25,.6,1.2,2.5,4.],[-.2,0.,.2,1.1])]
    original=deepcopy(wakes)
    before=WC.aerodynamic_wake_collisions(wakes,triangles;scale=1.)
    @test before.count==3
    @test before.segment_count==20
    @test all(hit.body_patch==1 for hit in before.samples)
    @test sort([hit.filament for hit in before.samples])==[1,2,3]
    metadata=WC.aerodynamic_seed_clear_wake!(wakes,triangles,1.;core=.05)
    @test metadata.initial_intersections==3
    @test metadata.remaining_intersections==0
    @test metadata.modified_filaments==3
    @test metadata.max_offset>0
    @test WC.aerodynamic_wake_collisions(wakes,triangles).count==0
    @test wakes[1][1,:,:]==original[1][1,:,:]
    @test wakes[1][:,1,:]==original[1][:,1,:]
    @test wakes[1][2,:,:]==original[1][2,:,:]
    @test wakes[1][:,:,4]==original[1][:,:,4]
    @test body==originalbody
    saved=deepcopy(wakes)
    @test WC.aerodynamic_seed_clear_wake!(wakes,triangles,1.;core=.05).modified_filaments==0
    @test wakes==saved
    # An intersection on a wake station is counted once, not once per segment.
    nodes=[clearance_grid([0.,1.5,3.],[.2])]
    @test WC.aerodynamic_wake_collisions(nodes,triangles).count==1
    # Finite-sheet attachment and a grazing external body edge are allowed.
    @test WC.aerodynamic_wake_collisions([clearance_grid([1.5,3.],[.2])],triangles).count==0
    @test WC.aerodynamic_wake_collisions([clearance_grid([0.,3.],[1.])],triangles).count==0
    @test WC.aerodynamic_wake_collisions(wakes,NamedTuple[]).count==0
    lower=deepcopy(original)
    lower_metadata=WC.aerodynamic_seed_clear_wake!(lower,triangles,1.;core=.05,side=-1)
    @test lower_metadata.remaining_intersections==0
    @test WC.aerodynamic_wake_collisions(lower,triangles).count==0
    @test all(lower[1][3,2:end,1:3].<0)
    @test lower[1][:,1,:]==original[1][:,1,:]
    @test_throws ArgumentError WC.aerodynamic_seed_clear_wake!(lower,triangles,1.;core=.05,side=0)
end

@testset "Duplicated physical TE vertices keep identical initialization" begin
    body=[clearance_grid([1.,2.],[-1.,1.];z=x->.6-.4x)]
    triangles=WC.aerodynamic_wake_body_triangles(body)
    wakes=[clearance_grid([0.,.25,.6,1.2,2.5,4.],[-.2,0.]),
        clearance_grid([0.,.25,.6,1.2,2.5,4.],[0.,.2])]
    WC.aerodynamic_seed_clear_wake!(wakes,triangles,1.;core=.05)
    @test wakes[1][:,:,2]==wakes[2][:,:,1]
    @test WC.aerodynamic_wake_collisions(wakes,triangles).count==0
end

@testset "Optional span dilation follows TE connectivity without reducing clearance" begin
    firstgrid=clearance_grid([0.,.5,1.],[0.,.1,.2]);firstgrid[3,2:end,1].=1.
    # The second patch continues the first TE; the nearby third is detached.
    continued=clearance_grid([0.,.5,1.],[.2,.3])
    detached=clearance_grid([.01,.51,1.01],[0.,.1])
    grids=[firstgrid,continued,detached];original=deepcopy(grids)
    WC.aerodynamic_smooth_wake_seed!(grids,1,.1)
    @test grids[1][3,2:3,1]==[1.,1.]
    @test grids[1][3,2,2]≈exp(-1)
    @test grids[1][3,2,3]≈exp(-2)
    @test grids[2][3,2,2]≈exp(-3)
    @test grids[1][:,:,3]==grids[2][:,:,1]
    @test grids[3]==original[3]
    @test all(g[1,:,:]==old[1,:,:]&&g[:,1,:]==old[:,1,:] for (g,old) in zip(grids,original))
    body=[clearance_grid([1.,2.],[-.2,.2];z=x->.6-.4x)]
    triangles=WC.aerodynamic_wake_body_triangles(body)
    for side in (-1,1)
        wake=[clearance_grid([0.,.25,.6,1.2,2.5,4.],[-1.,-.2,0.,.2,1.])]
        old=deepcopy(wake)
        report=WC.aerodynamic_seed_clear_wake!(wake,triangles,1.;core=.05,side,span_smoothing=true)
        @test report.modified_filaments>1
        @test report.remaining_intersections==0
        @test WC.aerodynamic_wake_collisions(wake,triangles).count==0
        @test wake[1][1,:,:]==old[1][1,:,:]
        @test wake[1][:,1,:]==old[1][:,1,:]
    end
end

@testset "An impossible clearance branch fails without changing the input" begin
    # The TE starts above a sheet that already extends upstream. A continuous
    # fixed-Y ray cannot switch to its lower side without passing through it.
    bodies=[clearance_grid([-1.,1.],[-1.,1.];z=x->-.1+.2x)]
    triangles=WC.aerodynamic_wake_body_triangles(bodies)
    wake=[clearance_grid([0.,.2,.5,1.5],[0.])];original=deepcopy(wake)
    @test WC.aerodynamic_wake_collisions(wake,triangles).count==1
    @test_throws ArgumentError WC.aerodynamic_seed_clear_wake!(wake,triangles,1.;core=.05,side=-1)
    @test wake==original
    @test WC.aerodynamic_seed_clear_wake!(wake,triangles,1.;core=.05,side=1).remaining_intersections==0
end
