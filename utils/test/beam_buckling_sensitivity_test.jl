module BeamBucklingSensitivityTests

using Test, LinearAlgebra, Random, OpenJFEM
const S = OpenJFEM.Solver

function synthetic_model()
    model = mktempdir() do directory
        deck = joinpath(directory, "oriented_beams.bdf")
        write(deck, """
        SOL 105
        CEND
        BEGIN BULK
        MAT1,1,7.1+10,,.29,2700.
        MAT1,2,6.4+10,,.24,2600.
        PBAR,1,1,.0012,8.-7,1.3-6,4.1-7
        PBAR,2,2,.0009,6.-7,9.-7,3.3-7
        GRID,1,,.25,-.13,.18
        GRID,2,,.94,.22,.62
        GRID,3,,1.36,.76,.51
        CBAR,11,1,1,2,.17,.82,.43
        CBEAM,22,2,2,3,.17,.82,.43
        ENDDATA
        """)
        OpenJFEM.bdf_to_model(deck)
    end
    for (pid, k1, k2, product) in (("1",.61,.83,1.1e-7),("2",.74,.57,-1.3e-7))
        property = model["PBARLs"][pid]
        property["K1"], property["K2"], property["I12"] = k1,k2,product
    end
    for (collection,eid,offset) in (("CBARs","11",[.013,-.017,.009]),
                                     ("CBEAMs","22",[.011,.014,-.021]))
        beam = model[collection][eid]
        beam["WA"],beam["WB"] = copy(offset),copy(offset)
        @assert get(beam,"PA",0)==get(beam,"PB",0)==0
    end
    for material in values(model["MATs"])
        material["ALPHA"],material["TREF"] = 1.1e-5,25.
    end
    model["TEMPDs"] = Dict(9=>0.,10=>125.)
    return model
end

# Finite differences are the independent test oracle only. Production
# sensitivities differentiate the resultant energy and constitutive algebra.
function parameter_fd(model, energy, kind, key)
    plus,minus = deepcopy(model),deepcopy(model)
    if kind==:area
        original=model["PBARLs"][key]["A"]
        step=original*1e-5
        plus["PBARLs"][key]["A"]+=step
        minus["PBARLs"][key]["A"]-=step
    else
        original=model["MATs"][key]["NU"]
        step=1e-5
        for (copy_model,sign) in ((plus,1),(minus,-1))
            material=copy_model["MATs"][key]
            material["NU"]=original+sign*step
            material["G"]=material["E"]/(2*(1+material["NU"]))
        end
    end
    return (energy(plus)-energy(minus))/(2step)
end

@testset "Full-resultant beam buckling sensitivities follow assembled Kg" begin
    # Silence routine assembler progress while retaining assertion diagnostics.
    redirect_stdout(devnull) do
        model=synthetic_model()
        _,ids,x,ndof,rot,_,_,_,_=S.assemble_stiffness(model)
        rng=MersenneTwister(761902)
        u=1e-3*randn(rng,ndof)
        phi=randn(rng,ndof)
        kg(m,state)=S.assemble_geometric_stiffness(m,ids,x,rot,ndof,state,Dict(),Dict())
        energy(m,state)=dot(phi,kg(m,state)*phi)
        for eid in (11,22)
            data=S._get_beam_element_data(eid,model,ids,x,rot)
            forces=data.Ke_loc*(data.T12*u[data.dofs])
            # Each element independently exercises N,Qy,Qz,T,My,Mz, with
            # a genuine non-axis-aligned frame, finite shear and rigid offsets.
            @test all(abs.(forces[[7,2,3,4,5,6]]).>1e-6)
            @test 0<data.prop["K1"]<1 && 0<data.prop["K2"]<1
            @test norm(data.T12[1:3,4:6])>0
            @test norm(data.T12[1:3,1:3]-I)>0.1
        end

        # Explicit zero temperature is not zero thermal strain when TREF=25.
        # Test both temperature signs as well as the nonthermal state.
        cold_rhs=S.compute_buckling_adjoint_rhs(model,ids,x,rot,u,phi,ndof)
        for temperature_set in (nothing,9,10)
            active=deepcopy(model)
            temperature_set===nothing || (active["_active_temp_sid"]=temperature_set)
            Kg=kg(active,u)
            rhs=S.compute_buckling_adjoint_rhs(active,ids,x,rot,u,phi,ndof)
            @test rhs≈cold_rhs rtol=1e-14
            step=1e-7
            numerical=zeros(ndof)
            for component in 1:ndof
                plus,minus=copy(u),copy(u)
                plus[component]+=step
                minus[component]-=step
                numerical[component]=(energy(active,plus)-energy(active,minus))/(2step)
            end
            @test rhs≈numerical rtol=2e-8 atol=1e-3
            area=S._dKg_dx_phi_bar_area(Dict("pids"=>[1,2]),active,ids,x,rot,u,phi,Kg,ndof)
            nu=S._dKg_dx_phi_material_NU(Dict("mids"=>[1,2]),active,ids,x,rot,u,phi,Kg,ndof)
            for key in ("1","2")
                expected_area=parameter_fd(active,m->energy(m,u),:area,key)
                expected_nu=parameter_fd(active,m->energy(m,u),:nu,key)
                @test area["PID_"*key]≈expected_area rtol=2e-7 atol=1e-4
                @test nu["MID_"*key]≈expected_nu rtol=2e-7 atol=1e-4
                @test abs(expected_area)>1e-4
                @test abs(expected_nu)>1e-4
            end
            temperature_set===nothing && continue
            strain=1.1e-5*(active["TEMPDs"][temperature_set]-25.)
            expanded=zeros(ndof)
            for index in values(ids)
                expanded[6*(index-1).+(1:3)]=strain.*rot[index]'*vec(x[index,:])
            end
            # Unrestrained uniform thermal expansion cancels all prestress,
            # including zero applied temperature relative to nonzero TREF.
            scale=norm(kg(active,zeros(ndof)))
            @test scale>0
            @test norm(kg(active,expanded))<=2e-12*scale
            zero_area=S._dKg_dx_phi_bar_area(Dict("pids"=>[1,2]),active,ids,x,rot,expanded,phi,Kg,ndof)
            zero_nu=S._dKg_dx_phi_material_NU(Dict("mids"=>[1,2]),active,ids,x,rot,expanded,phi,Kg,ndof)
            for key in ("1","2")
                @test abs(zero_area["PID_"*key])<=1e-10*max(abs(area["PID_"*key]),1.)
                @test abs(zero_nu["MID_"*key])<=1e-10*max(abs(nu["MID_"*key]),1.)
            end
        end
    end
end

end # module
