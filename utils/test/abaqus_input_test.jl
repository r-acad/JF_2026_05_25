module AbaqusInputTests

using Test
include(joinpath(@__DIR__,"..","..","src","abaqus_input.jl"))

const TETMESH="""** Authored synthetic straight-sided quadratic tetrahedron
*Node, nset=all_nodes
11,0,0,0
12,1,0,0
13,0,1,0
14,0,0,1
15,.5,0,0
16,.5,.5,0
17,0,.5,0
18,0,0,.5
19,.5,0,.5
20,0,.5,.5
*Element, type=C3D10, elset=body
101,11,12,13,14,15,16,17,
18,19,20
*Nset, nset=fix
11,12,13,15,16,17
*Nset, nset=tip
14,18,19,20
*Surface,name=loaded,type=element
body,S1
"""
const PROPERTIES="""*Material,name=steel
*Elastic
210D9,.3
*Density
7800
*Solid Section,elset=body,material=steel
,
"""
const STATIC="""*Boundary
fix,1,3,0
*Step,name=Static
*Static
*Cload
tip,3,25
*End Step
"""
function resultant(raw,kind="FORCE";sid=1)
    result=zeros(3)
    for force in raw["bulk_data"][kind]
        force["SID"]==sid&&(result.+=force["Mag"].*force["Dir"])
    end
    return result
end

@testset "Wrapped topology, named sets, faces and missing physics" begin
    doc=abaqus_parse_input(TETMESH)
    @test length(doc["nodes"])==10
    @test doc["inventory"]["node_count"]==10&&doc["inventory"]["element_types"]==Dict("C3D10"=>1)
    orphan=abaqus_parse_input(TETMESH*"*NODE\n999,10,10,10\n")
    @test orphan["inventory"]["unused_node_ids"]==[999]&&haskey(orphan["nodes"],"999")
    @test doc["elements"]["101"]["nodes"]==collect(11:20)
    @test doc["node_sets"]["TIP"]==[14,18,19,20]
    @test doc["element_sets"]["BODY"]==[101]
    @test abaqus_element_face(doc["elements"]["101"],"S1")==[11,12,13,15,16,17]
    @test abaqus_element_face(doc["elements"]["101"],"S4")==[13,14,11,20,18,17]
    raw=abaqus_to_raw_model(doc;require_analysis=false)
    @test raw["bulk_data"]["CTETRA"]["101"]["ABAQUS_TYPE"]=="C3D10"
    @test length(raw["bulk_data"]["CTETRA"]["101"]["NODES"])==10
    @test raw["bulk_data"]["CTETRA"]["101"]["PID"]==0
    @test isempty(raw["bulk_data"]["MAT1"])
    @test !raw["abaqus_import"]["analysis_ready"]
    @test !haskey(raw["case_control"],"SOL")
    @test_throws ArgumentError abaqus_to_raw_model(doc)
    sets=abaqus_parse_input(TETMESH*"*NSET,NSET=previous,GENERATE\n11,13,1\n*NSET,NSET=combined\nprevious,tip\n*NSET,NSET=from_elements,ELSET=body\n")
    @test sets["node_sets"]["COMBINED"]==[11,12,13,14,18,19,20]
    @test sets["node_sets"]["FROM_ELEMENTS"]==collect(11:20)
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=a\nb\n*NSET,NSET=b\na\n")
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=bad\n999\n")
    @test_throws ArgumentError abaqus_parse_input(replace(TETMESH,"101,11,12"=>"101,999,12"))
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NODE\n11,1,2,3\n")
    @test_throws ArgumentError abaqus_parse_input(replace(TETMESH,"18,19,20\n"=>"18,19\n"))
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*Contact\n")
    unsupported=abaqus_parse_input(TETMESH*"*Contact\n";strict=false)
    @test any(d->d["code"]=="unsupported_keyword",unsupported["diagnostics"])
    @test !abaqus_to_raw_model(unsupported;require_analysis=false)["abaqus_import"]["analysis_ready"]
    reduced=abaqus_parse_input(replace(TETMESH,"C3D10"=>"C3D10M"))
    @test reduced["elements"]["101"]["type"]=="C3D10M"
    @test haskey(abaqus_to_raw_model(reduced;require_analysis=false)["abaqus_import"]["unsupported_elements"],"101")
end

