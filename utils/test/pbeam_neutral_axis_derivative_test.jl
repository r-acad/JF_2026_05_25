module PbeamNeutralAxisDerivativeTests

using Test, OpenJFEM, LinearAlgebra, Random
const S = OpenJFEM.Solver

function fixture(; kind="CBEAM", release=0)
    model = mktempdir() do directory
        deck = joinpath(directory,"offset_section.bdf")
        write(deck,"""
        SOL 101
        CEND
        BEGIN BULK
        GRID,1,,.2,-.3,.1
        GRID,2,,1.1,.4,.6
        MAT1,1,7.2+10,,.27,2700.
        PBEAM,3,1,.0021,1.8-6,9.1-7,2.4-7,4.3-7
        +,.035,-.021,-.025,.013,0.,0.,0.,0.
        +,.63,.81,0.,0.,0.,0.,0.,0.
        +,0.,0.,0.,0.,-.025,.017
        $kind,8,3,1,2,.2,.7,-.1
        ENDDATA
        """)
        OpenJFEM.bdf_to_model(deck)
    end
    p = model["PBARLs"]["3"]
    p["TYPE"]="PBEAM"
    p["I12"]=2.4e-7
    p["K1"],p["K2"]=.63,.81
    p["N1A"]=p["N1B"]=-.025
    p["N2A"]=p["N2B"]=.017
    p["C1"],p["C2"] = .035,-.021
    p["D1"],p["D2"] = -.025,.013
    beam = model[kind=="CBAR" ? "CBARs" : "CBEAMs"]["8"]
    beam["WA"]=beam["WB"]=[.012,-.008,.019]
    beam["PB"]=release
    return model
end

function perturb(model, parameter, amount)
    model=deepcopy(model)
    if parameter==:area
        model["PBARLs"]["3"]["A"]+=amount
        for station in model["PBARLs"]["3"]["STATIONS"]
            station["A"]+=amount
        end
    else
        material=model["MATs"]["1"]
        material[parameter==:E ? "E" : "NU"]+=amount
        material["G"]=material["E"]/(2(1+material["NU"]))
    end
    return model
end

