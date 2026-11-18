"""An export owns its new SolidCraft document and retains its construction receipts."""
mutable struct SolidCraftExportJob
    id::String
    state::String
    message::String
    started::Float64
    finished::Float64
    completed::Int
    total::Int
    cancelled::Bool
    folder::String
    result::Dict{String,Any}
end

const SOLIDCRAFT_EXPORT_LOCK = ReentrantLock()
const SOLIDCRAFT_EXPORT_JOBS = WeakKeyDict{Any,Dict{String,SolidCraftExportJob}}()

function solidcraft_export_status(job::SolidCraftExportJob)
    stop = job.finished > 0 ? job.finished : time()
    Dict{String,Any}("ok"=>true, "id"=>job.id, "state"=>job.state,
        "message"=>job.message, "seconds"=>round(stop-job.started; digits=1),
        "completed"=>job.completed, "total"=>job.total, "result"=>copy(job.result))
end

solidcraft_export_cancelled(job) = lock(SOLIDCRAFT_EXPORT_LOCK) do
    job.cancelled
end

function solidcraft_export_progress!(job, message)
    lock(SOLIDCRAFT_EXPORT_LOCK) do
        job.cancelled && throw(InterruptException())
        job.message = String(message)
    end
    yield()
end

function solidcraft_export_receipt(folder, name, value)
    open(joinpath(folder, name*".json"), "w") do io
        JSON.print(io, value, 2)
    end
end

"""Alternate native capping of the same polygon loft after a confirmed rollback."""
function solidcraft_alternate_cap_commands(body)
    commands = body["commands"]
    any(command->command["command"]=="sketch.spline.fit_point",commands) && return nothing
    lofts = filter(command->command["command"]=="surface.loft",commands)
    patches = filter(command->command["command"]=="surface.patch",commands)
    stitches = filter(command->command["command"]=="surface.stitch",commands)
    length(lofts)==1 && length(patches)==2 && length(stitches)==1 || return nothing
    loft = only(lofts)
    name = String(body["name"])
    get(loft["params"],"body_name",nothing)==name || return nothing
    sections = get(loft["params"],"sections",Any[])
    length(sections)>=2 || return nothing
    get(patches[1]["params"],"sketch",nothing)==get(first(sections),"sketch",nothing) || return nothing
    get(patches[2]["params"],"sketch",nothing)==get(last(sections),"sketch",nothing) || return nothing
    caps = [get(patch["params"],"body_name",nothing) for patch in patches]
    all(cap->cap isa String,caps) && get(only(stitches)["params"],"bodies",nothing)==vcat([name],caps) || return nothing
    # Both native paths use precisely the authored sketches. No tessellation,
    # projection, tolerance change or section movement is used for this retry.
    alternate = Any[]
    for command in commands
        operation = command["command"]
        if operation=="surface.loft"
            parameters = deepcopy(command["params"])
            parameters["operation"] = "new"
            push!(alternate,Dict("command"=>"solid.loft","params"=>parameters))
        elseif !(operation in ("surface.patch","surface.stitch"))
            push!(alternate,command)
        end
    end
    alternate
end

function solidcraft_cap_retry_allowed(error)
    error isa SolidCraftToolError && error.tool=="batch" || return false
    details = error.details
    details isa AbstractDict || return false
    failed = get(details,"failed",nothing)
    failed isa AbstractDict || return false
    get(failed,"command","") in ("surface.loft","surface.patch","surface.stitch") || return false
    index = get(failed,"index",nothing)
    undone = get(details,"undone",nothing)
    applied = get(details,"applied",nothing)
    index isa Integer && undone isa Integer && undone>=index &&
        applied isa AbstractVector && isempty(applied)
end

