# Runs the production editing handler and native parser on a synthetic closed
# fuselage. No private reference models or external solver are needed.
using Test, WingFEGen, Base64, LinearAlgebra
const W=WingFEGen

function fuselage_source()
    io=IOBuffer()
    println(io,"SOL 101\nCEND\nSUBCASE 1\n SPC = 1\n LOAD = 2\nBEGIN BULK\nMAT1,1,7.e10,,.3,2700.\nPSHELL,1,1,.002")
    # Four rectangular cross-section vertices, with several axial stations.
    for station in 0:4,corner in 1:4
        yz=((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))[corner]
        println(io,"GRID,",4station+corner,",,",station*5.,",",yz[1],",",yz[2])
    end
    eid=101
    for station in 0:3,corner in 1:4
        next=mod1(corner+1,4);println(io,"CQUAD4,$eid,1,",4station+corner,",",4(station+1)+corner,",",4(station+1)+next,",",4station+next);eid+=1
    end
    println(io,"SPC1,1,123456,1,THRU,4\nFORCE,2,20,0,100.,0.,0.,1.\nCONM2,990,6,-1,5.,5.,-1.,-1.\nENDDATA")
    String(take!(io))
end

function fe_request(st,action;kwargs...)
    raw=Dict{String,Any}("action"=>action)
    for (key,value) in kwargs;raw[String(key)]=value;end
    response=W.handle_fe_edit(st,W.HTTP.Request("POST","/api/fe_edit",[],W.JSON.json(raw)))
    payload=W.JSON.parse(String(response.body))
    response.status==200||error(get(payload,"error",string(payload)))
    payload
end

function native_beam_basis(native,kind,id)
    el=native[kind][string(id)]
    a=Float64.(native["GRIDs"][string(el["GA"])]["X"]);b=Float64.(native["GRIDs"][string(el["GB"])]["X"])
    direction=el["G0"]>0 ? Float64.(native["GRIDs"][string(el["G0"])]["X"])-a : Float64.(el["V"])
    x=normalize((b+Float64.(el["WB"]))-(a+Float64.(el["WA"])));z=normalize(cross(x,direction));y=cross(z,x)
    hcat(x,y,z)
end

