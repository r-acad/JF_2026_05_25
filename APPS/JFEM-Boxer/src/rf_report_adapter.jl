# Ordinary Stress Report and fixed-force previews use the same native physical
# RF values as derivatives. This endpoint performs postprocessing only: it never
# meshes, solves, mutates AppState or relabels an estimate as equilibrated.

function rf_report_response_ids(input)
    cases,_=rf_native_cases(input);mode=string(rf_get(input,"failureMode","von_mises"))
    mode in ("critical_case","critical_failure")&&(mode="minimum_rf")
    mode in ("minimum_rf","von_mises","principal_strain","euler_column","stringer_blade","skin_buckling","spar_web_buckling","rib_web_buckling","spar_cap_buckling","rib_stiffener_buckling","rib_stiffener_blade")||throw(ArgumentError("Unknown physical RF report mode $mode"))
    ids=String[];allmodes=mode=="minimum_rf"
    for item in cases
        suffix=item["case_key"]
        if allmodes||mode in ("von_mises","principal_strain")
            for (pid,elements) in rf_region_elements(input)
                mode=="principal_strain"&&!any(rf_get(e.property,"type","")=="PCOMP" for e in elements)&&continue
                push!(ids,"material:P$pid:$suffix")
            end
            for spec in rf_material_region_specs(input)
                mode=="principal_strain"&&!any(rf_get(e.property,"type","")=="PCOMP" for e in spec.elements)&&continue
                push!(ids,"$(spec.scope):$suffix")
            end
        end
        for (field,failure) in (("eulerColumns","euler_column"),("stringerBlades","stringer_blade"),("skinBucklingPanels","skin_buckling"))
            allmodes||mode==failure||continue
            for raw in rf_get(input,field,Any[])
                rf_get(raw,"applicable",true)===false&&continue
                push!(ids,"$failure:$(rf_get(raw,"key","unknown")):$suffix")
            end
        end
        components=rf_get(input,"componentBuckling",Dict())
        for (field,kind,failure) in (("web_panels","spar_web","spar_web_buckling"),("web_panels","rib_web","rib_web_buckling"),("columns","spar_cap","spar_cap_buckling"),("columns","rib_stiffener","rib_stiffener_buckling"),("blades","rib_stiffener_blade","rib_stiffener_blade"))
            allmodes||mode==failure||continue
            for raw in rf_get(components,field,Any[])
                rf_get(raw,"kind","")==kind&&rf_get(raw,"applicable",true)!==false||continue
                push!(ids,"$failure:$(rf_get(raw,"key","unknown")):$suffix")
            end
        end
    end
    unique(ids)
end

"""POST /api/rf_assessment body: ordinary stress-report input or {input: ...}.
Returns native physical response values and presentation metadata. No FE solve.
"""
function rf_report_assessment(raw;progress=(_)->nothing,cancelled=()->false)
    input=rf_get(raw,"input",raw)
    input isa AbstractDict||throw(ArgumentError("Native RF assessment input must be an object"))
    value=Dict{String,Any}(string(k)=>v for (k,v) in pairs(input))
    if !haskey(value,"response_ids")||isempty(value["response_ids"])
        value["response_ids"]=rf_report_response_ids(value)
    end
    value["restrict_responses"]=true
    started=time();assessment=rf_assessment_values(value;derivatives=false,progress,cancelled)
    Dict{String,Any}("ok"=>true,"format"=>"jfem-native-rf-report-1","backend"=>"native",
        "postprocessing_only"=>true,"estimated"=>rf_get(value,"estimated",false),
        "seconds"=>time()-started,"assessment"=>Dict(k=>(k=="responses" ? [rf_public_response(row) for row in v] : rf_native_public_safe(v)) for (k,v) in assessment))
end