"""Discover atomic recovery before any component changes the isolated document."""
function solidcraft_cap_checkpoints_supported(bridge)
    commands = solidcraft_tool!(bridge,"list_commands",Dict("filter"=>"checkpoint"))
    commands isa AbstractVector || error("SolidCraft returned an unreadable checkpoint command catalog.")
    names = Set(String(get(command,"id","")) for command in commands if command isa AbstractDict)
    "edit.checkpoint" in names && "edit.restore_checkpoint" in names
end

"""Compact native state used to prove a component rollback preserved the earlier design."""
function solidcraft_cap_baseline(bridge)
    state = solidcraft_tool!(bridge,"execute",Dict("command"=>"document.inspect","params"=>Dict(
        "bodies"=>"names","timeline"=>"summary","sketch_counts"=>true)))
    state isa AbstractDict && get(state,"bodies",nothing) isa AbstractVector &&
        get(state,"timeline",nothing) isa AbstractVector && get(state,"sketches",nothing) isa AbstractVector &&
        get(state,"undo",nothing) isa Integer || error("SolidCraft could not record a safe component recovery state.")
    baseline = deepcopy(Dict{String,Any}(state))
    # Native revisions remain monotonic even when every design/undo field is restored.
    delete!(baseline,"revision")
    baseline
end

function solidcraft_cap_checkpoint!(bridge)
    value = solidcraft_tool!(bridge,"execute",Dict("command"=>"edit.checkpoint","params"=>Dict{String,Any}()))
    id = value isa AbstractDict ? get(value,"checkpoint",nothing) : nothing
    id isa Integer && !(id isa Bool) && id>=0 || error("SolidCraft did not create a component recovery checkpoint.")
    id
end

function solidcraft_cap_restore!(bridge,id,baseline)
    value = solidcraft_tool!(bridge,"execute",Dict("command"=>"edit.restore_checkpoint","params"=>Dict("checkpoint"=>id)))
    value isa AbstractDict && get(value,"checkpoint",nothing)==id && get(value,"restored",false)===true ||
        error("SolidCraft did not confirm restoration of the component checkpoint. No alternate geometry was attempted.")
    restored = solidcraft_cap_baseline(bridge)
    restored==baseline || error("SolidCraft checkpoint restoration changed the preceding design. No alternate geometry was attempted.")
    value
end

function solidcraft_cap_forget!(bridge,id)
    value = solidcraft_tool!(bridge,"execute",Dict("command"=>"edit.restore_checkpoint","params"=>Dict("checkpoint"=>id,"forget"=>true)))
    value isa AbstractDict && get(value,"checkpoint",nothing)==id && get(value,"restored",nothing)===false ||
        error("SolidCraft did not release the component checkpoint.")
    nothing
end

function solidcraft_cap_measurement(bridge,name)
    value = solidcraft_tool!(bridge,"measure",Dict("body"=>name,"summary"=>true))
    rows = value isa AbstractDict ? get(value,"bodies",nothing) : nothing
    rows isa AbstractVector && length(rows)==1 && only(rows) isa AbstractDict &&
        get(only(rows),"name",nothing)==name || error("SolidCraft did not return a unique measurement for $name.")
    body = only(rows)
    get(body,"closed",nothing) isa Bool && haskey(body,"volume_mm3") ||
        error("SolidCraft did not return closure and volume for $name.")
    volume = body["volume_mm3"]
    valid = body["closed"]===true && volume isa Real && !(volume isa Bool) && isfinite(volume) && volume>0
    valid,value
end

