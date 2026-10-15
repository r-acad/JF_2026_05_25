using Test, LinearAlgebra, ForwardDiff, WingFEGen
const W=WingFEGen
matrix(rows)=reduce(vcat,permutedims.(rows))
function tiny_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.65,
        "planform.sweep"=>18.,"planform.twist_tip"=>-5.,"box.end_eta"=>1.,"box.rib_pitch"=>.3,
        "box.stringer_pitch"=>.15,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "fuel.enabled"=>false,"leading_edge.enabled"=>true,"loads.cases"=>Any[],
        "aero.enabled"=>false,"loads.method"=>"analytic","loads.structure_inertia"=>false))
    first(p["materials.shells"])["kind"]="sandwich"
    for (i,(component,_,unit)) in enumerate(W.NONSTRUCTURAL_COMPONENTS)
        p["nonstructural."*component]=i*(unit=="kg/m2" ? .7 : .13)
    end
    W.normalize_params(p)[1]
end
function conservation(m,rows)
    raw=[W.structural_element_mass_moments(m,g,e) for g in m.groups for e in 1:W.n_elements(g)]
    @test sum(r["mass_kg"] for r in rows)≈sum(r.mass for r in raw) rtol=3e-13
    @test sum(r["mass_kg"]*r["center_of_gravity_m"] for r in rows)≈sum(r.first for r in raw) rtol=3e-13
    second=sum(begin
        inertia=matrix(r["inertia_kg_m2"]);central=tr(inertia)/2*I-inertia
        central+r["mass_kg"]*(r["center_of_gravity_m"]*r["center_of_gravity_m"]')
    end for r in rows)
    @test second≈sum(r.second for r in raw) rtol=3e-13
    @test sum(r["mass_kg"] for r in rows)≈W.weights_payload(m)["totals"]["structure_mass_kg"] rtol=1e-12
end
@testset "Conserved structural mass per physical rib bay" begin
    p=tiny_params();m=W.build_model(p);before=(copy(m.xyz),copy(m.node_ids),deepcopy(m.params))
    rows=W.structural_inertia_payload(m)
    @test length(rows)==length(m.grid.ribs)-1
    @test [r["start_rib"] for r in rows]==collect(1:length(rows))
    @test (m.xyz,m.node_ids,m.params)==before
    @test all(r["reference_grid"]===nothing for r in rows)
    @test any(norm(r["offset_m"])>1e-5 for r in rows)
    conservation(m,rows)
    for r in rows
        tensor=matrix(r["inertia_kg_m2"])
        @test issymmetric(tensor)
        @test minimum(eigvals(Symmetric(tensor)))>=-1e-11*maximum(abs,tensor)
        @test r["center_of_gravity_m"]≈r["reference_m"]+r["offset_m"]
        @test r["conm2_inertia_kg_m2"]≈[tensor[1,1],-tensor[2,1],tensor[2,2],-tensor[3,1],-tensor[3,2],tensor[3,3]]
    end
    for gr in m.groups,e in 1:W.n_elements(gr)
        ownership=W.structural_element_bay_weights(m,gr,e);@test sum(last,ownership)==1.
        n=gr.kind===:bar ? 2 : gr.kind===:tria ? 3 : 4
        span=unique(m.node_keys[node][2] for node in gr.conn[n*(e-1)+1:n*e])
        if length(span)==1&&first(span) in m.grid.ribs
            rib=findfirst(==(first(span)),m.grid.ribs)
            @test ownership==(rib==1 ? [(1,1.)] : rib==length(m.grid.ribs) ? [(rib-1,1.)] : [(rib-1,.5),(rib,.5)])
        end
    end
    wet=deepcopy(p);merge!(wet,Dict("fuel.enabled"=>true,"fuel.start_rib"=>2,"fuel.end_rib"=>length(rows)+1,"fuel.disabled_bays"=>"3"))
    wm=W.build_model(W.normalize_params(wet)[1]);wr=W.structural_bay_mass_properties(wm)
    @test length(wr)==length(rows);conservation(wm,wr)
    for (a,b) in zip(rows,wr)
        @test a["mass_kg"]≈b["mass_kg"] rtol=1e-13
        @test matrix(a["inertia_kg_m2"])≈matrix(b["inertia_kg_m2"]) rtol=1e-12
        if b["reference_grid"]!==nothing
            node=b["reference_node"]+1
            @test b["reference_m"]==wm.xyz[3node-2:3node]
            @test b["reference_grid"]==wm.node_ids[node]
        end
    end
    delta=[10.,-5.,3.]
    for (axis,d) in zip(("x","y","z"),delta);p["planform.root_ref_"*axis]+=d;end
    moved=W.structural_inertia_payload(W.build_model(W.normalize_params(p)[1]))
    for (a,b) in zip(rows,moved)
        @test a["mass_kg"]≈b["mass_kg"] rtol=1e-11
        @test a["reference_m"]+delta≈b["reference_m"] atol=1e-10
        @test a["center_of_gravity_m"]+delta≈b["center_of_gravity_m"] atol=1e-10
        @test matrix(a["inertia_kg_m2"])≈matrix(b["inertia_kg_m2"]) rtol=1e-9 atol=1e-9
    end
end
@testset "Exact section, layer and signed raw moments" begin
    m=W.build_model(tiny_params());bar=first(g for g in m.groups if g.kind===:bar)
    a,b=collect.(W.element_points(m,bar,1));d=b-a;length_e=norm(d)
    section=W.section_definition(m.params,bar.pid);rho=W.bar_material_definition(m.params,bar.pid)["rho"]
    density=rho+W.nonstructural_mass_density(m.params,bar.pid)/section["area_m2"]
    x=d/length_e;v=bar.orient[1:3];y=normalize(v-dot(x,v)*x);z=cross(x,y)
    offset=collect(W.bar_section_offset(m,bar,1));center=(a+b)/2+offset
    moment=W.structural_element_mass_moments(m,bar,1)
    @test moment.mass≈length_e*density*section["area_m2"]
    @test moment.first/moment.mass≈center
    expected=moment.mass*d*d'/12+length_e*density*(section["I1_m4"]*y*y'+section["I2_m4"]*z*z')
    @test moment.second-moment.mass*center*center'≈expected atol=1e-13 rtol=1e-9
    quad=first(g for g in m.groups if g.kind===:quad)
    base=W.structural_element_mass_moments(m,quad,1;shell_moments=(2.,.3,.4))
    neg=W.structural_element_mass_moments(m,quad,1;shell_moments=(-2.,-.3,-.4))
    @test neg.mass≈-base.mass;@test neg.first≈-base.first;@test neg.second≈-base.second
    zero_mass=W.structural_element_mass_moments(m,quad,1;shell_moments=(0.,.3,.4))
    @test zero_mass.mass==0.;@test norm(zero_mass.first)>0;@test all(isfinite,zero_mass.second)
    @test ForwardDiff.derivative(t->sum(W.structural_element_mass_moments(m,quad,1;shell_moments=(2t,.3t,.4t)).second),1.)≈sum(base.second)
    @test ForwardDiff.derivative(t->sum(W.structural_element_mass_moments(m,bar,1;bar_properties=(linear_mass=t,offset,section_second=t.*Matrix{Float64}(I,3,3))).second),0.)≈sum(W.structural_element_mass_moments(m,bar,1;bar_properties=(linear_mass=1.,offset,section_second=Matrix{Float64}(I,3,3))).second)
    for g in m.groups
        g.kind===:bar&&continue
        property=W.shell_material_definition(m.params,g.pid);m0,m1,m2=W.structural_shell_mass_moments(m.params,g.pid)
        @test m0≈property["areal_mass_kg_m2"]
        if property["type"]=="PSHELL"
            @test m1==0.;@test m2≈m0*property["thickness_m"]^2/12
        else
            @test abs(m1)<1e-14;@test m2>0.
            no_nsm=deepcopy(m.params);for (component,_,_) in W.NONSTRUCTURAL_COMPONENTS;no_nsm["nonstructural."*component]=0.;end
            @test W.structural_shell_mass_moments(no_nsm,g.pid)[3]≈m2
        end
    end
    saved=copy(m.xyz[1:12]);m.xyz[1:12].=[0.,0.,0.,2.,0.,0.,2.,3.,0.,0.,3.,0.]
    try
        q=W.ElemGroup("test",:quad,quad.pid,[1],[1,2,3,4],Float64[])
        r=W.structural_element_mass_moments(m,q,1;shell_moments=(2.,.5,.25))
        @test r.mass≈12.;@test r.first≈[12.,18.,3.]
        @test r.second≈[16. 18. 3.;18. 36. 4.5;3. 4.5 1.5]
        t=W.ElemGroup("test",:tria,quad.pid,[1,2],[1,2,3,1,3,4],Float64[])
        rt=[W.structural_element_mass_moments(m,t,e;shell_moments=(2.,.5,.25)) for e in 1:2]
        @test sum(x.mass for x in rt)≈r.mass;@test sum(x.first for x in rt)≈r.first;@test sum(x.second for x in rt)≈r.second
    finally;m.xyz[1:12].=saved;end
end
@testset "Angled ribs retain physical bay ownership" begin
    p=tiny_params();p["ribs.masters"]=Any[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>80.,"pitch"=>.3)]
    p["loads.structure_inertia"]=true
    m=W.build_model(W.normalize_params(p)[1]);rows=W.structural_bay_mass_properties(m)
    @test W.oriented_ribs(m.grid)
    @test length(rows)==length(m.grid.ribs)-1
    conservation(m,rows)
    for row in rows
        @test row["reference_grid"]!==nothing
        node=row["reference_node"]+1
        @test row["reference_m"]==m.xyz[3node-2:3node]
    end
    if !isempty(ARGS)
        mkpath(ARGS[1]);write(joinpath(ARGS[1],"angled-bay-mass.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
        write(joinpath(ARGS[1],"angled-bay-schema.json"),W.JSON.json(W.schema_payload(m.params,"bay-mass-test.toml")))
    end
end
