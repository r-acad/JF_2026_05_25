# julia --project=. --startup-file=no APPS/JFEM-Boxer/test/unboxed_aero_coupling_test.jl OUTPUT
# Physical unboxed-span interpolation, independently checked against rigid motion,
# wrench conservation and virtual work. Generated decks/results remain in OUTPUT.
using Test, LinearAlgebra, Random, WingFEGen, OpenJFEM
const W=WingFEGen
const N=OpenJFEM
length(ARGS)==1 || error("Pass an evidence output directory")
const OUT=abspath(only(ARGS));mkpath(OUT)
const REPORT=Dict{String,Any}()

function coupling_params(;end_eta=.55)
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "planform.sweep"=>15.,"planform.dihedral"=>5.,"planform.twist_tip"=>-3.,
        "box.end_eta"=>end_eta,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>100.,
        "loads.structure_inertia"=>false,"loads.torque_y"=>0.,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"output.solution"=>"101","output.n_modes"=>6))
end
coupling_model(p)=W.build_model(first(W.normalize_params(p)))
point(m,ref)=Tuple(m.xyz[3ref-2:3ref])
dot3(a,b)=sum(a.*b)
function write_coupling_deck(m,name)
    path=joinpath(OUT,name*".bdf")
    W.write_reference(m,path;large_field=true)
    return path,N.bdf_to_model(path)
end
function native_motion(result,m)
    rows=only(result["subcases"])["displacements"]
    lookup=Dict(row["grid_id"]=>row for row in rows)
    u=zeros(length(m.xyz));r=similar(u)
    for (i,id) in enumerate(m.node_ids)
        row=lookup[id]
        u[3i-2:3i].=[row[k] for k in ("t1","t2","t3")]
        r[3i-2:3i].=[row[k] for k in ("r1","r2","r3")]
    end
    u,r
end

