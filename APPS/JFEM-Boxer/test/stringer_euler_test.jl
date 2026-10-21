using Test, LinearAlgebra, JSON, WingFEGen
const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
mat1(id,e=70e9,nu=.3)=Dict("type"=>"MAT1","id"=>id,"E_Pa"=>e,"nu"=>nu)
function stack(materials,thicknesses,angles;offset=0.)
    t=sum(thicknesses)
    W.euler_shell_section(Dict("type"=>"PCOMP","thickness_m"=>t,"z0_m"=>offset-t/2,
        "plies"=>[Dict("material"=>m,"material_id"=>m["id"],"thickness_m"=>h,"angle_deg"=>a)
            for (m,h,a) in zip(materials,thicknesses,angles)]))
end
function fixture_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,
        "mesh.elements_between_stringers"=>2,"mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>2,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,"fuel.enabled"=>false,"leading_edge.enabled"=>false,
        "aero.enabled"=>false,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "loads.lift_total"=>1.,"output.solution"=>"101","output.n_modes"=>3,"stringers.model"=>"beam"))
    p
end
build(p)=W.build_model(first(W.normalize_params(p)))
function stiffness(station)
    total=zeros(3,3)
    for part in station["parts"]
        if haskey(part,"axial_matrix")
            total.+=reduce(vcat,permutedims.(part["axial_matrix"]))
        else
            a,y,z,e=part["area_m2"],part["centroid_y_m"],part["centroid_z_m"],part["young_pa"]
            total.+=e.*[a a*y a*z;a*y part["izz_m4"]+a*y^2 part["iyz_m4"]+a*y*z;a*z part["iyz_m4"]+a*y*z part["iyy_m4"]+a*z^2]
        end
    end
    total