@testset "Native FE editing transaction and stretch workflow" begin
    mktempdir() do dir
        app=normpath(joinpath(@__DIR__,".."));input=joinpath(dir,"input.toml");write(input,W.params_to_toml(W.default_params()))
        st=W.AppState(app,input;deck_store_dir=joinpath(dir,"cache"))
        try
            result=fe_request(st,"initialize";model_source=Dict("name"=>"fuselage.bdf","text"=>fuselage_source(),"format"=>"reference"))
            @test result["summary"]["nodes"]==20
            @test result["summary"]["elements"]==17
            @test result["undo_depth"]==0
            mesh=W.MsgPack.unpack(base64decode(result["mesh_msgpack_base64"]))
            @test mesh["imported_deck"]["token"]==st.model.params["imported.token"]
            @test mesh["model_source"]["text"]==result["source"]["text"]
            exact=fe_request(st,"node_coordinates";node_ids=[1,20])
            @test exact["node_coordinates"]["1"]==[0.,-1.,-1.]
            @test exact["nodes"][2]["id"]==20
            @test exact["revision"]==result["revision"]
            @test !haskey(exact,"source")&&!haskey(exact,"mesh_msgpack_base64")
            invalid=W.handle_fe_edit(st,W.HTTP.Request("POST","/api/fe_edit",[],W.JSON.json(Dict("action"=>"node_coordinates","node_ids"=>[999999]))))
            @test invalid.status!=200
            plane=Dict("point"=>[10.,0.,0.],"normal"=>[1.,0.,0.],"side_length"=>20.,"tolerance"=>1e-7)
            preview=fe_request(st,"preview";plane,selection=Dict("kind"=>"positive","plane"=>plane))
            @test !isempty(preview["selected_element_ids"])
            @test preview["revision"]==result["revision"]
            @test !isempty(preview["cut_segments"])
            @test all(length(segment)==2&&all(length(point)==3 for point in segment) for segment in preview["cut_segments"])
            compact=fe_request(st,"cut_preview";plane)
            @test compact["cut_segments"]==preview["cut_segments"]
            @test !haskey(compact,"source")&&!haskey(compact,"summary")&&!haskey(compact,"mesh_msgpack_base64")
            @test compact["revision"]==preview["revision"]
            smallpreview=fe_request(st,"preview";plane=merge(plane,Dict("side_length"=>.1)))
            @test isempty(smallpreview["cut_segments"])
            slabpreview=fe_request(st,"preview";plane,selection=Dict("kind"=>"slab","plane"=>plane,"second_plane"=>merge(plane,Dict("point"=>[15.,0.,0.]))))
            @test !isempty(slabpreview["second_cut_segments"])
            @test !isempty(slabpreview["second_intersected_element_ids"])
            result=fe_request(st,"cut";plane,duplicate_nodes=true)
            @test result["summary"]["nodes"]==24
            @test result["structural_part_count"]==2
            @test length(result["parts"])==2
            @test result["timings"]["native_verification_seconds"]>=0.
            @test result["timings"]["parts_seconds"]>=0.
            result=fe_request(st,"translate";selection=Dict("kind"=>"positive","plane"=>plane),vector=[5.,0.,0.])
            @test result["summary"]["bounds"]["max"][1]==25.
            plane9=merge(plane,Dict("point"=>[9.,0.,0.]))
            result=fe_request(st,"cut";plane=plane9,duplicate_nodes=true)
            selection=Dict("kind"=>"slab","plane"=>plane9,"second_plane"=>plane)
            result=fe_request(st,"copy";selection,vector=[1.,0.,0.],count=5)
            @test result["undo_depth"]==4
            deck=W.fe_edit_deck("result.bdf",result["source"]["text"])
            @test count(c->c.kind=="FORCE",deck.records)==1
            @test count(c->c.kind=="SPC1",deck.records)==1
            # CONM2 is at x=5 outside this slice; it is not spuriously repeated.
            @test count(c->c.kind=="CONM2",deck.records)==1
            candidates=fe_request(st,"candidates";tolerance=1e-6)
            @test length(candidates["candidate_groups"])>=4
            result=fe_request(st,"equivalence";groups=[g["nodes"] for g in candidates["candidate_groups"]],tolerance=1e-6)
            @test result["report"]["merged_nodes"]>=20
            @test isempty(fe_request(st,"candidates";tolerance=1e-6)["candidate_groups"])
            final=fe_request(st,"export")
            @test final["deck_text"]==result["source"]["text"]
            @test occursin("FORCE,2,20,0,100.,0.,0.,1.",final["deck_text"])
            before=st.model;revision=result["revision"]
            bad=W.handle_fe_edit(st,W.HTTP.Request("POST","/api/fe_edit",[],W.JSON.json(Dict("action"=>"translate","revision"=>revision-1,"selection"=>selection,"vector"=>[1.,0.,0.]))))
            @test bad.status!=200
            @test st.model===before
            @test fe_request(st,"context")["revision"]==revision
            undo=fe_request(st,"undo");@test undo["undo_depth"]==4
            reset=fe_request(st,"reset");@test reset["summary"]["nodes"]==20
            @test reset["undo_depth"]==0
            @test reset["source"]["text"]==W.FE_EDIT_SESSIONS[st].initial_source["text"]
            # Native GRID and mass parser sees the correct absolute CG shift.
            plane0=merge(plane,Dict("point"=>[-1.,0.,0.]))
            allmoved=fe_request(st,"translate";selection=Dict("kind"=>"positive","plane"=>plane0),vector=[2.,0.,0.])
            @test occursin("CONM2,990,6,-1,5.,7.0,-1.0,-1.0",allmoved["source"]["text"])
            triangular="SOL 101\nCEND\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nGRID,3,,0.,2.,0.\nCTRIA3,10,1,1,2,3,10.,.001,\n+,,0,.001,.003,.001\nPSHELL,1,1,.002\nMAT1,1,7.e10,,.3\nENDDATA\n"
            fe_request(st,"initialize";model_source=Dict("name"=>"tapered_triangle.bdf","text"=>triangular,"format"=>"reference"))
            fe_request(st,"cut";plane=Dict("point"=>[1.,0.,0.],"normal"=>[1.,0.,0.],"side_length"=>10.))
            native=W.imported_native(st.model)
            @test Set(el["TYPE"] for el in values(native["CSHELLs"]))==Set(["CTRIA3","CQUAD4"])
            for el in values(native["CSHELLs"])
                @test el["TFLAG"]==0
                @test el["ZOFFS"]==.001
                @test el["MCID_SPECIFIED"]
                for (id,t) in zip(el["NODES"],el["CORNER_THICKNESSES"])
                    @test t≈.001+.001native["GRIDs"][string(id)]["X"][1] atol=1e-12
                end
            end
            orphan=replace(fuselage_source(),"ENDDATA"=>"GRID,999,,10.1234567890123,0.,0.\nRBE3,9999,,999,123,1.0,123,9,10,11,12\nENDDATA")
            fe_request(st,"initialize";model_source=Dict("name"=>"orphan_spider.bdf","text"=>orphan,"format"=>"reference"))
            precise=fe_request(st,"node_coordinates";node_ids=[999])
            @test precise["node_coordinates"]["999"][1]==10.1234567890123
            @test precise["node_coordinates"]["999"][1]!=Float64(Float32(10.1234567890123))
            copied=fe_request(st,"copy";selection=Dict("kind"=>"positive","plane"=>plane0),vector=[30.,0.,0.],count=1)
            graph=W.imported_native(st.model)
            @test length(graph["RBE3s"])==2
            @test length(unique(el["REFGRID"] for el in values(graph["RBE3s"])))==2
            @test length(graph["GRIDs"])==42
            @test count(c->c.kind=="FORCE",W.fe_edit_records(copied["source"]["text"]))==1
            # Ambiguous source rigid connections deliberately stay attached to
            # original GRIDs. New structural aliases detach the positive part
            # without silently rewriting/removing those source definitions.
            rigidline="RBE3,9999,,999,123,1.0,123,5,10,15"
            staysline="RBE2,9998,999,123,1000"
            seam=replace(fuselage_source(),"ENDDATA"=>"GRID,999,,10.,0.,0.\nGRID,1000,,10.,0.,0.\n"*rigidline*"\n"*staysline*"\nENDDATA")
            fe_request(st,"initialize";model_source=Dict("name"=>"retained_rigids.bdf","text"=>seam,"format"=>"reference"))
            connected=fe_request(st,"part_at_element";element_id=101,plane)
            @test connected["requires_cut"]
            @test isempty(connected["element_ids"])
            @test occursin("duplicated seam",connected["warning"])
            seamcut=fe_request(st,"cut";plane,duplicate_nodes=true)
            @test 9999 in seamcut["report"]["retained_rigid_ids"]
            @test 9998 in seamcut["report"]["retained_rigid_ids"]
            @test occursin(rigidline,seamcut["source"]["text"])
            @test occursin(staysline,seamcut["source"]["text"])
            @test occursin("FE Utilities cut revision",seamcut["source"]["text"])
            @test occursin("Structural aliases (original -> new)",seamcut["source"]["text"])
            parts=fe_request(st,"parts";plane)
            @test parts["structural_part_count"]==2
            @test !haskey(parts,"source")
            posid=first(seamcut["report"]["side_elements"]["positive"])
            picked=fe_request(st,"part_at_element";element_id=posid,plane)
            @test picked["part"]["side"]=="positive"
            @test !picked["requires_cut"]
            @test !isempty(picked["element_ids"])
            seammoved=fe_request(st,"translate";element_ids=picked["element_ids"],vector=[5.,0.,0.])
            @test occursin(rigidline,seammoved["source"]["text"])
            @test occursin(staysline,seammoved["source"]["text"])
            retained=W.imported_native(st.model)
            @test retained["GRIDs"]["15"]["X"]==[15.,1.,1.]
            @test retained["GRIDs"]["999"]["X"]==[10.,0.,0.]
            @test retained["GRIDs"]["1000"]["X"]==[10.,0.,0.]
            positive=[el for el in values(retained["CSHELLs"]) if minimum(retained["GRIDs"][string(id)]["X"][1] for id in el["NODES"])>=15.0-1e-8]
            @test !isempty(positive)
            @test all(!(15 in el["NODES"]) for el in positive)
            @test maximum(node["X"][1] for node in values(retained["GRIDs"]))==25.
            crossed=fe_request(st,"part_at_element";element_id=posid,plane=merge(plane,Dict("point"=>[20.,0.,0.])))
            @test crossed["part"]["side"]=="crossing"
            @test !crossed["requires_cut"]
            @test crossed["element_ids"]==picked["element_ids"]
            exported=fe_request(st,"export")["deck_text"]
            fe_request(st,"initialize";model_source=Dict("name"=>"rigids_after_cut.bdf","text"=>exported,"format"=>"reference"))
            rerun=W.imported_native(st.model)
            @test rerun["RBE3s"]["9999"]["REFGRID"]==999
            @test rerun["GRIDs"]["15"]["X"]==[15.,1.,1.]
            @test rerun["GRIDs"]["999"]["X"]==[10.,0.,0.]
            before=st.model;revision=fe_request(st,"context")["revision"]
            collapse=W.handle_fe_edit(st,W.HTTP.Request("POST","/api/fe_edit",[],W.JSON.json(Dict("action"=>"equivalence","groups"=>[[999,1000]],"tolerance"=>1e-6))))
            @test collapse.status!=200
            @test st.model===before
            @test fe_request(st,"context")["revision"]==revision
            fe_request(st,"initialize";model_source=Dict("name"=>"rigids_before_move.bdf","text"=>seam,"format"=>"reference"))
            direct=fe_request(st,"translate";selection=Dict("kind"=>"positive","plane"=>plane),vector=[5.,0.,0.],detach_shared=true)
            @test 9999 in direct["report"]["retained_rigid_ids"]
            @test occursin(rigidline,direct["source"]["text"])
            @test occursin("FE Utilities translate revision",direct["source"]["text"])
            directnative=W.imported_native(st.model)
            @test directnative["GRIDs"]["15"]["X"]==[15.,1.,1.]
            @test directnative["GRIDs"]["999"]["X"]==[10.,0.,0.]
            beamtext="""
SOL 101
CEND
BEGIN BULK
CORD2R,41,0,100.,200.,300.,100.,200.,301.
+,100.,201.,300.
CORD2R,42,0,0.,0.,0.,0.,0.,1.
+,1.,1.,0.
GRID,1,41,0.,0.,0.,42
GRID,2,41,2.,0.,0.,42
GRID,3,41,0.,2.,1.
GRID,4,,0.,0.,0.
GRID,5,,0.,0.,2.
MAT1,1,7.e10,,.3,2700.
PBAR,7,1,.01,1.e-4,2.e-4,1.e-5
PBEAM,8,1,.01,1.e-4,2.e-4,0.,1.e-5,0.
CBAR,16019518,7,1,2,3,,,GGG
+,5,6,.1,.2,0.,.3,0.,.1
CBAR,16019519,7,4,5,2,,,GGG
CBEAM,16019520,8,1,2,3,,,GOO
+,0,0,.01,0.,0.,.02,0.,0.
ENDDATA
"""
            fe_request(st,"initialize";model_source=Dict("name"=>"native_G0_frames.bdf","text"=>beamtext,"format"=>"reference"))
            original=W.imported_native(st.model)
            originalframes=Dict(id=>native_beam_basis(original,kind,id) for (kind,id) in (("CBARs",16019518),("CBARs",16019519),("CBEAMs",16019520)))
            orientation=fe_request(st,"translate";element_ids=[16019518,16019520],vector=[4.,0.,0.])
            oriented=W.imported_native(st.model)
            @test Set(row["eid"] for row in orientation["report"]["beam_orientation_conversions"])==Set([16019518,16019519,16019520])
            @test oriented["GRIDs"]["1"]["X"]≈original["GRIDs"]["1"]["X"]+[4.,0.,0.]
            @test oriented["GRIDs"]["2"]["X"]≈original["GRIDs"]["2"]["X"]+[4.,0.,0.]
            @test oriented["GRIDs"]["3"]["X"]==original["GRIDs"]["3"]["X"]
            @test oriented["GRIDs"]["4"]["X"]==original["GRIDs"]["4"]["X"]
            @test oriented["GRIDs"]["5"]["X"]==original["GRIDs"]["5"]["X"]
            @test oriented["GRIDs"]["1"]["CD"]==42
            cards=W.fe_edit_deck("oriented.bdf",orientation["source"]["text"])
            for (kind,id) in (("CBARs",16019518),("CBARs",16019519),("CBEAMs",16019520))
                before=original[kind][string(id)];after=oriented[kind][string(id)]
                @test after["G0"]==0
                @test native_beam_basis(oriented,kind,id)≈originalframes[id] atol=1e-13
                @test after["WA"]==before["WA"]&&after["WB"]==before["WB"]
                @test after["PA"]==before["PA"]&&after["PB"]==before["PB"]
                row=only(filter(c->c.kind in ("CBAR","CBEAM")&&W.fe_edit_int(W.fe_edit_field(c,1))==id,cards.records))
                @test W.fe_edit_field(row,8)==(kind=="CBEAMs" ? "BOO" : "BGG")
            end
            jointext="""
SOL 101
CEND
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.,1.,0.
GRID,4,,0.,1.,0.
GRID,5,,3.,0.,0.
GRID,6,,4.,0.,0.
GRID,7,,4.,1.,0.
GRID,8,,3.,1.,0.
GRID,99,,10.,10.,0.
GRID,100,,10.,10.,0.
GRID,101,,1.,0.,0.
CQUAD4,1,1,1,2,3,4
CQUAD4,2,1,5,6,7,8
PSHELL,1,1,.002
MAT1,1,7.e10,,.3
ENDDATA
"""
            fe_request(st,"initialize";model_source=Dict("name"=>"copy_and_review.bdf","text"=>jointext,"format"=>"reference"))
            sourcebefore=W.imported_native(st.model)
            copied=fe_request(st,"copy";element_ids=[1],vector=[1.,0.,0.],count=1,coincidence_tolerance=1e-6)
            review=copied["operation_coincidences"]
            @test review["group_count"]==2
            @test review["revision"]==copied["revision"]
            @test review["affected_node_count"]==2
            @test !haskey(review,"cohorts")&&!haskey(review,"source_nodes")&&!haskey(review,"created_nodes")
            sourceafter=W.imported_native(st.model)
            @test all(sourcebefore["GRIDs"][id]["X"]==sourceafter["GRIDs"][id]["X"] for id in keys(sourcebefore["GRIDs"]))
            before=st.model;revision=copied["revision"]
            rejected=W.handle_fe_edit(st,W.HTTP.Request("POST","/api/fe_edit",[],W.JSON.json(Dict("action"=>"equivalence","operation_id"=>review["operation_id"],"groups"=>[Dict("nodes"=>[99,100],"retained_node"=>99)],"tolerance"=>1e-6))))
            @test rejected.status!=200
            @test st.model===before
            @test fe_request(st,"context")["revision"]==revision
            @test fe_request(st,"context")["operation_coincidences"]["operation_id"]==review["operation_id"]
            chosen=[Dict("nodes"=>unique(vcat([group["retained_node"]],group["affected_nodes"])),"retained_node"=>group["retained_node"]) for group in review["candidate_groups"]]
            glued=fe_request(st,"equivalence";operation_id=review["operation_id"],groups=chosen,tolerance=review["tolerance"])
            joined=W.imported_native(st.model)
            @test all(haskey(joined["GRIDs"],string(id)) for id in (2,3,99,100,101))
            @test joined["GRIDs"]["99"]["X"]==joined["GRIDs"]["100"]["X"]
            @test joined["GRIDs"]["2"]["X"]==joined["GRIDs"]["101"]["X"]
            @test glued["report"]["merged_nodes"]==2
            @test glued["operation_coincidences"]===nothing
            undone=fe_request(st,"undo")
            @test undone["operation_coincidences"]===nothing
            # This is the actual generated-model route, with normal defaults;
            # it freezes the app's own write_deck output into an editable BDF.
            generated=fe_request(st,"initialize";params=W.default_params())
            @test generated["summary"]["nodes"]>0
            @test generated["summary"]["elements"]>0
            @test W.is_imported_model(st.model)
            @test occursin("Lifting surface torsion box",generated["source"]["text"])
        finally
            # Only this test's isolated worker is stopped; no user app process
            # or shared persistent worker belongs to this private cache key.
            for (key,worker) in W.IMPORT_WORKERS
                occursin(st.deck_store_dir,key)&&process_running(worker.process)&&kill(worker.process)
            end
        end
    end
end
