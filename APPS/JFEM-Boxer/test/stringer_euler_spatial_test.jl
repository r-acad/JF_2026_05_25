using Test, Random, LinearAlgebra
include(joinpath(@__DIR__,"..","src","stringer_euler_spatial.jl"))

face(id,x,y,z=0.;w=1.,h=1.)=(eid=id,points=[(x,y,z),(x+w,y,z),(x+w,y+h,z),(x,y+h,z)])
ids(faces)=[f.eid for f in faces]

@testset "Euler AABB section candidates" begin
    faces=[face(1,0.,0.),face(2,1.,0.),face(3,0.,1.),face(4,4.,5.)]
    index=euler_face_index(faces;leaf_size=1)
    @test ids(euler_section_candidates(index,(0.,.5,0.),(0.,1.,0.),(1.,0.,0.),.2,.8))==[1]
    @test ids(euler_section_candidates(index,(0.,.5,0.),(0.,1.,0.),(1.,0.,0.),1.,1.))==[1,2]
    @test isempty(euler_section_candidates(index,(0.,9.,0.),(0.,1.,0.),(1.,0.,0.),-10.,10.))
    @test isempty(euler_section_candidates(euler_face_index(Any[]),(0.,0.,0.),(0.,1.,0.),(1.,0.,0.),0.,1.))
    @test_throws ArgumentError euler_face_index([(points=[(NaN,0.,0.)],)])
    @test_throws ArgumentError euler_section_candidates(index,(0.,0.,0.),(0.,0.,0.),(1.,0.,0.),0.,1.)
    @test_throws ArgumentError euler_section_candidates(index,(0.,0.,0.),(0.,1.,0.),(1.,0.,0.),1.,0.)
end

@testset "Swept, translated and warped face candidates" begin
    # A diagonal plane through a nominal bay reaches the next row. No row or
    # bay filter is permitted to remove that valid section candidate.
    faces=[face(1,0.,0.),face(2,1.,1.),face(3,2.,2.),face(4,4.,0.)]
    a=Tuple(normalize([1.,-1.,0.]));y=Tuple(normalize([1.,1.,0.]));o=(.5,.5,0.)
    @test ids(euler_section_candidates(euler_face_index(faces),o,a,y,0.,4.))==[1,2,3]
    shift=(1e8,-2e8,3e8)
    translated=[(eid=f.eid,points=[p.+shift for p in f.points]) for f in faces]
    @test ids(euler_section_candidates(euler_face_index(translated),o.+shift,a,y,0.,4.))==[1,2,3]
    warped=(eid=9,points=[(0.,0.,-.2),(1.,0.,.2),(1.,1.,-.2),(0.,1.,.2)])
    @test ids(euler_section_candidates(euler_face_index([warped]),(.5,.5,0.),(1.,0.,0.),(0.,1.,0.),-.2,.2))==[9]
end

@testset "Conservative random queries and deterministic ordering" begin
    rng=MersenneTwister(4815)
    faces=[(eid=i,points=[Tuple(30rand(rng,3).-15) for _ in 1:4]) for i in 1:300]
    a=euler_face_index(faces;leaf_size=4);b=euler_face_index(faces;leaf_size=19)
    for _ in 1:80
        origin=Tuple(20rand(rng,3).-10);axis=Tuple(normalize(randn(rng,3)));y=Tuple(normalize(cross(collect(axis),randn(rng,3))))
        lo,hi=minmax(10rand(rng)-5,10rand(rng)-5)
        # Independent vertex projection intervals are tighter than AABBs.
        # Every face they can retain must also survive the BVH query.
        exact_possible=Set(f.eid for f in faces if begin
            plane=[dot(collect(p.-origin),collect(axis)) for p in f.points]
            transverse=[dot(collect(p.-origin),collect(y)) for p in f.points]
            minimum(plane)<=0<=maximum(plane)&&minimum(transverse)<=hi&&maximum(transverse)>=lo
        end)
        queried=ids(euler_section_candidates(a,origin,axis,y,lo,hi))
        @test issubset(exact_possible,Set(queried))
        @test queried==sort(queried)
        @test queried==ids(euler_section_candidates(b,origin,axis,y,lo,hi))
    end
end

@testset "Fine mesh spatial pruning" begin
    nx,ny=240,160
    faces=[face((j-1)*nx+i,(i-1)/10,(j-1)/10;w=.1,h=.1) for j in 1:ny for i in 1:nx]
    index=euler_face_index(faces);stats=Dict{Symbol,Int}()
    result=euler_section_candidates(index,(12.,7.53,0.),(0.,1.,0.),(1.,0.,0.),-.12,.12;stats)
    @test length(result)==4
    @test stats[:tested_faces]<100
    @test stats[:visited_nodes]<150
    println("Fine-mesh query: ",length(faces)," faces; ",stats[:tested_faces]," leaf faces tested; ",stats[:visited_nodes]," nodes visited; ",length(result)," candidates.")
end
