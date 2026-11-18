# Streaming full matrices: bounded memory, explicit unavailable values and
# atomic publication. Partial output is never offered as a complete matrix.
rf_csv_escape(x)="\""*replace(string(x),'"'=>"\"\"")*"\""

function rf_matrix_sink(directory,responses,variables;quantity="utilization",preview_size=100,provenance=Dict())
    M,N=length(responses),length(variables);mkpath(directory)
    binary_path=joinpath(directory,"jacobian.f64.partial");csv_path=joinpath(directory,"jacobian.csv.partial")
    binary=open(binary_path,"w+");csv=open(csv_path,"w")
    println(csv,join(rf_csv_escape.(vcat(["response_id"],[v["id"] for v in variables])),','))
    preview=fill(NaN,min(M,preview_size),min(N,preview_size));next=Ref(1);closed=Ref(false)
    function push_block(start,stop,block)
        start==next[]&&size(block)==(stop-start+1,N)||throw(ArgumentError("RF matrix blocks must be contiguous with the declared shape"))
        for j in 1:N
            seek(binary,8*((j-1)*M+start-1));write(binary,collect(view(block,:,j)))
        end
        for (local_i,i) in enumerate(start:stop)
            println(csv,rf_csv_escape(responses[i]["response_id"]),',',
                join((isfinite(block[local_i,j]) ? repr(block[local_i,j]) : "" for j in 1:N),','))
            i<=size(preview,1)&&(preview[i,:].=view(block,local_i,1:size(preview,2)))
        end
        flush(binary);flush(csv);next[]=stop+1
        sensitivity_json_write(joinpath(directory,"matrix_progress.json"),
            Dict("completed_rows"=>stop,"total_rows"=>M,"columns"=>N,"quantity"=>quantity))
        nothing
    end
    function finish(;complete=true,derivative_complete=nothing)
        if !closed[];close(binary);close(csv);closed[]=true;end
        complete&&next[]!=M+1&&throw(ArgumentError("RF matrix export is incomplete"))
        metadata=Dict{String,Any}("file"=>"jacobian.f64","shape"=>[M,N],"dtype"=>"float64","order"=>"F",
            "endianness"=>ENDIAN_BOM==0x04030201 ? "little" : "big","quantity"=>quantity,
            "unavailable"=>"NaN; consult derivative reasons and row status",
            "response_ids"=>[r["response_id"] for r in responses],"variable_ids"=>[v["id"] for v in variables],
            "completed_rows"=>next[]-1,"complete"=>complete,"export_complete"=>complete,
            "derivative_complete"=>derivative_complete,
            "value_units"=>"dimensionless response per column unit",
            "columns"=>[Dict(k=>v[k] for k in ("id","label","unit","value","scale","lower_bound","upper_bound","members") if haskey(v,k)) for v in variables],
            "rows"=>[Dict(k=>r[k] for k in ("response_id","physical_criterion_id","case_id","failure_mode","membership_pids","membership_eids","status","derivative_status","gradient_class") if haskey(r,k)) for r in responses],
            "provenance"=>provenance)
        if complete
            mv(binary_path,joinpath(directory,"jacobian.f64");force=true)
            mv(csv_path,joinpath(directory,"jacobian.csv");force=true)
            metadata["sha256"]=open(SHA.sha256,joinpath(directory,"jacobian.f64"))
            metadata["sha256"]=bytes2hex(metadata["sha256"])
            sensitivity_json_write(joinpath(directory,"jacobian_metadata.json"),metadata)
        end
        metadata
    end
    (;push_block,finish,preview)
end
