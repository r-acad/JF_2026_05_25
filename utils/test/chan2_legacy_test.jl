using Test,LinearAlgebra,OpenJFEM

@testset "Explicit legacy CHAN2 section equations" begin
    P=OpenJFEM.ReferenceParser
    for dims in ((.003,.004,.09,.12),(.004,.002,.04,.07),(.002,.002,.025,.0745),
                 (.0015,.002,.08,.14),(.006,.008,.04,.08),(.003,.004,.14,.04))
        tw,tb,h,b=dims
        s=P.chan2_section_legacy(dims...);g=P.chan2_section_geometry(dims...)
        # Independent wall-area/shear-flow equilibrium identities. The
        # legacy torsion integrates on wall midlines. Disjoint rectangle
        # lengths describe area/inertia but give the wrong torsion when the
        # side and bottom thicknesses differ.
        areas=(b*tb,tw*(h-tb),tw*(h-tb));thicknesses=(tb,tw,tw)
        lengths=(b-tw,h-tb/2,h-tb/2)
        @test s.J≈sum(lengths[i]*thicknesses[i]^3/3 for i in 1:3) rtol=1e-14
        rectangle_sum=sum(areas[i]*thicknesses[i]^2/3 for i in 1:3)
        @test rectangle_sum-s.J≈tw*tb*(tb^2-tw^2)/3 atol=1e-23
        tw==tb && @test s.J≈rectangle_sum rtol=1e-14
        @test s.K1*g.A≈areas[2]+areas[3] rtol=1e-14
        @test s.K2*g.A≈(b-2tw)*tb rtol=1e-14
        shear_center=g.yc-s.N1
        @test (shear_center-tb/2)*(tb*(b-tw)+6tw*(h-tb/2))+3tw*(h-tb/2)^2≈0 atol=1e-18
        @test s.J>0 && 0<s.K1<1 && 0<s.K2<1 && s.N1>g.yc
        scaled=P.chan2_section_legacy((1000 .*dims)...)
        @test scaled.J≈1e12s.J rtol=1e-13
        @test scaled.N1≈1000s.N1 rtol=1e-13
        @test scaled.K1≈s.K1 rtol=1e-13
        @test scaled.K2≈s.K2 rtol=1e-13
    end
    for dims in ((.1,.5,.5,1.),(.5,.1,.5,1.))
        @test_throws ArgumentError P.chan2_section_legacy(dims...)
        @test P.chan2_section_warping(dims...).N1==0
    end
end

@testset "Legacy selection preserves default section physics" begin
    P=OpenJFEM.ReferenceParser;dims=(.003,.004,.09,.12)
    card=Any["SMALL","PBARL",1,1,"","CHAN2",dims...,.02]
    automatic=P.extract_pbarl([card])["1"];explicit=P.extract_pbarl([card];twbrbml=0)["1"]
    legacy=P.extract_pbarl([card];twbrbml=1)["1"]
    @test automatic==explicit
    # The default conversion takes area and inertias from the outline; the legacy equations use the
    # closed forms of the same outline.
    for field in ("A","I1","I2")
        @test automatic[field]≈legacy[field] rtol=1e-12
    end
    for field in ("I12","NSM","C1","C2","D1","D2")
        @test automatic[field]==legacy[field]
    end
    @test legacy["TORSION_FORMULATION"]=="legacy_thin_wall"
    @test automatic["TORSION_FORMULATION"]=="saint_venant_2d"
    @test automatic["J"]!=legacy["J"]
    @test legacy["TWBRBML"]==1
    # TWBRBML=1 selects the beam library equations for every section; the default is the
    # finite-element conversion. Both describe the same outline.
    for (shape,ds) in (("ROD",[.01]),("TUBE",[.01,.008]),("BAR",[.02,.03]))
        c=Any["SMALL","PBARL",1,1,"",shape,ds...]
        default=P.extract_pbarl([c])["1"];library=P.extract_pbarl([c];twbrbml=1)["1"]
        @test default["SECTION_METHOD"]=="finite_element"
        @test library["SECTION_METHOD"]=="library_equations"
        for field in ("A","I1","I2")
            @test default[field]≈library[field] rtol=1e-12
        end
        @test default["J"]≈library["J"] rtol=.01
    end
    # Library equations of T, I and BOX against the values of the reference solver
    # ("CONVERSION METHOD ... BEAM LIBRARY EQUATIONS", five digits).
    for (shape,ds,J,K1,K2) in (("T",[.04,.05,.004,.003],1.2853e-9,.46309,.53691),
            ("I",[.08,.05,.05,.003,.004,.004],2.8173e-9,.35065,.54113),
            ("BOX",[.06,.04,.003,.003],2.8391e-7,.36170,.57447))
        library=P.extract_pbarl([Any["SMALL","PBARL",1,1,"",shape,ds...]];twbrbml=1)["1"]
        @test library["J"]≈J rtol=5e-5
        @test library["K1"]≈K1 rtol=5e-5
        @test library["K2"]≈K2 rtol=5e-5
    end
end