"""Construct one polygon member, recovering native open-stitch results over unchanged sections."""
function solidcraft_construct_body!(bridge,job,body,index,checkpoints,progress)
    alternate = solidcraft_alternate_cap_commands(body)
    alternate===nothing && return (solidcraft_tool!(bridge,"batch",Dict("commands"=>body["commands"],
        "rollback"=>true,"verbose"=>false,"timings"=>true)),false)

    prefix = "body_"*lpad(index,5,'0')
    baseline = checkpoints ? solidcraft_cap_baseline(bridge) : nothing
    checkpoint = checkpoints ? solidcraft_cap_checkpoint!(bridge) : nothing
    checkpoint_active = checkpoints
    try
        receipt = nothing
        native_error = nothing
        try
            receipt = solidcraft_tool!(bridge,"batch",Dict("commands"=>body["commands"],
                "rollback"=>true,"verbose"=>false,"timings"=>true))
        catch error
            solidcraft_cap_retry_allowed(error) || rethrow()
            native_error = error
        end

        if native_error===nothing
            valid,measurement = solidcraft_cap_measurement(bridge,String(body["name"]))
            solidcraft_export_receipt(job.folder,prefix*"_geometry_check",measurement)
            if valid
                checkpoints && solidcraft_cap_forget!(bridge,checkpoint)
                checkpoint_active = false
                return receipt,false
            end
            # Stitch can succeed with a warning while leaving real boundary edges.
            # A successful batch is not proof of a closed, positive-volume member.
            solidcraft_export_receipt(job.folder,prefix*"_cap_error",Dict(
                "message"=>"Native capping left an open or non-positive-volume body.",
                "details"=>receipt,"measurement"=>measurement))
            checkpoints || error("SolidCraft left $(body["name"]) open. This SolidCraft version has no atomic component checkpoints; update SolidCraft before retrying. No partial model was opened.")
        else
            solidcraft_export_receipt(job.folder,prefix*"_cap_error",Dict(
                "tool"=>native_error.tool,"message"=>native_error.message,"details"=>native_error.details))
        end

        if checkpoints
            restoration = solidcraft_cap_restore!(bridge,checkpoint,baseline)
            checkpoint_active = false
            solidcraft_export_receipt(job.folder,prefix*"_checkpoint_restore",Dict(
                "native"=>restoration,"preceding_design_verified"=>true))
        end
        progress("Retrying native capping for $(body["name"]) with the original sections")
        solidcraft_export_receipt(job.folder,prefix*"_cap_retry",Dict("commands"=>alternate,
            "preserved_profiles"=>true,"rollback_verified"=>true,
            "atomic_checkpoint"=>checkpoints))
        retried = solidcraft_tool!(bridge,"batch",Dict("commands"=>alternate,
            "rollback"=>true,"verbose"=>false,"timings"=>true))
        valid,measurement = solidcraft_cap_measurement(bridge,String(body["name"]))
        solidcraft_export_receipt(job.folder,prefix*"_retry_geometry_check",measurement)
        valid || error("SolidCraft's alternate native capping did not produce a closed positive-volume solid for $(body["name"]).")
        return retried,true
    finally
        if checkpoint_active
            if solidcraft_export_cancelled(job)
                # The outer finally closes this owned isolated session. Avoid new
                # work after Cancel; closing the session also discards its checkpoints.
                solidcraft_export_receipt(job.folder,prefix*"_checkpoint_cleanup",Dict(
                    "cancelled"=>true,"release"=>"Closing the isolated construction session"))
            else
                try
                    solidcraft_cap_restore!(bridge,checkpoint,baseline)
                    solidcraft_export_receipt(job.folder,prefix*"_checkpoint_cleanup",Dict("restored"=>true))
                catch cleanup_error
                    # Never attempt another component after unconfirmed restoration.
                    # The original failure propagates and the owned session is closed.
                    solidcraft_export_receipt(job.folder,prefix*"_checkpoint_cleanup",Dict(
                        "restored"=>false,"error"=>sprint(showerror,cleanup_error),
                        "release"=>"Closing the isolated construction session"))
                end
            end
        end
    end
end