tests=@testset "Massless unboxed aerodynamic references" begin
    m=coupling_model(coupling_params());virtual=filter(sp->sp.station<0,m.rbe3)
    physical=filter(sp->sp.station>=0,m.rbe3);terminal=last(physical)
    @test W.all_checks_pass(m)
    @test !isempty(virtual)
    @test last(m.rbe3).eta==1.
    @test all(diff([sp.eta for sp in m.rbe3]).>0)
    @test all(sp->sp.dep==terminal.dep,virtual)
    @test all(sp->sp.ref>m.n_struct && !(sp.ref in sp.dep),virtual)
    @test all(sp->all(1 .<=sp.dep.<=m.n_struct),virtual)
    @test all(sp->all(g->!(sp.ref in g.conn),m.groups),virtual)
    @test all(sp->collect(point(m,sp.ref))≈collect(W.section_point(m.wing,sp.eta,m.params["rbe3.ref_xc"],0.)),virtual)

    # References carry interpolation, never elastic elements or point masses.
    path,parsed=write_coupling_deck(m,"partial_box_static")
    @test length(parsed["RBE3s"])==length(m.rbe3)
    for sp in virtual
        rbe=parsed["RBE3s"][string(sp.eid)]
        @test rbe["REFGRID"]==m.node_ids[sp.ref]
        @test rbe["REFC"]==123456
        groups=rbe["WT_GROUPS"]
        ids=reduce(vcat,[g isa AbstractDict ? g["grids"] : g.grids for g in groups])
        @test Set(ids)==Set(m.node_ids[terminal.dep])
        @test all(g->(g isa AbstractDict ? g["comps"] : g.comps)==123,groups)
    end
    @test isempty(get(parsed,"CONM2s",Dict()))
    no_refs=deepcopy(m.params);no_refs["rbe3.enabled"]=false;no_refs["output.solution"]="103"
    bare=coupling_model(no_refs)
    @test bare.n_struct==m.n_struct
    @test bare.xyz[1:3bare.n_struct]==m.xyz[1:3m.n_struct]
    @test [(g.name,g.pid,g.eids,g.conn) for g in bare.groups]==[(g.name,g.pid,g.eids,g.conn) for g in m.groups]
    @test W.weights_payload(bare)["totals"]["structure_mass_kg"]==W.weights_payload(m)["totals"]["structure_mass_kg"]

    # A fully boxed model keeps its existing structural loft attachment.
    full=coupling_model(coupling_params(end_eta=1.))
    @test all(sp->sp.station>=0,full.rbe3)
    fullmap=copy(full.aero_map);fullweights=copy(full.aero_weights)
    full_etas=[(full.aero_xyz[3((j-1)*full.aero_nloop+1)-1]-full.wing.root_ref_y)/full.wing.semispan for j in 1:length(full.aero_xyz)÷(3full.aero_nloop)]
    W.bind_unboxed_aero_points!(fullmap,fullweights,full.aero_xyz,full.grid,full.rbe3,full_etas,full.aero_nloop)
    @test fullmap==full.aero_map && fullweights==full.aero_weights

    # A rigid body must be reproduced exactly by both the display loft and
    # arbitrary VLM points (including points ahead/behind the structural box).
    translation=(.12,-.07,.31);rotation=(.019,-.027,.031)
    u=zeros(length(m.xyz));r=similar(u)
    for ref in eachindex(m.node_ids)
        u[3ref-2:3ref].=translation.+W.cross3(rotation,point(m,ref))
        r[3ref-2:3ref].=rotation
    end
    stride=length(m.aero_map)÷(length(m.aero_xyz)÷3);lever=W.aero_rotation_levers(m)
    display_error=0.
    for i in 1:length(m.aero_xyz)÷3
        xyz=Tuple(m.aero_xyz[3i-2:3i]);ut=zeros(3);rt=zeros(3)
        for j in 1:stride
            k=stride*(i-1)+j;ref=m.aero_map[k];weight=m.aero_weights[k]
            ut.+=weight.*u[3ref-2:3ref];rt.+=weight.*r[3ref-2:3ref]
        end
        shown=Tuple(ut).+W.cross3(Tuple(rt),Tuple(lever[3i-2:3i]))
        display_error=max(display_error,norm(collect(shown.-translation.-W.cross3(rotation,xyz))))
    end
    @test display_error<1e-12
    points=[W.section_point(m.wing,eta,xc,.025sin(eta)) for eta in (.08,.4,.6,.73,.93,1.),xc in (-.1,.25,.7,1.1)]
    points=vec(points)
    displacement=W.aerodynamic_point_displacements(m,points,u,r)
    point_error=maximum(norm(collect(actual.-translation.-W.cross3(rotation,xyz))) for (actual,xyz) in zip(displacement,points))
    @test point_error<1e-12
    @test_throws ArgumentError W.aerodynamic_point_displacements(m,points,u[1:end-1],r)

    # Independent arbitrary DOFs make this stronger than a rigid-body-only
    # test: equal virtual work proves the force and displacement maps are dual.
    rng=MersenneTwister(20261025);random_u=randn(rng,length(u));random_r=randn(rng,length(r))
    panels=[(eta=(p[2]-m.wing.root_ref_y)/m.wing.semispan,position=p,force=Tuple(randn(rng,3)),moment=Tuple(randn(rng,3))) for p in points]
    transfer=W.transfer_aero_loads(m,panels)
    sourceF,sourceM=W.load_resultant(panels);targetF,targetM=W.load_resultant(transfer)
    @test norm(collect(targetF.-sourceF))<1e-12
    @test norm(collect(targetM.-sourceM))<1e-12
    pu=W.aerodynamic_point_displacements(m,points,random_u,random_r)
    etas=[sp.eta for sp in m.rbe3]
    source_work=0.;target_work=0.
    for (panel,displacement) in zip(panels,pu)
        point_rotation=zeros(3)
        for (j,w) in W.moment_span_weights(etas,panel.eta)
            ref=m.rbe3[j].ref;point_rotation.+=w.*random_r[3ref-2:3ref]
        end
        source_work+=dot3(panel.force,displacement)+dot3(panel.moment,Tuple(point_rotation))
    end
    for station in transfer
        ref=station.node_index
        target_work+=dot3(station.force,Tuple(random_u[3ref-2:3ref]))+dot3(station.moment,Tuple(random_r[3ref-2:3ref]))
    end
    @test isapprox(source_work,target_work;rtol=1e-12,atol=1e-12)
    # Match the browser's per-reference lever path for nonuniform rotations.
    # A common averaged lever passes rigid-body checks but fails this test.
    mixed_params=copy(m.params)
    mixed_params["airfoil.stations"]=[Dict("eta"=>.68,"source"=>"naca","code"=>"NACA0012")]
    mixed=coupling_model(mixed_params)
    mixed_u=randn(rng,length(mixed.xyz));mixed_r=randn(rng,length(mixed.xyz))
    mixed_stride=div(length(mixed.aero_map),div(length(mixed.aero_xyz),3))
    mask=W.aerodynamic_reference_point_mask(mixed)
    @test length(mask)==div(length(mixed.aero_xyz),3)
    @test all(iszero,W.aerodynamic_reference_point_mask(full))
    @test any(==(1),mask)
    @test any(count(!iszero,mixed.aero_weights[mixed_stride*(i-1).+(1:mixed_stride)])>1 for i in findall(==(1),mask))
    variable_rotation_error=0.;common_lever_error=0.
    common_levers=W.aero_rotation_levers(mixed)
    for i in findall(==(1),mask)
        xyz=Tuple(mixed.aero_xyz[3i-2:3i]);displayed=zeros(3);common_u=zeros(3);common_r=zeros(3)
        for j in 1:mixed_stride
            k=mixed_stride*(i-1)+j;ref=mixed.aero_map[k];weight=mixed.aero_weights[k]
            displayed.+=weight.*(mixed_u[3ref-2:3ref].+
                collect(W.cross3(Tuple(mixed_r[3ref-2:3ref]),xyz.-point(mixed,ref))))
            common_u.+=weight.*mixed_u[3ref-2:3ref];common_r.+=weight.*mixed_r[3ref-2:3ref]
        end
        exact=only(W.aerodynamic_point_displacements(mixed,[xyz],mixed_u,mixed_r))
        variable_rotation_error=max(variable_rotation_error,norm(displayed.-collect(exact)))
        old_common=common_u.+collect(W.cross3(Tuple(common_r),Tuple(common_levers[3i-2:3i])))
        common_lever_error=max(common_lever_error,norm(old_common.-collect(exact)))
    end
    @test variable_rotation_error<1e-12
    @test common_lever_error>1e-4
    REPORT["old_common_rotation_lever_error_m"]=common_lever_error
    REPORT["rigid_body_loft_max_error_m"]=display_error
    REPORT["rigid_body_arbitrary_point_max_error_m"]=point_error
    REPORT["wrench_force_error_N"]=norm(collect(targetF.-sourceF))
    REPORT["wrench_moment_error_Nm"]=norm(collect(targetM.-sourceM))
    REPORT["virtual_work_absolute_error"]=abs(target_work-source_work)
    REPORT["variable_rotation_loft_max_error_m"]=variable_rotation_error
    REPORT["virtual_reference_count"]=length(virtual)
    REPORT["physical_reference_count"]=length(physical)
    REPORT["structural_grid_count"]=m.n_struct

    # Independent closed-form strip integrals check prescribed lift moments,
    # rather than merely comparing the generator's two routing functions.
    cdf(kind,taper,x)=kind=="uniform" ? x : kind=="elliptical" ?
        2/pi*(asin(x)+x*sqrt(max(0.,1-x*x))) : kind=="chord" ?
        2/(1+taper)*(x-(1-taper)*x*x/2) : (cdf("elliptical",taper,x)+cdf("chord",taper,x))/2
    firstmoment(kind,taper,x)=kind=="uniform" ? x*x/2 : kind=="elliptical" ?
        -4/(3pi)*(max(0.,1-x*x))^1.5 : kind=="chord" ?
        2/(1+taper)*(x*x/2-(1-taper)*x*x*x/3) :
        (firstmoment("elliptical",taper,x)+firstmoment("chord",taper,x))/2
    moment_errors=Dict{String,Float64}()
    for kind in ("uniform","elliptical","chord","schrenk")
        p=copy(m.params);p["loads.distribution"]=kind;testmodel=coupling_model(p)
        physical_end=last(filter(sp->sp.station>=0,testmodel.rbe3)).eta
        etas=[sp.eta for sp in testmodel.rbe3]
        scale=p["loads.lift_total"]*p["loads.load_factor"]*testmodel.wing.semispan
        integrated=W.analytic_outboard_station_moments(testmodel)
        errors=Float64[]
        for (i,eta) in enumerate(etas)
            a=max(physical_end,i==1 ? 0. : (etas[i-1]+eta)/2)
            b=i==length(etas) ? 1. : (eta+etas[i+1])/2
            expected=b<=a ? 0. : scale*(firstmoment(kind,testmodel.wing.taper,b)-firstmoment(kind,testmodel.wing.taper,a)-
                eta*(cdf(kind,testmodel.wing.taper,b)-cdf(kind,testmodel.wing.taper,a)))
            push!(errors,abs(integrated[i][1]-expected))
        end
        @test maximum(errors)<1e-10
        moment_errors[kind]=maximum(errors)
    end
    REPORT["prescribed_strip_moment_closed_form_error_Nm"]=moment_errors

    if get(ENV,"BOXER_TEST_SKIP_NATIVE","0")!="1"
        ids=sort(parse.(Int,collect(keys(parsed["GRIDs"]))))
        id_map=Dict(id=>i for (i,id) in enumerate(ids))
        coordinates=reduce(vcat,[transpose(Float64.(parsed["GRIDs"][string(id)]["X"])) for id in ids])
        frames=[Matrix{Float64}(I,3,3) for _ in ids]
        constraints=first(N.Solver.assemble_constraints(parsed,id_map,coordinates,frames,Int[],Int[],Float64[]))
        mass=N.Solver.assemble_mass(parsed,id_map,coordinates,frames,6length(ids))
        terminal_dofs=Set(6(id_map[m.node_ids[n]]-1)+c for n in terminal.dep for c in 1:3)
        for sp in virtual
            dofs=6(id_map[m.node_ids[sp.ref]]-1).+(1:6)
            @test all(haskey(constraints,dof) for dof in dofs)
            @test all(source in terminal_dofs for dof in dofs for (source,_) in constraints[dof])
            @test all(iszero,mass[dofs,:])
        end
        elapsed=@elapsed forward=N.solve_model(parsed)
        actual_u,actual_r=native_motion(forward,m)
        @test all(isfinite,actual_u) && all(isfinite,actual_r)
        @test actual_u[3last(virtual).ref]>0
        # Every new reference is derived from the same terminal rib. Its six
        # DOFs therefore reproduce that rib's mean motion, including lever arm.
        ref=terminal.ref;origin=point(m,ref)
        tip_relation_error=maximum(norm(actual_u[3sp.ref-2:3sp.ref] .- actual_u[3ref-2:3ref] .-
            collect(W.cross3(Tuple(actual_r[3ref-2:3ref]),point(m,sp.ref).-origin))) for sp in virtual)
        rotation_error=maximum(norm(actual_r[3sp.ref-2:3sp.ref].-actual_r[3ref-2:3ref]) for sp in virtual)
        @test tip_relation_error<1e-10
        @test rotation_error<1e-10
        REPORT["static_solve_wall_s"]=elapsed
        REPORT["static_virtual_tip_displacement_m"]=actual_u[3last(virtual).ref]
        REPORT["static_reference_translation_relation_error_m"]=tip_relation_error
        REPORT["static_reference_rotation_relation_error_rad"]=rotation_error

        modal_params=copy(m.params);modal_params["output.solution"]="103"
        modal=coupling_model(modal_params);modalpath,modalinput=write_coupling_deck(modal,"partial_box_modal")
        elapsed=@elapsed modes=N.solve_model(modalinput)
        eigenvalues=Float64.(modes["eigenvalues"])
        @test length(eigenvalues)==6
        @test all(isfinite,eigenvalues) && all(eigenvalues.>0)
        # Remove only massless virtual GRIDs/RBE3s from a modal-only deck;
        # physical stiffness, mass and constraints remain identical.
        pruned=N.bdf_to_model(modalpath)
        for sp in virtual
            delete!(pruned["RBE3s"],string(sp.eid));delete!(pruned["GRIDs"],string(m.node_ids[sp.ref]))
        end
        for name in ("FORCEs","MOMENTs","LOADs");haskey(pruned,name)&&(pruned[name]=Dict());end
        baseline=N.solve_model(pruned)
        baselinevalues=Float64.(baseline["eigenvalues"])
        @test length(baselinevalues)==length(eigenvalues)
        eigenerror=maximum(abs.((eigenvalues.-baselinevalues)./baselinevalues))
        @test eigenerror<1e-8
        REPORT["modal_solve_wall_s"]=elapsed
        REPORT["modal_eigenvalues_rad2_per_s2"]=eigenvalues
        REPORT["modal_relative_difference_without_virtual_references"]=eigenerror
        REPORT["static_deck"]=path;REPORT["modal_deck"]=modalpath
    end
end
counts=Test.get_test_counts(tests)
REPORT["passed"]=true;REPORT["assertions"]=counts.passes+counts.cumulative_passes
write(joinpath(OUT,"summary.json"),W.JSON.json(REPORT,2))
