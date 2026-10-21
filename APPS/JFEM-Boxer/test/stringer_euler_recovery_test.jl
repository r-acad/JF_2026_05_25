using Test, JSON, WingFEGen, OpenJFEM
const W=WingFEGen;const N=OpenJFEM
out=abspath(only(ARGS));mkpath(out)
reports=Any[]
checks=@testset "Generated Euler sections use actual recovered signed forces" begin
    for kind in ("beam","shell_mixed")
        dir=joinpath(out,kind);params=JSON.parsefile(joinpath(dir,"params.json"))
        model=W.build_model(first(W.normalize_params(params)));columns=W.stringer_euler_payload(model)
        deck=read(joinpath(dir,"model.bdf"),String)
        deck=replace(deck,r"(?m)^FORCE[^\r\n]*\r?\n"=>"")
        gid=model.node_ids[last(model.rbe3).ref]
        deck=replace(deck,"BEGIN BULK"=>"SUBCASE 2\n  LABEL = Axial tension\n  SPC = 1\n  LOAD = 2\nSUBCASE 3\n  LABEL = Double axial compression\n  SPC = 1\n  LOAD = 3\nBEGIN BULK")
        deck=replace(deck,"ENDDATA"=>"FORCE,1,$gid,0,1000.,0.,-1.,0.\nFORCE,2,$gid,0,1000.,0.,1.,0.\nFORCE,3,$gid,0,2000.,0.,-1.,0.\nENDDATA")
        path=joinpath(dir,"axial_cases.bdf");write(path,deck)
        native=N.bdf_to_model(path)
        elapsed=@elapsed result=N.solve_model(native)
        @test result["sol_type"]==101
        @test length(result["subcases"])==3
        write(joinpath(dir,"axial_native_results.json"),JSON.json(result))
        records=[last(W.element_results_payload(model,sub)) for sub in result["subcases"]]
        @test all(!isempty,records)
        values=Any[]
        for column in columns
            column["status"]=="ready"||continue
            for station in column["stations"]
                loads=zeros(3);simple=zeros(3)
                for term in station["force_terms"]
                    eid=string(term["eid"])
                    for case in 1:3
                        forces=records[case][eid]["forces"]
                        if term["kind"]=="beam_axial"
                            loads[case]+=forces["axial"];simple[case]+=forces["axial"]
                        else
                            @test term["coefficients"]≈[1.,0.,0.] atol=1e-12
                            loads[case]+=term["width_m"]*sum(term["coefficients"].*[forces["fx"],forces["fy"],forces["fxy"]])
                            simple[case]+=term["width_m"]*forces["fx"]
                        end
                    end
                end
                @test loads≈simple atol=1e-8
                @test loads[1]≈-loads[2] rtol=1e-10 atol=1e-8
                @test loads[3]≈2loads[1] rtol=1e-10 atol=1e-8
                push!(values,Dict("panel_id"=>column["panel_id"],"station"=>station["id"],"signed_axial_force_N"=>loads))
            end
        end
        @test any(row["signed_axial_force_N"][1]<-1. for row in values)
        fixture=Dict("columns"=>columns,"cases"=>[Dict("case_id"=>i,"analysis_type"=>"SOL101","element_results"=>records[i]) for i in 1:3],"station_checks"=>values)
        write(joinpath(dir,"axial_euler_fixture.json"),JSON.json(fixture))
        push!(reports,Dict("kind"=>kind,"seconds_including_compilation"=>elapsed,"stations"=>length(values),"cases"=>3))
        if kind=="beam"
            text=replace(read(joinpath(dir,"model.bdf"),String),r"(?m)^FORCE[^\r\n]*\r?\n"=>"","SOL 101"=>"SOL 106")
            text=replace(text,"ENDDATA"=>"PARAM,LGDISP,1\nPARAM,NLLOADSTEPS,2\nPARAM,NLMAXITER,40\nPARAM,NLTOL,1.e-9\nPARAM,NLRESTOL,1.e-9\nFORCE,1,$gid,0,1000.,0.,-1.,0.\nENDDATA")
            path106=joinpath(dir,"axial_sol106.bdf");write(path106,text)
            elapsed106=@elapsed result106=N.solve_model(N.bdf_to_model(path106))
            @test result106["sol_type"]==106
            sub106=only(result106["subcases"])
            @test W.sensitivity_nonlinear_convergence(sub106)!==false
            @test sub106["nonlinear_diagnostics"]["nonlinear_method"]!="linear_elastic"
            records106=last(W.element_results_payload(model,sub106))
            @test !isempty(records106)
            write(joinpath(dir,"axial_sol106_native_results.json"),JSON.json(result106))
            write(joinpath(dir,"axial_sol106_euler_fixture.json"),JSON.json(Dict("columns"=>columns,"cases"=>[Dict("case_id"=>1,"analysis_type"=>"SOL106","element_results"=>records106,"nonlinear"=>sub106["nonlinear_diagnostics"],"load_scale"=>sub106["nonlinear_diagnostics"]["exported_load_scale"])])))
            push!(reports,Dict("kind"=>"beam_SOL106","seconds_including_compilation"=>elapsed106,"cases"=>1))
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"recovery_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"models"=>reports)))
