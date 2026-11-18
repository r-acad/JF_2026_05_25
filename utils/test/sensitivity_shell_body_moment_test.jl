using Test
module ShellBodyMomentDerivativeFixture
using Test,LinearAlgebra,Printf
struct Model
    params::Dict{String,Any}
    groups::Vector{Any}
    xyz::Vector{Float64}
    node_ids::Vector{Int}
    n_struct::Int
    fuel_rbe3::Vector{Any}
    grid::Nothing
end
const AERO_ZERO=(0.,0.,0.)
const WEIGHT_GRAVITY=1.
cross3(a,b)=(a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1])
norm3(a)=sqrt(sum(abs2,a))
unit3(a)=Tuple(a./norm3(a))
n_elements(g)=length(g.eids)
element_points(m,g,e)=[Tuple(m.xyz[3i-2:3i]) for i in g.conn]
register_shell_stringer_mass_geometry!(args...)=nothing
structure_inertia_enabled(p)=true
inertia_acceleration_g(p)=(1.3,-.7,-9.81)
function load_resultant(records)
    force=zeros(3);moment=zeros(3)
    for row in records
        force.+=row.force;moment.+=row.moment.+cross3(row.position,row.force)
    end
    Tuple(force),Tuple(moment)
end
function physical_moments(p)
    x=p["properties.test_x"];mode=p["properties.test_mode"]
    h1=.001;h2=.003+(mode===:thickness ? x : 0.)
    rho1=1600. + (mode===:redistribution ? x/h1 : 0.)
    rho2=2700. - (mode===:redistribution ? x/.003 : 0.)
    z=.002+(mode===:reference_shift ? x : 0.)
    nsm=p["nonstructural.test"]+(mode===:nsm ? x : 0.)
    m0=nsm;m1=0.;m2=0.
    for (h,rho) in ((h1,rho1),(h2,rho2))
        top=z+h;m0+=rho*h;m1+=rho*(top^2-z^2)/2;m2+=rho*(top^3-z^3)/3;z=top
    end
    m0,m1,m2
end
structural_shell_mass_moments(p,pid)=physical_moments(p)
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","load_moments.jl"))
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","structure_loads.jl"))
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","sensitivity_analytic_loads.jl"))
function fixture(kind,mode,nsm,x=0.)
    points=kind===:quad ? [(0.,0.,0.),(2.,0.,.03),(1.9,1.,.09),(-.1,.9,-.04)] :
        [(0.,0.,0.),(2.,0.,.07),(.2,1.,-.04)]
    n=length(points);append!(points,[(.4,-.2,-.15),(.8,1.2,.1)])
    params=Dict{String,Any}("properties.test_x"=>x,"properties.test_mode"=>mode,
        "nonstructural.test"=>nsm,"loads.load_factor"=>1.)
    group=(;kind,pid=11,conn=collect(1:n),eids=[1])
    Model(params,Any[group],reduce(vcat,collect.(points)),collect(1:n+2),n,Any[(;ref=n+1),(;ref=n+2)],nothing)
end
function direction(mode)
    top=.006
    mode===:thickness&&return (2700.,2700top,2700top^2)
    mode===:reference_shift&&return (0.,1600*.001+2700*.003,2*(1600*(.003^2-.002^2)/2+2700*(.006^2-.003^2)/2))
    mode===:redistribution&&return (0.,(.002+.003)/2-(.003+.006)/2,
        (.003^3-.002^3)/(3*.001)-(.006^3-.003^3)/(3*.003))
    mode===:nsm&&return (1.,0.,0.)
    error("Unknown fixture mode")
end
function primal_force(m)
    loads=structure_applied_loads(m)
    records=[(;position=Tuple(m.xyz[3s.node+1:3s.node+3]),force=s.force,moment=s.moment) for s in loads]
    targets=[Tuple(m.xyz[3s.ref-2:3s.ref]) for s in m.fuel_rbe3]
    routed=transfer_load_wrenches(targets,records);result=zeros(6length(m.node_ids))
    for (i,ref) in enumerate(m.fuel_rbe3)
        result[6ref.ref-5:6ref.ref-3].=routed.force[i]
        result[6ref.ref-2:6ref.ref].=routed.moment[i]
    end
    result
end
function checks()
    for kind in (:quad,:tria),nsm in (0.,.7),mode in (:thickness,:reference_shift,:redistribution,:nsm)
        model=fixture(kind,mode,nsm);dm=direction(mode)
        directions=Dict(11=>Dict("areal_mass"=>dm[1],"mass_moments"=>dm))
        analytic=sensitivity_analytic_load_tangent(model,directions)
        h=mode===:thickness||mode===:reference_shift ? 1e-7 : 1e-5
        numerical=(primal_force(fixture(kind,mode,nsm,h))-primal_force(fixture(kind,mode,nsm,-h)))/(2h)
        @test analytic.force≈numerical rtol=2e-7 atol=1e-8
        @test analytic.diagnostics["affected_elements"]==1
        @test analytic.diagnostics["force_relative_error"]<1e-12
        @test analytic.diagnostics["moment_relative_error"]<1e-12
        if iszero(dm[1])
            @test norm(analytic.force)>1e-6
            @test all(norm(analytic.force[6r.ref-5:6r.ref-3])<1e-12 for r in model.fuel_rbe3)
        end
    end
end
end
@testset "Shell body-load first mass moment derivatives preserve offset couples" begin
    ShellBodyMomentDerivativeFixture.checks()
end