@testset "Neutral-axis beam derivatives follow assembled stiffness and stress" begin
    begin
        rng=MersenneTwister(918172)
        for kind in ("CBAR","CBEAM"), release in (0,6)
            model=fixture(;kind,release)
            K,ids,x,n,rot,_,_,_,_=S.assemble_stiffness(model)
            u=1e-3randn(rng,n)
            bd=S._get_beam_element_data(8,model,ids,x,rot)
            @test S._pbeam_neutral_axis_transform(bd.prop)!==nothing
            @test K[bd.dofs,bd.dofs] ≈ bd.T12'*bd.Ke_loc*bd.T12 rtol=1e-13
            for (parameter,step,dv) in (
                (:area,2.1e-8,Dict("type"=>"bar_area","pids"=>[3])),
                (:E,7.2e5,Dict("type"=>"material_E","mids"=>[1])),
                (:nu,1e-5,Dict("type"=>"material_NU","mids"=>[1])))
                plus,minus=perturb(model,parameter,step),perturb(model,parameter,-step)
                kp=first(S.assemble_stiffness(plus));km=first(S.assemble_stiffness(minus))
                expected=((kp-km)/(2step))*u
                actual=S.compute_dKdx_u(dv,model,ids,x,rot,u,n)
                @test norm(expected)>0
                @test actual ≈ expected rtol=2e-7 atol=1e-9
                if parameter==:area
                    dv["method"]=:element_fd
                    @test S.compute_dKdx_u(dv,model,ids,x,rot,u,n) ≈ expected rtol=2e-6 atol=1e-8
                end
            end
            # Independent perturbations of every state component test the
            # complete stress response covector, including offset end moments.
            for ending in ("a","b")
                response=Dict("type"=>"von_mises","eid"=>8,"beam_end"=>ending,"beam_point"=>1)
                gradient=S.compute_dr_du(response,u,model,ids,n,x,rot)
                numerical=zeros(n)
                for component in 1:n
                    plus,minus=copy(u),copy(u)
                    plus[component]+=1e-7;minus[component]-=1e-7
                    numerical[component]=(S.evaluate_response(response,plus,model,ids,n,x,rot)-
                        S.evaluate_response(response,minus,model,ids,n,x,rot))/(2e-7)
                end
                @test gradient ≈ numerical rtol=2e-8 atol=1e-3
                for (parameter,step,dv,key) in (
                    (:area,2.1e-8,Dict("type"=>"bar_area","pids"=>[3]),"PID_3"),
                    (:E,7.2e5,Dict("type"=>"material_E","mids"=>[1]),"MID_1"),
                    (:nu,1e-5,Dict("type"=>"material_NU","mids"=>[1]),"MID_1"))
                    plus,minus=perturb(model,parameter,step),perturb(model,parameter,-step)
                    expected=(S.evaluate_response(response,u,plus,ids,n,x,rot)-
                        S.evaluate_response(response,u,minus,ids,n,x,rot))/(2step)
                    explicit=S.compute_dr_dx_explicit(response,dv,model,ids,x,rot,u,n)
                    @test explicit[key] ≈ expected rtol=2e-6 atol=1e-5
                end
            end
            @test_throws ErrorException S._buckling_bar_data(8,model,ids,x,rot)
            if release==0
                # A complete fixed-root equilibrium/adjoint check also verifies
                # cancellation of explicit and implicit material dependence.
                free=6(ids[2]-1).+(1:6)
                load=zeros(n);load[free]=[150.,-42.,73.,2.,-3.,5.]
                state=zeros(n);state[free]=K[free,free]\load[free]
                response=Dict("type"=>"von_mises","eid"=>8,"beam_end"=>"a","beam_point"=>1)
                value=S.evaluate_response(response,state,model,ids,n,x,rot)
                gradient=S.compute_dr_du(response,state,model,ids,n,x,rot)
                adjoint=zeros(n);adjoint[free]=K[free,free]'\gradient[free]
                for (parameter,pvalue,step,dv,key) in (
                    (:area,.0021,2.1e-8,Dict("type"=>"bar_area","pids"=>[3]),"PID_3"),
                    (:E,7.2e10,7.2e5,Dict("type"=>"material_E","mids"=>[1]),"MID_1"),
                    (:nu,.27,1e-5,Dict("type"=>"material_NU","mids"=>[1]),"MID_1"))
                    pseudo=S.compute_dKdx_u(dv,model,ids,x,rot,state,n)
                    explicit=S.compute_dr_dx_explicit(response,dv,model,ids,x,rot,state,n)[key]
                    analytic=explicit-dot(adjoint,pseudo)
                    responses=Float64[]
                    for sign in (1,-1)
                        changed=perturb(model,parameter,sign*step)
                        changed_K=first(S.assemble_stiffness(changed))
                        changed_u=zeros(n);changed_u[free]=changed_K[free,free]\load[free]
                        push!(responses,S.evaluate_response(response,changed_u,changed,ids,n,x,rot))
                    end
                    numerical=(responses[1]-responses[2])/(2step)
                    @test analytic ≈ numerical rtol=2e-5 atol=2e-7*abs(value/pvalue)
                end
            end
        end
    end
end

@testset "Prismatic property sensitivity accepts optional station data" begin
    for storage in (:missing, :null, :empty, :populated)
        model = fixture()
        prop = model["PBARLs"]["3"]
        storage == :missing && delete!(prop,"STATIONS")
        storage == :null && (prop["STATIONS"] = nothing)
        storage == :empty && (prop["STATIONS"] = Any[])
        original = deepcopy(model)
        step = 1e-6
        changed = S._beam_model_with_property_delta(model,3,"A",step)
        @test changed["PBARLs"]["3"]["A"] == prop["A"] + step
        @test model == original
        @test S._beam_station_properties_constant(changed["PBARLs"]["3"])
        if storage == :populated
            @test all(s["A"] == prop["A"]+step for s in changed["PBARLs"]["3"]["STATIONS"])
        elseif storage == :null
            @test changed["PBARLs"]["3"]["STATIONS"] === nothing
        end
    end
end

end
