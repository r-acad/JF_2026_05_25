using Test, LinearAlgebra, WingFEGen
const W=WingFEGen

@testset "Local shell knots use their physical material-axis station" begin
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.))
    w=W.make_wing(p);etas=[0.,.25,.75,1.];xcs=[.2,.7]
    fractions=repeat(reshape(xcs,:,1),1,length(etas))
    grid=W.BoxGrid(w,xcs,etas,1,collect(0:3),fractions,copy(fractions),zeros(Int,2,4),Int[])
    # A triangle beyond a .6 kink still carries the inboard coarse-row key
    # on its inserted vertex. The physical range is .6:.75, not .25:.75.
    points=[(.2,.6,.1),(.7,.75,.1),(.2,.75,.1)]
    xyz=reduce(vcat,[[x,w.root_ref_y+eta*w.semispan,z] for (x,eta,z) in points])
    keys=[(0,1,-99),(1,2,1),(0,2,1)]
    group=W.ElemGroup("local kink",:tria,W.PID_SKIN_UPPER,[1],[1,2,3],Float64[])
    path=(etas=[0.,.6,1.],slopes=[0.,.3])
    expected=normalize([.3,1.,0.])
    for oblique in (false,true)
        g=oblique ? W.BoxGrid(grid.wing,grid.xcs,grid.etas,grid.nh,grid.ribs,
            grid.lower_xcs,grid.upper_xcs,grid.collapsed,grid.stringer_indices,
            grid.lower_etas,grid.upper_etas,(deltas=[.1],)) : grid
        context=(xyz=xyz,node_keys=keys,grid=g,wing=w,params=p)
        x,y,z=W.shell_material_frame(context,group,1;path)
        @test collect(x)≈expected
        @test dot(x,y)≈0 atol=1e-14
        @test dot(x,z)≈0 atol=1e-14
        @test norm(x)≈1
    end
end

@testset "Ordinary-rib shell blades use the final selected kink frame" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>2.,"planform.twist_tip"=>-3.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_stringer_height"=>2,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"stringers.model"=>"shell",
        "box.front_spar_points"=>[Dict("eta"=>.35,"dxc"=>.015)]))
    source=W.build_model(p)
    @test !W.oriented_ribs(source.grid)
    @test W.all_checks_pass(source)
    groups=filter(g->g.kind===:tria&&W.component_base_pid(g.pid)==W.PID_SKIN_UPPER,source.groups)
    cids=sort!([id for group in groups for id in group.eids])
    @test !isempty(cids)
    for cid in unique([first(cids),last(cids)])
        selected=W.build_model(merge(p,Dict("stringers.orientation"=>"coordinate_axis",
            "stringers.axis"=>"z","stringers.axis_cid"=>cid)))
        @test W.all_checks_pass(selected)
        group=only(filter(g->cid in g.eids,selected.groups));index=findfirst(==(cid),group.eids)
        _,_,axis=W.shell_material_frame(selected,group,index)
        for (node,base) in selected.grid.shell_columns.blade_bases
            delta=Tuple(selected.xyz[3node-2:3node]).-base
            @test norm(collect(W.cross3(delta,axis)))<1e-12
        end
    end
end