function run_solidcraft_export!(job, params, options)
    bridge = nothing
    progress = message -> solidcraft_export_progress!(job, message)
    try
        progress("Evaluating the current Study geometry")
        plan = solidcraft_geometry(params; include_structure=options["structure"],
            mirror=options["mirror"], deflected=options["deflected"], progress)
        bodies = plan["bodies"]
        isempty(bodies) && throw(ArgumentError("The Study produced no solid wing bodies."))
        names = [String(body["name"]) for body in bodies]
        length(unique(names)) == length(names) || error("The CAD plan contains duplicate body names.")
        lock(SOLIDCRAFT_EXPORT_LOCK) do
            job.total = length(bodies)
        end
        solidcraft_export_receipt(job.folder, "construction", plan)
        bridge = solidcraft_start_session(; cli_path=options["cli_path"],
            app_path=options["app_path"], allow_path=job.folder,
            log_path=joinpath(job.folder,"bridge.log"), headless=true, progress,
            cancelled=()->solidcraft_export_cancelled(job))
        title = String(get(params,"output.title","JFEM-Boxer wing"))
        initial = solidcraft_tool!(bridge,"inspect_design",Dict("measure"=>false,"sketches"=>true))
        isempty(get(initial,"bodies",Any[])) && isempty(get(initial,"sketches",Any[])) ||
            error("The new SolidCraft construction session restored an existing design. Export stopped before modifying that document.")
        solidcraft_tool!(bridge, "new_design", Dict("name"=>title))
        solidcraft_export_receipt(job.folder, "bridge", Dict("server"=>bridge.server_info,
            "address"=>bridge.address, "cli"=>bridge.cli_path, "application"=>bridge.app_path))

        cap_retries = 0
        checkpoints = solidcraft_cap_checkpoints_supported(bridge)
        for (index, body) in enumerate(bodies)
            progress("Creating $(body["name"])")
            receipt,retried = solidcraft_construct_body!(bridge,job,body,index,checkpoints,progress)
            cap_retries += retried
            solidcraft_export_receipt(job.folder,"body_"*lpad(index,5,'0'),receipt)
            lock(SOLIDCRAFT_EXPORT_LOCK) do
                job.completed = index
            end
        end

        progress("Organizing SolidCraft components")
        appearance = Any[]
        groups = Dict{String,Vector{String}}()
        for body in bodies
            name = String(body["name"])
            group = String(get(body,"group","Wing"))
            push!(get!(()->String[],groups,group),name)
            push!(appearance,Dict("command"=>"appearance.assign","params"=>Dict(
                "bodies"=>[name],"color"=>get(body,"color","#76b6dc"),
                "opacity"=>get(body,"opacity",1.0))))
        end
        for group in sort!(collect(keys(groups)))
            push!(appearance,Dict("command"=>"browser.group","params"=>Dict(
                "folder"=>"bodies","name"=>group,"items"=>groups[group])))
        end
        append!(appearance,[Dict("command"=>"browser.visibility","params"=>Dict("folder"=>"sketches","visible"=>false)),
            Dict("command"=>"view.grid","params"=>Dict("on"=>false)),
            Dict("command"=>"view.isometric","params"=>Dict{String,Any}()),
            Dict("command"=>"view.fit","params"=>Dict{String,Any}()),
            Dict("command"=>"document.metadata.set","params"=>Dict("values"=>Dict(
                "org.openjfem.boxer"=>Dict("source"=>"JFEM-Boxer Study",
                    "source_parameters_sha256"=>bytes2hex(SHA.sha256(JSON.json(params))),
                    "source_request"=>joinpath(job.folder,"request.json"),
                    "components"=>[Dict("name"=>body["name"],"group"=>get(body,"group","Wing"),
                        "metadata"=>get(body,"metadata",Dict{String,Any}())) for body in bodies],
                    "native_cap_retries"=>cap_retries,
                    "options"=>options, "notes"=>get(plan,"notes",Any[]),
                    "source_units"=>"m","cad_units"=>"mm"))))])
        styled = solidcraft_tool!(bridge,"batch",Dict("commands"=>appearance,"rollback"=>true,"verbose"=>false))
        solidcraft_export_receipt(job.folder,"appearance",styled)

        progress("Checking closed solids and volumes")
        inspection = solidcraft_tool!(bridge,"inspect_design",Dict("measure"=>true,"sketches"=>false))
        solidcraft_export_receipt(job.folder,"inspection",inspection)
        get(inspection,"units","")=="mm" || error("SolidCraft returned unexpected model units.")
        inspected_bodies = get(inspection,"bodies",Any[])
        actual = Dict(String(body["name"])=>body for body in inspected_bodies)
        invalid = String[]
        for name in names
            body = get(actual,name,Dict{String,Any}())
            volume = get(body,"volume_mm3",0.0)
            if get(body,"closed",false)!==true || !(volume isa Real && isfinite(volume) && volume>0)
                push!(invalid,name)
            end
        end
        isempty(invalid) || error("SolidCraft could not verify closed positive-volume solids for "*join(invalid,", "))
        length(inspected_bodies)==length(actual)==length(names) || error("The SolidCraft body count differs from the construction plan.")
        any(step->(value=get(step,"error",nothing); value!==nothing && value!==false && !isempty(string(value))),
            get(inspection,"timeline",Any[])) &&
            error("SolidCraft reported an error in the completed construction history.")

        progress("Saving the SolidCraft model")
        filename = first(replace(title,r"[^\p{L}\p{N}_.-]+"=>"_"),48)
        isempty(filename) && (filename="JFEM_Boxer_wing")
        path = joinpath(job.folder,"Wing_"*filename*".sc")
        saved = solidcraft_tool!(bridge,"save",Dict("path"=>path))
        solidcraft_export_receipt(job.folder,"save",saved)
        verification_path = path
        if Sys.iswindows() && !startswith(path,"\\\\?\\")
            verification_path = startswith(path,"\\\\") ? "\\\\?\\UNC\\"*path[3:end] : "\\\\?\\"*abspath(path)
        end
        isfile(verification_path) && filesize(verification_path)>0 || error("SolidCraft did not create the requested native model file.")
        lock(SOLIDCRAFT_EXPORT_LOCK) do
            job.result = Dict("title"=>title,"path"=>path,"bodies"=>length(actual),
                "closed_solids"=>length(names),"notes"=>get(plan,"notes",Any[]),
                "source_units"=>"m","cad_units"=>"mm","native_cap_retries"=>cap_retries)
        end

        # Publish only the fully constructed, checked and saved document. A failed
        # body must never leave a plausible-looking partial wing in a new window.
        progress("Opening the complete saved model in SolidCraft")
        publication = solidcraft_show_model!(bridge,path; expected_names=names,
            expected_inspection=inspection, progress,
            cancelled=()->solidcraft_export_cancelled(job))
        solidcraft_export_receipt(job.folder,"publication",publication)
        lock(SOLIDCRAFT_EXPORT_LOCK) do
            job.result["publication"] = Dict(key=>publication[key]
                for key in ("address","path","bodies","server") if haskey(publication,key))
            job.state = "done"
            job.message = "Opened the complete SolidCraft model with $(length(names)) closed solids"
        end
    catch error
        lock(SOLIDCRAFT_EXPORT_LOCK) do
            if error isa InterruptException || job.cancelled
                job.state = "cancelled"
                job.message = haskey(job.result,"path") ?
                    "Opening in SolidCraft was cancelled. The complete native model is saved and can be opened using the path below." :
                    "Export cancelled after $(job.completed) / $(job.total) bodies. No partial model was opened in SolidCraft."
            else
                job.state = "failed"
                job.message = "SolidCraft export failed during "*job.message*". "*sprint(showerror,error)
                haskey(job.result,"path") && (job.message *= " The complete native model is saved and can be opened using the path below.")
            end
        end
        if error isa SolidCraftToolError
            try
                solidcraft_export_receipt(job.folder,"native_error",Dict("tool"=>error.tool,
                    "message"=>error.message,"details"=>error.details))
            catch receipt_error
                @warn "Could not save SolidCraft error diagnostics" exception=receipt_error
            end
        end
    finally
        bridge === nothing || close(bridge)
        status = lock(SOLIDCRAFT_EXPORT_LOCK) do
            job.finished = time()
            solidcraft_export_status(job)
        end
        try
            solidcraft_export_receipt(job.folder,"result",status)
        catch receipt_error
            @warn "Could not save SolidCraft export receipt" exception=receipt_error
        end
    end
