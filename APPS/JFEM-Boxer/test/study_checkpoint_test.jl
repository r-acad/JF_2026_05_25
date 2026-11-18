using Test, WingFEGen
const W=WingFEGen

# Data-only fixture: exercises save/restore and fixed-load editing without an
# FE or aerodynamic solve. Binary fields use the same wire format as the solver.
function checkpoint_fixture()
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.rib_pitch"=>.5,"box.stringer_pitch"=>.16,"airfoil.root"=>"NACA0012",
        "airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"fuel.enabled"=>false,
        "loads.structure_inertia"=>false,"loads.cases"=>Any[Dict("id"=>2,"label"=>"Second load"),Dict("id"=>3,"label"=>"Pending load")]))
    m=W.build_model(first(W.normalize_params(p));summaries=false);p=deepcopy(m.params)
    groups=[Dict{String,Any}("pid"=>g.pid,"kind"=>String(g.kind),"count"=>length(g.eids),
        "n_per_elem"=>(g.kind==:quad ? 4 : g.kind==:tria ? 3 : 2),
        "eids"=>W.blob_i32(g.eids),"conn"=>W.blob_i32(g.conn;offset=-1),
        "properties"=>W.element_properties(m,g)) for g in m.groups if !isempty(g.eids)]
    mesh=Dict{String,Any}("format"=>"wingfegen-mesh-1","model_params"=>p,
        "nodes"=>Dict("count"=>length(m.node_ids),"ids"=>W.blob_i32(m.node_ids),"xyz"=>W.blob_f32(m.xyz)),
        "groups"=>groups,"loads"=>Dict("load_application_version"=>W.APPLIED_LOAD_VERSION))
    n=length(m.node_ids);eid=first(first(m.groups).eids)
    record=Dict{String,Any}("id"=>1,"node_count"=>n,"available"=>true,"partial"=>true,
        "analysis_type"=>"SOL101","source_model_params"=>p,"load_application_version"=>W.APPLIED_LOAD_VERSION,
        "static"=>Dict("disp"=>W.blob_f32(fill(.002,3n)),"rotation"=>W.blob_f32(zeros(3n))),
        "modes"=>Any[Dict("eigenvalue"=>123.,"shape"=>W.blob_f32(fill(.5,3n)))],
        "element_results"=>Dict{String,Any}(string(eid)=>Dict{String,Any}("stress"=>Dict("von_mises"=>123.),"strain"=>Dict("xx"=>1e-6),"forces"=>Dict("Nx"=>-20.))),
        "contours"=>Any[Dict("ids"=>W.blob_i32([eid]),"values"=>W.blob_f32([123.]))])
    variant=deepcopy(record);delete!(variant,"id");variant["analysis_type"]="SOL105"
    record["variants"]=Any[variant]
    second=deepcopy(record);second["id"]=2
    unavailable=Dict{String,Any}("id"=>3,"available"=>false,"message"=>"Not yet computed")
    results=Dict{String,Any}("format"=>"wingfegen-results-1","node_count"=>n,
        "source_model_params"=>p,"load_application_version"=>W.APPLIED_LOAD_VERSION,
        "load_cases"=>Any[record,second,unavailable])
    encode(value)=W.Base64.base64encode(W.MsgPack.pack(W.restore_payload_binary(value)))
    request=Dict{String,Any}("parameters"=>p,"mesh_base64"=>encode(mesh),"results_base64"=>encode(results))
    m,p,mesh,results,request,encode
end