@testset "Set membership snapshots and actionable LFS errors" begin
    sets=abaqus_parse_input(TETMESH*"""*NSET,NSET=a
11
*NSET,NSET=b
a
*NSET,NSET=a
12
*ELSET,ELSET=earlier
101
*NSET,NSET=nodes_now,ELSET=earlier
*NODE
21,2,0,0
*ELEMENT,TYPE=S3,ELSET=earlier
102,12,14,21
*ELSET,ELSET=copied
earlier
*ELEMENT,TYPE=S3,ELSET=earlier
103,12,19,21
""")
    @test sets["node_sets"]["A"]==[11,12]
    @test sets["node_sets"]["B"]==[11]
    @test sets["node_sets"]["NODES_NOW"]==collect(11:20)
    @test sets["element_sets"]["EARLIER"]==[101,102,103]
    @test sets["element_sets"]["COPIED"]==[101,102]
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=a\nlater\n*NSET,NSET=later\n11\n")
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*ELSET,ELSET=a\nlater\n*ELSET,ELSET=later\n101\n")
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=a,ELSET=later\n*ELSET,ELSET=later\n101\n")
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=a,GENERATE\n11,14,2\n")
    @test_throws ArgumentError abaqus_parse_input(TETMESH*"*NSET,NSET=a,ELSET=body,GENERATE\n")
    mktempdir() do folder
        pointer="version https://git-lfs.github.com/spec/v1\noid sha256:"*repeat("a",64)*"\nsize 123456\n"
        for suffix in (".inp",".inp.gz")
            path=joinpath(folder,"mesh"*suffix);write(path,pointer)
            err=try abaqus_read_input(path);nothing catch error;error end
            @test err isa ArgumentError
            @test occursin("Git LFS pointer",sprint(showerror,err))
            @test occursin("git lfs pull",sprint(showerror,err))
        end
    end
end

@testset "Explicit material, static loads and history" begin
    raw=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*STATIC))
    @test raw["abaqus_import"]["analysis_ready"]
    @test raw["case_control"]["SOL"]==101
    @test raw["bulk_data"]["MAT1"]["1"]["E"]==210e9
    @test raw["bulk_data"]["PSOLID"]["1"]["MID"]==1
    @test resultant(raw)==[0,0,100]
    @test length(raw["bulk_data"]["SPC1"])==18
    next="*STEP,NAME=Next\n*STATIC\n*CLOAD,OP=NEW\ntip,1,5\n*CLOAD,OP=NEW\ntip,2,7\n*END STEP\n"
    history=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*STATIC*next))
    @test resultant(history;sid=1)==[0,0,100]
    @test resultant(history;sid=2)==[20,28,0]
    @test length(filter(c->c["SID"]==2,history["bulk_data"]["SPC1"]))==18
    clear="*STEP\n*STATIC\n*CLOAD,OP=NEW\n*END STEP\n"
    cleared=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*STATIC*clear))
    @test resultant(cleared;sid=2)==zeros(3)
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(replace(TETMESH*PROPERTIES*STATIC,"*Step,name=Static"=>"*STEP,NLGEOM=YES")))
    @test_throws ArgumentError abaqus_parse_input(replace(TETMESH*PROPERTIES*STATIC,"*Cload"=>"*CLOAD,FOLLOWER"))
    @test_throws ArgumentError abaqus_parse_input(replace(PROPERTIES,"*Elastic"=>"*Elastic,type=ENGINEERING CONSTANTS"))
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*replace(STATIC,"tip,3,25"=>"tip,3,25\n14,3,10")))
    continued=abaqus_parse_input(replace(TETMESH,"*Element, type=C3D10, elset=body"=>"*ELEMENT,\nTYPE=C3D10,\nELSET=body"))
    @test continued["elements"]["101"]["nodes"]==collect(11:20)
end

