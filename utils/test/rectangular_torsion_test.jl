using Test,OpenJFEM
@testset "Rectangular section torsion keeps finite aspect correction" begin
    p=OpenJFEM.ReferenceParser
    # Independent Saint-Venant series checks the approximation's physical scale;
    # swapping width and height cannot change torsional rigidity.
    exact(a,b)=a*b^3/3*(1-192b/(pi^5*a)*sum(tanh(n*pi*a/(2b))/n^5 for n in 1:2:999))
    for (w,h) in ((.02,.02),(.04,.02),(.10,.02),(.02,.04),(.8,.001))
        J=p.rectangular_section_torsion(w,h)
        @test J≈p.rectangular_section_torsion(h,w)
        @test abs(J/exact(max(w,h),min(w,h))-1)<.005
        @test p.rectangular_section_torsion(3w,3h)≈81J
        # A library BAR is converted by finite elements on the section, as the reference solver does. The
        # converted torsion constant carries the discretisation of that mesh and stays within one
        # percent of the exact series (the reference's own values are 0.05 to 0.3 % above it).
        _,bulk=p.read_bulk_and_case(["BEGIN BULK","PBARL,20,1,,BAR", "+,$w,$h", "ENDDATA"])
        cards=p.process_cards(bulk)
        converted=p.extract_pbarl(cards["PBARL"])["20"]
        @test converted["SECTION_METHOD"]=="finite_element"
        @test abs(converted["J"]/exact(max(w,h),min(w,h))-1)<.01
        @test converted["A"]≈w*h rtol=1e-12
        @test converted["I1"]≈w*h^3/12 rtol=1e-12
        @test converted["I2"]≈h*w^3/12 rtol=1e-12
        for kind in ("PBARL","PBEAML")
            raw=Dict("case_control"=>Dict(),"bulk_data"=>Dict(kind=>Dict("20"=>
                Dict("PID"=>20,"MID"=>1,"TYPE"=>"BAR","DIMS"=>[w,h]))))
            @test OpenJFEM.build_model_from_json(raw)["PBARLs"]["20"]["J"]≈converted["J"]
        end
    end
    # Full square coefficient is .1408333..., not the slender-strip .1233333...
    @test p.rectangular_section_torsion(1.,1.)≈169/1200
end