@testset "Portable editable Study checkpoints" begin
    m,p,mesh,results,request,encode=checkpoint_fixture()
    original=deepcopy(p);checkpoint=W.study_checkpoint_create(request)
    @test checkpoint["compressed_bytes"]<checkpoint["uncompressed_bytes"]
    saved=W.checkpoint_unpack(checkpoint)
    @test saved["parameters"]==p
    @test saved["results"]["load_cases"][1]["element_results"]==results["load_cases"][1]["element_results"]
    @test length(saved["results"]["load_cases"][1]["variants"])==1
    @test saved["results"]["load_cases"][1]["partial"]
    @test saved["results"]["load_cases"][2]["id"]==2
    @test saved["results"]["load_cases"][3]["available"]==false
    @test saved["results"]["load_cases"][1]["static"]["disp"]==results["load_cases"][1]["static"]["disp"].bytes
    presentation=deepcopy(p);presentation["view.plan_view"]="{\"theme\":\"white\"}"
    presentation["assessment.strength_safety_factor"]=2.
    @test W.checkpoint_params_match(p,presentation)
    mktempdir() do dir
        input=joinpath(dir,"input.toml");write(input,W.params_to_toml(p))
        st=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(dir,"session"))
        @test st.model===nothing
        raw=Dict("parameters"=>p,"checkpoint"=>checkpoint)
        restored=W.study_checkpoint_restore(st,raw)
        @test st.model===nothing
        @test restored["mesh"]["nodes"]["xyz"] isa W.Blob
        @test restored["results"]["load_cases"][1]["static"]["disp"] isa W.Blob
        @test haskey(restored["mesh"],"component_buckling")
        W.STUDY_CHECKPOINT_STAGES[st]["created"]=time()-100000.
        @test W.checkpoint_finish!(st,restored["restore_token"];commit=true)["ok"]
        @test st.model!==nothing
        @test st.model.node_ids==m.node_ids
        @test st.model.params==p
        draft=deepcopy(p);draft["properties.t_skin_upper"]*=1.2
        @test W.rf_section_update(st.model,draft)["fixed_geometry"]
        existing=st.model
        second=W.study_checkpoint_restore(st,raw)
        @test st.model===existing
        @test W.checkpoint_finish!(st,second["restore_token"])["ok"]
        @test st.model===existing
        @test_throws ArgumentError W.checkpoint_finish!(st,second["restore_token"];commit=true)
        third=W.study_checkpoint_restore(st,raw)
        st.model=m
        @test_throws ArgumentError W.checkpoint_finish!(st,third["restore_token"];commit=true)
        W.checkpoint_finish!(st,third["restore_token"])
        fourth=W.study_checkpoint_restore(st,raw);oldparams=st.params;st.params=copy(st.params)
        @test_throws ArgumentError W.checkpoint_finish!(st,fourth["restore_token"];commit=true)
        W.checkpoint_finish!(st,fourth["restore_token"]);st.params=oldparams
        stale=deepcopy(p);stale["loads.lift_total"]+=1.
        @test_throws ArgumentError W.study_checkpoint_restore(st,Dict("parameters"=>stale,"checkpoint"=>checkpoint))
        # An edited/malicious archive has a valid checksum but fails native
        # geometry/section reconstruction before any server state is replaced.
        badmesh=W.MsgPack.unpack(W.MsgPack.pack(mesh));badmesh["nodes"]["xyz"][1]⊻=0x01
        badrequest=merge(request,Dict("mesh_base64"=>encode(badmesh)))
        badcheckpoint=W.study_checkpoint_create(badrequest)
        @test_throws ArgumentError W.study_checkpoint_restore(st,Dict("parameters"=>p,"checkpoint"=>badcheckpoint))
        @test st.model===m
        badsection=deepcopy(mesh);badsection["groups"][1]["properties"]["thickness_m"]*=2
        altered=W.study_checkpoint_create(merge(request,Dict("mesh_base64"=>encode(badsection))))
        @test_throws ArgumentError W.study_checkpoint_restore(st,Dict("parameters"=>p,"checkpoint"=>altered))
        @test st.model===m
    end
    corrupted=merge(checkpoint,Dict("sha256"=>"wrong"))
    @test_throws ArgumentError W.checkpoint_unpack(corrupted)
    @test_throws ArgumentError W.checkpoint_unpack(checkpoint;limit=32)
    @test_throws ArgumentError W.study_checkpoint_create(request;limit=32)
    garbage=UInt8[0x00,0x00,0x00]
    invalid=merge(checkpoint,Dict("data_base64"=>W.Base64.base64encode(garbage),"sha256"=>bytes2hex(W.SHA.sha256(garbage))))
    @test_throws ArgumentError W.checkpoint_unpack(invalid)
    for mutate in (
        r->r["load_cases"][1]["static"]["disp"]=W.blob_f32([0.]),
        r->r["load_cases"][1]["static"]["disp"]=W.blob_f32(fill(NaN,3length(m.node_ids))),
        r->r["load_cases"][1]["element_results"]["999999999"]=Dict("stress"=>1.),
        r->r["load_cases"][1]["element_results"][first(keys(r["load_cases"][1]["element_results"]))]["bad"]=Inf,
        r->r["load_cases"][1]["load_application_version"]="obsolete")
        candidate=deepcopy(results);mutate(candidate)
        @test_throws ArgumentError W.study_checkpoint_create(merge(request,Dict("results_base64"=>encode(candidate))))
    end
    @test p==original && m.params==original