end
coverage=Any[]
checks=@testset "Actual stringer Euler sections and laminate laws" begin
    e=70e9;t=.003;offset=-.002
    section=stack([mat1(1)],[t],[0.];offset)
    for angle in (0.,.32,pi/2)
        @test W.euler_laminate_axial(section,angle)≈e.*[t t*offset;t*offset t^3/12+t*offset^2] rtol=2e-12
    end
    law=W.euler_laminate_axial(section,0.)
    width=.08;center=(.012,.02);tangent=(1.,0.);normal=(0.,1.)
    matrix=W.euler_strip_matrix(law,width,center,tangent,normal)
    centroid=[center[1],center[2]+offset];a=t*width
    expected=e.*[a a*centroid[1] a*centroid[2];
        a*centroid[1] a*centroid[1]^2+t*width^3/12 a*prod(centroid);
        a*centroid[2] a*prod(centroid) a*centroid[2]^2+width*t^3/12]
    @test matrix≈expected rtol=1e-12
    @test isposdef(Symmetric(matrix))
    shift=(.37,-.22);translated=W.euler_strip_matrix(law,width,center.+shift,tangent,normal)
    transform=[1. shift[1] shift[2];0. 1. 0.;0. 0. 1.]
    @test translated≈transpose(transform)*matrix*transform rtol=2e-12
    angle=.72;rotation=[cos(angle) -sin(angle);sin(angle) cos(angle)]
    transform=cat(ones(1,1),transpose(rotation);dims=(1,2))
    rotated=W.euler_strip_matrix(law,width,rotation*collect(center),rotation*collect(tangent),rotation*collect(normal))
    @test rotated≈transpose(transform)*matrix*transform rtol=2e-12
    ortho=Dict("type"=>"MAT8","id"=>9,"E1_Pa"=>130e9,"E2_Pa"=>9e9,"G12_Pa"=>5e9,"nu12"=>.28)
    for angle in (0.,.4,pi/2)
        c,s=cos(angle),sin(angle)
        effective=1/(c^4/ortho["E1_Pa"]+s^4/ortho["E2_Pa"]+c^2*s^2*(1/ortho["G12_Pa"]-2ortho["nu12"]/ortho["E1_Pa"]))
        axial=W.euler_laminate_axial(stack([ortho],[t],[0.]),angle)
        @test axial≈effective.*[t 0.;0. t^3/12] rtol=2e-12
    end
    angle=.17;orthotropic_offset=stack([ortho],[t],[27.];offset)
    law_fixture=W.euler_laminate_axial(orthotropic_offset,angle)
    write(joinpath(out,"mat8_directional_law.json"),JSON.json(Dict("material"=>ortho,"thickness_m"=>t,"offset_m"=>offset,"ply_angle_deg"=>27.,"column_angle_rad"=>angle,"axial_law"=>[collect(law_fixture[i,:]) for i in 1:2])))
    # Same-nu unsymmetric MAT1 layers give exact E-weighted first/second moments.
    mixed=stack([mat1(1),mat1(2,140e9)],[.001,.002],[0.,0.])
    expected=zeros(2,2);z=-.0015
    for (modulus,h) in ((70e9,.001),(140e9,.002))
        z1=z+h;expected.+=modulus.*[h (z1^2-z^2)/2;(z1^2-z^2)/2 (z1^3-z^3)/3];z=z1
    end
    @test W.euler_laminate_axial(mixed,.31)≈expected rtol=2e-12
    composite=stack(fill(ortho,3),[.001,.0015,.0008],[0.,45.,90.];offset=-.0004)
    @test isposdef(Symmetric(W.euler_laminate_axial(composite,.23)))
    @test abs(W.euler_laminate_axial(composite,.23)[1,2])>1.
    @test_throws ArgumentError W.euler_material_q(merge(ortho,Dict("G12_Pa"=>0.)))
    @test_throws ArgumentError W.euler_shell_section(Dict("type"=>"PSOLID"))
    # Oblique geometry reproduces the documented p^4 energy-modulus rule.
    p=.8;oblique=W.euler_strip_matrix(law,width,center,tangent,normal,p)
    equivalent=W.euler_strip_matrix((e*p^4).*[t/p t*offset/p^2;t*offset/p^2 (t^3/12+t*offset^2)/p^3],width,center,tangent,normal)
    @test oblique≈equivalent rtol=2e-12
    base=fixture_params();base_model=build(base)
    @test W.sensitivity_model_signature(base_model)==W.sensitivity_model_signature(build(merge(base,Dict("stringers.euler_fixity_coefficient"=>4.))))
    @test_throws ArgumentError build(merge(base,Dict("stringers.euler_fixity_coefficient"=>0.)))
    for kind in ("beam","shell","shell_offset","shell_mixed","blade","swept")
        p=fixture_params();p["stringers.model"]=startswith(kind,"shell")||kind=="blade" ? "shell" : "beam"
        kind=="shell_offset"&&(p["stringers.shell_offsets"]=true)
        if kind=="shell_mixed"
            p["stringers.shell_offsets"]=true
            only(filter(r->r["component"]=="stringer",p["materials.bars"]))["material"]=2
        end
        kind=="blade"&&(p["properties.stringer_flange_width"]=0.)
        kind=="swept"&&merge!(p,Dict("planform.sweep"=>35.,"planform.dihedral"=>7.,"planform.twist_tip"=>-4.,"planform.taper_ratio"=>.55,"mesh.elements_between_ribs"=>4))
        m=build(p);columns=W.stringer_euler_payload(m)
        elapsed=@elapsed columns=W.stringer_euler_payload(m)
        ready=filter(row->row["status"]=="ready",columns)
        compact=W.stringer_euler_payload(m;compact=true)
        push!(coverage,Dict("kind"=>kind,"columns"=>length(columns),"ready"=>length(ready),"seconds"=>elapsed,
            "reasons"=>unique(row["reason"] for row in columns)))
        @test !isempty(columns)
        kind=="swept"||(@test length(ready)==length(columns))
        for column in ready,station in column["stations"]
            matrix=stiffness(station)
            @test isposdef(Symmetric(matrix))
            @test column["length_m"]>0
            @test length(station["force_terms"])==length(unique(term["eid"] for term in station["force_terms"]))
            @test all(part["area_m2"]>0 for part in station["parts"])
            compact_column=only(filter(c->c["key"]==column["key"],compact))
            compact_station=only(filter(s->s["id"]==station["id"],compact_column["stations"]))
            @test stiffness(compact_station)≈matrix rtol=2e-13
            @test compact_station["force_terms"]==station["force_terms"]
            @test only(compact_station["parts"])["area_m2"]≈sum(p["area_m2"] for p in station["parts"])
            @test Set(only(compact_station["parts"])["property_ids"])==Set(p["pid"] for p in station["parts"])
        end
        write(joinpath(out,kind*"_columns.json"),JSON.json(columns))
        if kind in ("beam","shell_mixed")
            dir=joinpath(out,kind);mkpath(dir)
            write(joinpath(dir,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
            write(joinpath(dir,"schema.json"),JSON.json(W.schema_payload(m.params,"euler_fixture.toml")))
            write(joinpath(dir,"params.json"),JSON.json(m.params))
            open(joinpath(dir,"model.bdf"),"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
        end
        # Geometric spar boundaries survive removal of every cap bar.
        if kind=="beam"
            filter!(g->W.component_base_pid(g.pid)!=W.PID_SPAR_CAP,m.groups)
            @test all(row["status"]=="ready" for row in W.stringer_euler_payload(m))
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"geometry_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"coverage"=>coverage)))
println(JSON.json(coverage))