@testset "MDLPRM name-value pairs and deck/JSON propagation" begin
    P=OpenJFEM.ReferenceParser
    controls=P.extract_mdlprm([Any["SMALL","MDLPRM","TWBRBML","1","UNVERIFIED","YES"]])
    @test controls==Dict("TWBRBML"=>1,"UNVERIFIED"=>"YES")
    @test P.mdlprm_twbrbml(controls)==1
    @test P.mdlprm_twbrbml(Dict())==0
    @test P.normalize_mdlprm(Dict("twbrbml"=>"1"))==Dict("TWBRBML"=>1)
    @test_throws ArgumentError P.extract_mdlprm([Any["SMALL","MDLPRM","TWBRBML",1],Any["SMALL","MDLPRM","TWBRBML",0]])
    @test_throws ArgumentError P.extract_mdlprm([Any["SMALL","MDLPRM","TWBRBML",1],Any["SMALL","MDLPRM","TWBRBML",1]])
    @test_throws ArgumentError P.normalize_mdlprm(Dict("TWBRBML"=>1,"twbrbml"=>1))
    @test_throws ArgumentError P.extract_mdlprm([Any["SMALL","MDLPRM","TWBRBML",""]])
    @test_throws ArgumentError P.mdlprm_twbrbml(Dict("TWBRBML"=>2))
    @test_throws ArgumentError P.mdlprm_twbrbml(Dict("TWBRBML"=>"AUTO"))
    mktempdir() do dir
        file=joinpath(dir,"legacy.bdf")
        write(file,"SOL 101\nCEND\nBEGIN BULK\nMDLPRM,TWBRBML,1\n"*
            "GRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nMAT1,1,7.e10,,.3\n"*
            "PBARL,10,1,,CHAN2\n+,.002,.002,.025,.0745\n"*
            "PBEAML,20,1,,CHAN2\n+,.002,.002,.025,.0745\nENDDATA\n")
        model=OpenJFEM.bdf_to_model(file)
        @test model["MDLPRMs"]["TWBRBML"]==1
        @test model["PBARLs"]["10"]["TWBRBML"]==1
        @test !haskey(model["PBARLs"]["10"],"N1A")
        @test model["PBARLs"]["20"]["N1A"]≈.012753308481787778 rtol=2e-12
        raw=Dict("case_control"=>Dict("SOL"=>101),"bulk_data"=>Dict(
            "MDLPRM"=>Dict("TWBRBML"=>1),
            "PBARL"=>Dict("10"=>Dict("PID"=>10,"MID"=>1,"TYPE"=>"CHAN2","DIMS"=>[.002,.002,.025,.0745])),
            "PBEAML"=>Dict("20"=>Dict("PID"=>20,"MID"=>1,"TYPE"=>"CHAN2","DIMS"=>[.002,.002,.025,.0745]))))
        from_json=OpenJFEM.build_model_from_json(raw)
        @test from_json["MDLPRMs"]==model["MDLPRMs"]
        @test from_json["PBARLs"]==model["PBARLs"]
        unchanged=replace(read(file,String),"MDLPRM,TWBRBML,1\n"=>"")
        write(joinpath(dir,"default.bdf"),unchanged)
        @test OpenJFEM.bdf_to_model(joinpath(dir,"default.bdf"))["PBARLs"]["10"]["J"]!=model["PBARLs"]["10"]["J"]
    end
end

@testset "Legacy beam compliance and shear-center work conjugacy" begin
    P=OpenJFEM.ReferenceParser;S=OpenJFEM.Solver
    dims=(.003,.004,.09,.12);card=Any["SMALL","PBARL",1,1,"","CHAN2",dims...]
    bar=P.extract_pbarl([card];twbrbml=1)["1"]
    beamcard=Any["SMALL","PBEAML",2,1,"","CHAN2","","","","",dims...]
    beam=P.extract_pbeaml([beamcard];twbrbml=1)["2"]
    E,G,L=73e9,28e9,1.35
    K=S._beam_local_stiffness(L,bar,E,G);C=inv(Symmetric(K[7:12,7:12]))
    @test C[1,1]≈L/(E*bar["A"]) rtol=1e-12
    @test C[2,2]≈L^3/(3E*bar["I1"])+L/(G*bar["K1"]*bar["A"]) rtol=1e-12
    @test C[3,3]≈L^3/(3E*bar["I2"])+L/(G*bar["K2"]*bar["A"]) rtol=1e-12
    @test C[4,4]≈L/(G*bar["J"]) rtol=1e-12
    Kc=S._beam_local_stiffness(L,beam,E,G);eccentric=inv(Symmetric(Kc[7:12,7:12]));n=beam["N1A"]
    @test eccentric[1,1]≈C[1,1]+n^2*L/(E*bar["I1"]) rtol=1e-12
    @test eccentric[2,1]≈n*L^2/(2E*bar["I1"]) rtol=1e-12
    @test eccentric[6,1]≈n*L/(E*bar["I1"]) rtol=1e-12
    @test Kc≈transpose(S._pbeam_neutral_axis_transform(beam))*K*S._pbeam_neutral_axis_transform(beam) rtol=1e-14
end
