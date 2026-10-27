using Test
module OffsetReferenceSensitivityFixture
using Test,OpenJFEM,LinearAlgebra,JSON
const S=OpenJFEM.Solver
function model(directory)
    path=joinpath(directory,"offset_plate.bdf")
    open(path,"w") do io
        print(io,"""
SOL 105
CEND
SUBCASE 1
 SPC = 1
 LOAD = 1
SUBCASE 2
 SPC = 1
 METHOD = 1
 STATSUB(PRELOAD) = 1
BEGIN BULK
PARAM,SNORM,0.
PARAM,K6ROT,1.
MAT1,1,7.1E10,,.29,2700.
PSHELL,1,1,.018,1,,1
EIGRL,1,0.,,3
""")
        for j=0:2,i=0:2
            n=1+i+3j
            println(io,"GRID,$n,,$(0.6i),$(0.4j),0.")
            i==0 && println(io,"SPC1,1,123456,$n")
            i==2 && println(io,"FORCE,1,$n,0,-100.,1.,0.,0.")
        end
        for j=0:1,i=0:1
            n=1+i+3j;e=1+i+2j
            println(io,"CQUAD4,$e,1,$n,$(n+1),$(n+4),$(n+3),0.,.007")
        end
        println(io,"ENDDATA")
    end
    return OpenJFEM.bdf_to_model(path)
end
function altered(base,kind,delta)
    value=deepcopy(base)
    if kind=="t"
        value["PSHELLs"]["1"]["T"]+=delta
    elseif kind=="E"
        m=value["MATs"]["1"];ratio=(m["E"]+delta)/m["E"]
        m["E"]+=delta;m["G"]*=ratio
    else
        m=value["MATs"]["1"];m["NU"]+=delta;m["G"]=m["E"]/(2*(1+m["NU"]))
    end
    return value
end
function checks()
    mktempdir() do dir
        base=model(dir);r=OpenJFEM.solve_model(base)
        lambda=collect(r["eigenvalues"])
        @test length(lambda)==3 && all(isfinite,lambda) && all(>(0.),lambda)
        @test only(r["buckling"].subcases).K_eig==r["K"]
        ordinary_defaults=("JFEM_KG_SHELL_TRANSVERSE_W_FORM"=>"w",
            "JFEM_KG_SHELL_LOCAL_TRANS_SPLIT"=>"off",
            "JFEM_KG_SHELL_TRANS_DOF_MODE"=>"reference",
            "JFEM_KG_SHELL_DRILL_ZERO"=>"yes",
            "JFEM_KG_QUAD4_STRESS_FIELD_MODE"=>"gp",
            "JFEM_KG_QUAD4_MEMBRANE_RECOVERY_MODE"=>"planar",
            "JFEM_KG_SHELL_SURFACE_OPERATOR"=>"flat",
            "JFEM_KG_QUAD4_GP_FIELD_BLEND"=>"1",
            "JFEM_KG_SHELL_NXY_AUTO_RELAX"=>"0.0",
            "JFEM_KG_QUAD4_SHEAR_AVG_OPERATOR"=>"false",
            "JFEM_KG_VALUES_ONLY_CSC"=>"true")
        withenv(ordinary_defaults...) do
            @test !S.q4_reference_offset_research_overrides()
            same=OpenJFEM.solve_model(base)
            @test same["K"]==r["K"]
            @test only(same["buckling"].subcases).Kg==only(r["buckling"].subcases).Kg
            @test only(same["buckling"].subcases).u_static==only(r["buckling"].subcases).u_static
            @test same["eigenvalues"]==r["eigenvalues"]
        end
        config=Dict("responses"=>[Dict("id"=>"mode_$i","type"=>"buckling_eigenvalue","mode"=>i) for i=1:3],
            "design_variables"=>[
            Dict("id"=>"t","type"=>"shell_thickness","pids"=>[1]),
            Dict("id"=>"E","type"=>"material_E","mids"=>[1]),
            Dict("id"=>"nu","type"=>"material_NU","mids"=>[1])])
        path=joinpath(dir,"sensitivity.json");open(io->JSON.print(io,config),path,"w")
        analytic=S.solve_adjoint_buckling(r,path)
        for (kind,original,label) in (("t",.018,"PID_1"),("E",7.1e10,"MID_1"),("nu",.29,"MID_1"))
            measured=[analytic["sensitivities"]["mode_$i"][kind][label] for i=1:3]
            @test all(isfinite,measured)
            estimates=Vector{Float64}[]
            for relative_step in (2e-4,1e-4)
                step=relative_step*original
                plus=OpenJFEM.solve_model(altered(base,kind,step))
                minus=OpenJFEM.solve_model(altered(base,kind,-step))
                lp=collect(plus["eigenvalues"]);lm=collect(minus["eigenvalues"])
                @test length(lp)==length(lm)==length(lambda)
                # Small perturbations must retain each simple mode in order.
                for shifted in (plus,minus),i=1:3
                    a=r["_raw_mode_shapes"][:,i];b=shifted["_raw_mode_shapes"][:,i]
                    @test abs2(dot(a,b))/(dot(a,a)*dot(b,b))>.999
                end
                numerical=(lp-lm)/(2step);push!(estimates,numerical)
                @test isapprox(measured,numerical;rtol=2e-4,atol=1e-8*norm(numerical))
            end
            @test isapprox(estimates[1],estimates[2];rtol=2e-4)
            kind=="E" && @test isapprox(measured,lambda/original;rtol=3e-5)
        end
    end
    # Presence of a diagnostic output does not select a research operator.
    withenv("JFEM_KG_DIAG_EID_CSV"=>"diagnostic.csv") do
        @test !S.q4_reference_offset_research_overrides()
    end
    withenv("JFEM_KG_QUAD4_GP_FIELD_BLEND"=>"0.5") do
        @test S.q4_reference_offset_research_overrides()
    end
    withenv("JFEM_KG_VALUES_ONLY_CSC"=>"false") do
        @test !S.q4_reference_offset_research_overrides()
    end
    for family in ("WARPED","SKEW")
        enabled="JFEM_SOL105_GEOM_PSHELL_ISO_"*family*"_KG_SCALE"
        value=enabled*"_VALUE"
        for (switch,scale,expected) in (("true","2",true),("on","0.5",true),
                ("false","2",false),("off","0.5",false),("true","1",false),
                ("yes","not-a-number",false),("false","1",false))
            withenv(enabled=>switch,value=>scale) do
                @test S.q4_reference_offset_research_overrides()==expected
            end
        end
    end
end
end
@testset "Flat offset buckling sensitivities follow the assembled reference law" begin
    OffsetReferenceSensitivityFixture.checks()
end