end

function solidcraft_export_options(raw)
    raw isa AbstractDict || throw(ArgumentError("Expected SolidCraft export options."))
    options = Dict{String,Any}()
    for (key, default) in (("structure",true),("mirror",false),("deflected",false))
        value = get(raw,key,default)
        value isa Bool || throw(ArgumentError("SolidCraft $key must be enabled or disabled."))
        options[key] = value
    end
    for key in ("cli_path","app_path")
        value = get(raw,key,"")
        value isa AbstractString || throw(ArgumentError("Expected an executable path for $key."))
        options[key] = String(value)
    end
    options
end

function handle_solidcraft_export(st, req; action="start")
    try
        if action=="start"
            raw = study_save_request(req)
            raw isa AbstractDict || throw(ArgumentError("Expected a SolidCraft export request."))
            input = get(raw,"parameters",nothing)
            input isa AbstractDict || throw(ArgumentError("Expected the current Study parameters."))
            haskey(input,"imported_deck") && throw(ArgumentError("Open a generated wing Study to export its solid geometry."))
            params,_ = normalize_params(input;validate=false)
            options = solidcraft_export_options(get(raw,"options",Dict{String,Any}()))
            return lock(SOLIDCRAFT_EXPORT_LOCK) do
                jobs = get!(()->Dict{String,SolidCraftExportJob}(),SOLIDCRAFT_EXPORT_JOBS,st)
                any(job->job.state=="running",values(jobs)) && return error_response("A SolidCraft export is already running.";status=409)
                id = "solidcraft_"*bytes2hex(rand(UInt8,8))
                folder = joinpath(st.deck_store_dir,"solidcraft",id)
                mkpath(folder)
                solidcraft_export_receipt(folder,"request",Dict("parameters"=>params,"options"=>options))
                job = SolidCraftExportJob(id,"running","Preparing the current Study geometry",time(),0.,0,0,false,folder,Dict{String,Any}())
                jobs[id] = job
                Threads.@spawn run_solidcraft_export!(job,params,options)
                old = sort!([j for j in values(jobs) if j.state!="running"];by=j->j.started)
                for expired in old[1:max(0,length(old)-8)]
                    delete!(jobs,expired.id)
                end
                json_response(solidcraft_export_status(job))
            end
        end
        action=="cancel" && study_save_request(req)
        query = HTTP.queryparams(HTTP.URI(req.target))
        id = get(query,"job","")
        lock(SOLIDCRAFT_EXPORT_LOCK) do
            jobs = get(SOLIDCRAFT_EXPORT_JOBS,st,Dict{String,SolidCraftExportJob}())
            haskey(jobs,id) || return error_response("Unknown SolidCraft export.";status=404)
            job = jobs[id]
            if action=="cancel" && job.state=="running"
                job.cancelled = true
                job.message = "Cancelling the SolidCraft export"
            end
            json_response(solidcraft_export_status(job))
        end
    catch error
        error_response("SolidCraft export: "*describe_error(error))
    end
end

function stop_solidcraft_exports!(st)
    lock(SOLIDCRAFT_EXPORT_LOCK) do
        for job in values(get(SOLIDCRAFT_EXPORT_JOBS,st,Dict{String,SolidCraftExportJob}()))
            job.state=="running" && (job.cancelled=true)
        end
    end
end
