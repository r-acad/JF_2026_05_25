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
        _,bulk=p.read_bulk_and_case(["BEGIN BULK","PBARL,20,1,,BAR", "+,$w,$h", "ENDDATA"])
        cards=p.process_cards(bulk)
        @test p.extract_pbarl(cards["PBARL"])["20"]["J"]≈J
        for kind in ("PBARL","PBEAML")
            raw=Dict("case_control"=>Dict(),"bulk_data"=>Dict(kind=>Dict("20"=>
                Dict("PID"=>20,"MID"=>1,"TYPE"=>"BAR","DIMS"=>[w,h]))))
            @test OpenJFEM.build_model_from_json(raw)["PBARLs"]["20"]["J"]≈J
        end
    end
    # Full square coefficient is .1408333..., not the slender-strip .1233333...
    @test p.rectangular_section_torsion(1.,1.)≈169/1200
end