end

@testset "Imported Study checkpoints preserve source and editable session identity" begin
    mktempdir() do dir
        input=joinpath(dir,"input.toml");write(input,W.params_to_toml(W.default_params()))
        st=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(dir,"session"))
        source=Dict{String,Any}("kind"=>"reference","name"=>"checkpoint_quad.bdf",
            "text"=>"SOL 101\nCEND\nSPC=1\nLOAD=2\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,1.,1.,0.\nGRID,4,,0.,1.,0.\nCQUAD4,1,1,1,2,3,4\nPSHELL,1,1,.002\nMAT1,1,7.E10,,.3,2700.\nSPC1,1,123456,1,4\nFORCE,2,3,0,1.,0.,0.,1.\nENDDATA\n")
        try
            response=W.handle_import_reference(st,W.HTTP.Request("POST","/api/import_reference",[],W.JSON.json(source)))
            @test response.status==200
            response.status==200||error(String(response.body))
            mesh=W.MsgPack.unpack(response.body);params=mesh["model_params"]
            results=Dict{String,Any}("format"=>"wingfegen-results-1","node_count"=>4,
                "imported_signature"=>mesh["imported_signature"],"imported_analysis"=>W.imported_analysis_options(),
                "load_application_version"=>W.IMPORTED_LOAD_VERSION,"available"=>true,
                "static"=>Dict("disp"=>W.blob_f32(zeros(12))),"element_results"=>Dict("1"=>Dict("forces"=>Dict("Nx"=>-1.))))
            encode(value)=W.Base64.base64encode(W.MsgPack.pack(W.restore_payload_binary(value)))
            raw=Dict{String,Any}("parameters"=>params,"mesh_base64"=>encode(mesh),"results_base64"=>encode(results),"imported_source"=>source)
            checkpoint=W.study_checkpoint_create(raw)
            previous=st.model;previous_token=mesh["imported_deck"]["token"]
            restored=W.study_checkpoint_restore(st,Dict("parameters"=>params,"checkpoint"=>checkpoint,"imported_source"=>source))
            @test st.model===previous
            @test restored["mesh"]["imported_deck"]["token"]!=previous_token
            W.checkpoint_finish!(st,restored["restore_token"];commit=true)
            @test W.is_imported_model(st.model)
            @test st.model.params["imported.source"]["text"]==source["text"]
            handle=merge(params,Dict("model_kind"=>"reference","imported_deck"=>restored["mesh"]["imported_deck"]))
            @test W.request_imported_model(Dict("parameters"=>handle)).node_ids==[1,2,3,4]
            wrong=deepcopy(source);wrong["text"]*= "\n"*string('$')*" changed source\n"
            @test_throws ArgumentError W.study_checkpoint_restore(st,Dict("parameters"=>params,"checkpoint"=>checkpoint,"imported_source"=>wrong))
            alternate=merge(source,Dict("analysis"=>Dict("solution"=>"103")))
            @test_throws ArgumentError W.study_checkpoint_restore(st,Dict("parameters"=>params,"checkpoint"=>checkpoint,"imported_source"=>alternate))
        finally
            # This test owns its parser session. Never signal any application
            # or solver process already running for the user.
            lock(W.IMPORT_WORKERS_LOCK) do
                for key in collect(keys(W.IMPORT_WORKERS))
                    endswith(key,"\n"*st.deck_store_dir)||continue
                    worker=pop!(W.IMPORT_WORKERS,key)
                    if process_running(worker.process);kill(worker.process);wait(worker.process);end
                end
            end
        end
    end
end