@testset "Frequency controls and pressure consistency" begin
    modal="*BOUNDARY\nfix,1,3\n*STEP\n*FREQUENCY,NORMALIZATION=DISPLACEMENT\n12,2.5,400\n*END STEP\n"
    raw=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*modal))
    eig=raw["bulk_data"]["EIGRL"]["1"]
    @test raw["case_control"]["SOL"]==103
    @test eig["ND"]==12&&eig["V1"]==2.5&&eig["V2"]==400
    @test eig["NORM"]=="MAX"
    @test raw["parameters"]["COUPMASS"]==1
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*replace(modal,"2.5,400"=>"400,2.5")))
    @test_throws ArgumentError abaqus_parse_input(replace(modal,"NORMALIZATION=DISPLACEMENT"=>"EIGENSOLVER=SUBSPACE"))
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(TETMESH*replace(PROPERTIES,"7800"=>"0")*modal))
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*STATIC*modal))
    pressure=replace(STATIC,"*Cload\ntip,3,25"=>"*DLOAD\nbody,P1,600")
    pressured=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*pressure))
    # Face z=0 has area1/2, outward−z; positive pressure gives total +300z.
    @test resultant(pressured)≈[0,0,300] atol=1e-12
    for nid in (11,12,13)
        @test abs(sum(c["Mag"] for c in pressured["bulk_data"]["FORCE"] if c["GID"]==nid;init=0.))<1e-12
    end
    for nid in (15,16,17)
        @test sum(c["Mag"] for c in pressured["bulk_data"]["FORCE"] if c["GID"]==nid)≈100
    end
    surface=replace(STATIC,"*Cload\ntip,3,25"=>"*DSLOAD\nloaded,P,600")
    @test resultant(abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*surface)))≈[0,0,300] atol=1e-12
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(replace(TETMESH,"15,.5,0,0"=>"15,.5,0,.1")*PROPERTIES*pressure))
    gravity=replace(STATIC,"*Cload\ntip,3,25"=>"*DLOAD\nbody,GRAV,9.81,0,0,-2")
    grav=only(abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*gravity))["bulk_data"]["GRAV"])
    @test grav["A"]==9.81&&grav["N"]==[0,0,-1]
end

@testset "Portable includes, gzip and explicit completion" begin
    include_text="*INCLUDE,INPUT=\"sub/mesh.inp\"\n*INCLUDE,INPUT=props.inp\n"*STATIC
    files=Dict("sub/mesh.inp"=>TETMESH,"props.inp"=>PROPERTIES)
    resolver=(requested,containing)->(path=requested,text=files[requested])
    doc=abaqus_parse_input(include_text;include_resolver=resolver)
    @test length(doc["source_files"])==3
    @test !occursin("*INCLUDE",doc["expanded_source"])
    @test abaqus_to_raw_model(doc)["abaqus_import"]["analysis_ready"]
    @test_throws ArgumentError abaqus_parse_input(include_text)
    @test_throws ArgumentError abaqus_parse_input("*INCLUDE,INPUT=model.inp";include_resolver=(r,c)->"*INCLUDE,INPUT=model.inp")
    mktempdir() do folder
        mkpath(joinpath(folder,"sub"));write(joinpath(folder,"sub","mesh.inp"),TETMESH);write(joinpath(folder,"props.inp"),PROPERTIES)
        path=joinpath(folder,"model.inp.gz");write(path,CodecZlib.transcode(CodecZlib.GzipCompressor,Vector{UInt8}(codeunits(include_text))))
        readback=abaqus_read_input(path)
        @test length(readback["nodes"])==10
        @test length(readback["container_sha256"])==64
        @test abaqus_to_raw_model(readback)["abaqus_import"]["analysis_ready"]
    end
    mesh=abaqus_parse_input(TETMESH)
    settings=Dict{String,Any}("enabled"=>true,"E"=>70e9,"nu"=>.32,"rho"=>2700.,"element_set"=>"ALL","constraint_set"=>"fix","constraint_dofs"=>"123","force_set"=>"tip","force_direction"=>[0,0,-2],"total_force"=>120.,"solution"=>101,"modes"=>6)
    source=abaqus_complete_input(mesh,settings);completed=abaqus_to_raw_model(abaqus_parse_input(source))
    @test resultant(completed)==[0,0,-120]
    multi=abaqus_to_raw_model(abaqus_parse_input(abaqus_complete_input(mesh,merge(settings,Dict("constraint_set"=>"FIX;TIP")))))
    @test Set(only(c["NODES"]) for c in multi["bulk_data"]["SPC1"])==Set(11:20)
    @test length(multi["bulk_data"]["SPC1"])==30
    @test startswith(source,mesh["expanded_source"])
    @test isempty(mesh["materials"])&&isempty(mesh["steps"])
    @test abaqus_complete_input(mesh,merge(settings,Dict("enabled"=>false)))==mesh["expanded_source"]
    @test_throws ArgumentError abaqus_complete_input(doc,settings)
    @test_throws ArgumentError abaqus_complete_input(mesh,merge(settings,Dict("force_direction"=>[0,0,0])))
    @test_throws ArgumentError abaqus_complete_input(mesh,merge(settings,Dict("E"=>nothing)))
    modal=abaqus_to_raw_model(abaqus_parse_input(abaqus_complete_input(mesh,merge(settings,Dict("solution"=>103)))))
    @test modal["case_control"]["SOL"]==103&&modal["bulk_data"]["EIGRL"]["1"]["ND"]==6
end

