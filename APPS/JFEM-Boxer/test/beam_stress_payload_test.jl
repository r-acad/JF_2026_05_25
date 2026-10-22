# Reprocess independently solved generated-model fixtures, without rerunning
# their FE solves. This checks the native-result -> Boxer records contract.
using Test, JSON, WingFEGen
const W=WingFEGen
fixture=abspath(ARGS[1]);recovery=abspath(ARGS[2]);out=abspath(ARGS[3]);mkpath(out)
m=W.build_model(first(W.normalize_params(JSON.parsefile(joinpath(fixture,"params.json")))))
groups=filter(g->g.kind===:bar&&W.component_base_pid(g.pid) in (W.PID_STRINGER,W.PID_RIB_STIFFENER),m.groups)
cases=Any[]
checks=@testset "Boxer equivalent stress from actual previous force recovery" begin
    @test !isempty(groups)
    for (solution,filename) in ((101,"sol101_native_results.json"),(106,"sol106_native_results.json"))
        result=JSON.parsefile(joinpath(recovery,filename))
        for (index,sub) in enumerate(result["subcases"])
            @test any(!haskey(s,"von_mises") for s in sub["stresses"]["cbar"])
            records=last(W.element_results_payload(m,sub))
            for group in groups,eid in group.eids
                record=records[string(eid)];stress=record["stress"]
                stress["von_mises_recovery"]["status"]=="complete"||error("P$(group.pid) E$eid: "*stress["von_mises_recovery"]["reason"])
                @test stress["von_mises_recovery"]["status"]=="complete"
                @test isfinite(stress["von_mises"])&&stress["von_mises"]>=0
                @test stress["von_mises"]>=abs(stress["axial"])*(1-1e-12)
                @test length(record["section_recovery_points_yz_m"])==8
            end
            # Scaling retains the same units and scales all mechanical
            # envelope components, not just the final scalar.
            enriched=deepcopy(sub)
            for row in enriched["stresses"]["cbar"]
                if haskey(records,string(row["eid"]))
                    data=records[string(row["eid"])]["stress"]
                    haskey(data,"von_mises")&&merge!(row,Dict("von_mises"=>data["von_mises"],"von_mises_recovery"=>deepcopy(data["von_mises_recovery"])))
                end
            end
            scaled=W.scaled_linear_result(enriched,.5)
            for (a,b) in zip(enriched["stresses"]["cbar"],scaled["stresses"]["cbar"])
                haskey(a,"von_mises")||continue
                @test b["von_mises"]==.5a["von_mises"]
                for key in ("normal_bound","transverse_shear_bound","torsional_shear_bound","combined_shear_bound","section_torque_bound")
                    @test b["von_mises_recovery"][key]==.5a["von_mises_recovery"][key]
                end
            end
            push!(cases,Dict("id"=>length(cases)+1,"label"=>"Actual SOL$solution case $index","solution"=>solution,
                "element_results"=>records,"load_scale"=>1.,"converged"=>true,"full_load"=>true))
        end
    end
    incomplete=Dict{String,Any}()
    group=first(groups);eid=first(group.eids)
    source=deepcopy(first(cases)["element_results"][string(eid)])
    delete!(source["stress"],"von_mises");delete!(source["stress"],"von_mises_recovery");delete!(source["forces"],"torque")
    incomplete[string(eid)]=source;W.complete_stringer_stresses!(m,incomplete)
    @test !haskey(source["stress"],"von_mises")
    @test occursin("torque",source["stress"]["von_mises_recovery"]["reason"])
    source["stress"]["von_mises_recovery"]=Dict("status"=>"unavailable","reason"=>"Native distributed-load scope limitation")
    W.complete_stringer_stresses!(m,incomplete)
    @test source["stress"]["von_mises_recovery"]["reason"]=="Native distributed-load scope limitation"
    section=W.section_definition(m.params,group.pid)
    native=Dict{String,Any}("SOL"=>101,"CASE_CONTROL"=>Dict("SUBCASES"=>Dict()),"SPC1s"=>Any[],
        "GRIDs"=>Dict("1"=>Dict("X"=>[0.,0.,0.]),"2"=>Dict("X"=>[1.,0.,0.])),
        "CBARs"=>Dict("1"=>Dict("ID"=>1,"PID"=>10,"GA"=>1,"GB"=>2,"V"=>[0.,1.,0.])),
        "PBARLs"=>Dict("10"=>Dict("MID"=>1,"TYPE"=>"T","DIMS"=>section["dimensions_m"],
            "A"=>section["area_m2"],"I1"=>section["I1_m4"],"I2"=>section["I2_m4"],"J"=>section["J_m4"])),
        "MATs"=>Dict("1"=>Dict("MID"=>1,"TYPE"=>"MAT1","E"=>70e9,"G"=>26.9e9,"NU"=>.3,"RHO"=>2700.)))
    imported=W.imported_model(native,W.imported_source(Dict("name"=>"t_section.bdf","text"=>"SOL 101\nCEND\nBEGIN BULK\nENDDATA\n")),m.params)
    imported_records=Dict("1"=>deepcopy(first(cases)["element_results"][string(eid)]))
    W.complete_stringer_stresses!(imported,imported_records)
    @test startswith(imported_records["1"]["stress_units"],"Source stress units")
    @test imported_records["1"]["stress"]["von_mises"]==first(cases)["element_results"][string(eid)]["stress"]["von_mises"]
    @test startswith(first(cases)["element_results"][string(eid)]["stress_units"],"Pa;")
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"payload_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>length(cases))))
write(joinpath(out,"browser_recovery_fixture.json"),JSON.json(Dict("provenance"=>"Previously solved physical SOL101/SOL106 cases reprocessed with complete-resultant T equivalent-stress envelope; no simulated FE results.","cases"=>cases)))
write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
write(joinpath(out,"schema.json"),JSON.json(W.schema_payload(m.params,"t_stress_recovery.toml")))
write(joinpath(out,"params.json"),JSON.json(m.params))