@testset "Restart state and active continuum DOFs cannot be discarded" begin
    full=TETMESH*PROPERTIES*STATIC
    # Writing restart/output files does not alter the solve. Reading a previous
    # state is mechanical history, even when a complete mesh is also supplied.
    @test abaqus_to_raw_model(abaqus_parse_input("*RESTART,WRITE,FREQUENCY=1\n"*full))["abaqus_import"]["analysis_ready"]
    @test_throws ArgumentError abaqus_parse_input("*RESTART,READ,STEP=1\n"*full)
    @test_throws ArgumentError abaqus_parse_input("*RESTART,READ,WRITE\n"*full)
    restart=abaqus_parse_input("*RESTART,READ,STEP=1\n"*full;strict=false)
    @test occursin("*RESTART,READ",restart["expanded_source"])
    @test any(d->d["severity"]=="error"&&d["keyword"]=="RESTART",restart["diagnostics"])
    @test !abaqus_to_raw_model(restart;require_analysis=false)["abaqus_import"]["analysis_ready"]
    @test_throws ArgumentError abaqus_to_raw_model(restart)
    for dof in 4:6
        moment=replace(full,"tip,3,25"=>"14,$dof,25")
        @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(moment))
        motion=replace(full,"fix,1,3,0"=>"fix,1,3,0\n19,$dof,$dof,.01")
        @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(motion))
    end
    # Common zero ENCASTRE/symmetry notation remains usable for continuum nodes.
    encastre=abaqus_to_raw_model(abaqus_parse_input(replace(full,"fix,1,3,0"=>"fix,ENCASTRE")))
    @test encastre["abaqus_import"]["analysis_ready"]
    @test resultant(encastre)==[0,0,100]
    @test isempty(abaqus_to_raw_model(abaqus_parse_input(replace(full,"tip,3,25"=>"tip,6,0")))["bulk_data"]["MOMENT"])
    # A shared shell node has real rotational DOFs; a nearby solid-only midside
    # node still does not. The check is per node, not a blanket model-type ban.
    shell="*ELEMENT,TYPE=S3,ELSET=skin\n102,14,19,20\n*SHELL SECTION,ELSET=skin,MATERIAL=steel\n.01\n"
    mixed=TETMESH*PROPERTIES*shell*replace(STATIC,"tip,3,25"=>"14,6,25")
    raw=abaqus_to_raw_model(abaqus_parse_input(mixed))
    @test raw["abaqus_import"]["analysis_ready"]
    @test resultant(raw,"MOMENT")==[0,0,25]
    @test_throws ArgumentError abaqus_to_raw_model(abaqus_parse_input(replace(mixed,"14,6,25"=>"18,6,25")))
end

@testset "DLOAD and DSLOAD retain separate step histories" begin
    steps="""*BOUNDARY
fix,1,3
*STEP
*STATIC
*DLOAD
body,GRAV,9.81,0,0,-1
body,P1,120
*DSLOAD
loaded,P,240
*END STEP
*STEP
*STATIC
*DSLOAD,OP=NEW
loaded,P,600
*END STEP
*STEP
*STATIC
*DLOAD,OP=NEW
*END STEP
*STEP
*STATIC
*DSLOAD,OP=NEW
*END STEP
"""
    history=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*steps))
    @test [g["SID"] for g in history["bulk_data"]["GRAV"]]==[1,2]
    @test resultant(history;sid=1)≈[0,0,180] atol=1e-12
    @test resultant(history;sid=2)≈[0,0,360] atol=1e-12
    @test resultant(history;sid=3)≈[0,0,300] atol=1e-12
    @test resultant(history;sid=4)==zeros(3)
    # A replacement element load also keeps inherited surface pressure, and two
    # OP=NEW declarations in one family reset that family only once per step.
    replace_gravity=replace(steps,"*DLOAD,OP=NEW\n*END STEP"=>"*DLOAD,OP=NEW\nbody,GRAV,2,0,0,-1\n*DLOAD,OP=NEW\nbody,P1,80\n*END STEP")
    modified=abaqus_to_raw_model(abaqus_parse_input(TETMESH*PROPERTIES*replace_gravity))
    @test [g["SID"] for g in modified["bulk_data"]["GRAV"]]==[1,2,3,4]
    @test only(g["A"] for g in modified["bulk_data"]["GRAV"] if g["SID"]==3)==2
    @test resultant(modified;sid=3)≈[0,0,340] atol=1e-12
    @test resultant(modified;sid=4)≈[0,0,40] atol=1e-12
end

end # module AbaqusInputTests
