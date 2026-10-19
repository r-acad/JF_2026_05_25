using Test

module TACSLinearCompatibilityFixture
using OpenJFEM, Test, LinearAlgebra, SparseArrays, StaticArrays
const J = OpenJFEM
const S = J.Solver

function mat2(Q)
    Dict{String,Any}("TYPE"=>"MAT2", "G11"=>Q[1,1], "G12"=>Q[1,2],
        "G13"=>Q[1,3], "G22"=>Q[2,2], "G23"=>Q[2,3], "G33"=>Q[3,3])
end

function constitutive_checks()
    Q1 = [120. 12. 3.;12. 80. -2.;3. -2. 40.]
    Q2 = [310. 19. 7.;19. 180. -9.;7. -9. 65.]
    Q3 = [17. 2. 0.;2. 23. 0.;0. 0. 0.]
    Q4 = [.8 .2 .1;.2 .6 -.04;.1 -.04 .3]
    model=Dict{String,Any}("MATs"=>Dict(string(i)=>mat2(q) for (i,q) in enumerate((Q1,Q2,Q3,Q4))))
    prop=Dict{String,Any}("TYPE"=>"PSHELL","MID"=>1,"MID2"=>2,"MID3"=>3,"MID4"=>4,
        "T"=>.2,"BEND_RATIO"=>1.7,"TS_T"=>.6)
    el=Dict{String,Any}("THETA"=>0.)
    A,D,H,h,_,B=J._tacs_shell_constitutive(model,prop,el)
    @test A ≈ .2Q1
    @test D ≈ 1.7*.2^3/12 .* Q2
    @test H ≈ .6*.2 .* Q3[1:2,1:2]
    @test B ≈ -.2^2 .* Q4
    # The quadratic sectional energy includes the full B coupling; test its
    # thickness derivative against an independent finite difference.
    strain=[.13,-.07,.02];curvature=[.04,.06,-.03];shear=[.01,-.02]
    function energy(t)
        p=copy(prop);p["T"]=t
        a,d,s,_,_,b=J._tacs_shell_constitutive(model,p,el)
        dot(strain,a*strain)/2 + dot(curvature,d*curvature)/2 +
            dot(strain,b*curvature) + dot(shear,s*shear)/2
    end
    expected=dot(strain,Q1*strain)/2 +
        1.7*.2^2/8*dot(curvature,Q2*curvature) -
        2*.2*dot(strain,Q4*curvature) + .6/2*dot(shear,Q3[1:2,1:2]*shear)
    @test J.ForwardDiff.derivative(energy,.2) ≈ expected rtol=2e-13
    @test (energy(.200001)-energy(.199999))/2e-6 ≈ expected rtol=2e-9
    # Independent rotated in-plane strain tensor preserves physical energy.
    angle=.41;c=cos(angle);s=sin(angle)
    T=[c*c s*s c*s;s*s c*c -c*s;-2c*s 2c*s c*c-s*s]
    ar,dr,hr,_,_,br=J._tacs_shell_constitutive(model,prop,el;material_angle=angle)
    @test ar ≈ T' * (.2Q1) * T
    @test dr ≈ T' * (1.7*.2^3/12 .* Q2) * T
    @test br ≈ T' * (-.2^2 .* Q4) * T
    R=[c -s;s c]
    @test hr ≈ R * (.6*.2 .* Q3[1:2,1:2]) * R'
    membrane=copy(prop);membrane["MID2"]=0;membrane["BEND_RATIO"]=0.
    _,d,shear,_,_,b=J._tacs_shell_constitutive(model,membrane,el)
    @test iszero(d) && iszero(shear) && b === nothing
    # Section support must leave the existing material-specific drilling
    # modulus unchanged: plane-stress Q11 is not Young's modulus.
    iso=Dict{String,Any}("MATs"=>Dict("1"=>Dict("TYPE"=>"MAT1","E"=>70.,"G"=>27.,"NU"=>.3)))
    p=Dict{String,Any}("MID"=>1,"T"=>.2)
    @test J._tacs_shell_constitutive(iso,p,el)[5] == 70.
    ortho=Dict{String,Any}("MATs"=>Dict("1"=>Dict("TYPE"=>"MAT8","E1"=>135.,"E2"=>8.,"G12"=>5.,"NU12"=>.25)))
    @test J._tacs_shell_constitutive(ortho,p,el)[5] == 135.
end

function write_deck(path; linked=true, sol=101)
    open(path,"w") do io
        println(io,"SOL $sol\nCEND\nSPC=1\nLOAD=1\nMETHOD=1\nBEGIN BULK")
        println(io,"PARAM,AUTOSPC,NO\nPARAM,COUPMASS,-1\nEIGRL,1,,,2")
        println(io,"MAT1,1,7.E10,,.3,2700.\nPSHELL,1,1,.02,1,1.,1,.833333333333333")
        for (i,p) in enumerate(((0.,0.,0.),(1.,0.,0.),(1.,1.,0.),(0.,1.,0.),(1.,.5,0.),(1.,.5,0.)))
            println(io,"GRID,$i,,",join(p,','))
        end
        println(io,"CQUADR,1,1,1,2,3,4,0.0\nSPC1,1,123456,1,4")
        if linked
            println(io,"SPC1,1,12456,5,6\nRBE3,10,,5,3,1.,3,2,3\nRBE2,11,5,3,6")
            println(io,"CONM2,12,6,0,10.\nGRAV,1,0,-9.81,0.,0.,1.")
        else
            println(io,"SPC1,1,123456,5,6\nGRAV,1,0,-9.81,0.,0.,1.")
            println(io,"FORCE,1,2,0,-49.05,0.,0.,1.\nFORCE,1,3,0,-49.05,0.,0.,1.")
        end
        println(io,"ENDDATA")
    end
end

function connection_checks()
    mktempdir() do dir
        linked=joinpath(dir,"linked.bdf");direct=joinpath(dir,"direct.bdf")
        write_deck(linked);write_deck(direct;linked=false)
        model=J.bdf_to_model(linked);base=J.bdf_to_model(direct)
        r=J.solve_model(model);b=J.solve_model(base)
        u=r["subcases"][1]["raw_displacement"];v=b["subcases"][1]["raw_displacement"]
        ids=r["id_map"];dof(g,c)=6*(ids[g]-1)+c
        @test r["backend_forced_by"] == "CQUADR"
        for g in 1:4,c in 1:6
            @test u[dof(g,c)] ≈ v[6*(b["id_map"][g]-1)+c] atol=1e-13 rtol=5e-11
        end
        @test u[dof(5,3)] ≈ (u[dof(2,3)]+u[dof(3,3)])/2 atol=1e-14
        @test u[dof(6,3)] ≈ u[dof(5,3)] atol=1e-14
        K,ids,X,ndof,R,_,graph,_,_=J._tacs_assemble_sol101(model)
        @test graph[dof(5,3)] == graph[dof(6,3)]
        @test Set(first.(graph[dof(6,3)])) == Set((dof(2,3),dof(3,3)))
        # A known interpolation matrix provides an independent reference for
        # the point-mass congruence, including the nested RBE2/RBE3 chain.
        model["SOL"]=103
        M=J._tacs_sol103_modal_mass_builder(model,ids,X,R,ndof)
        pointmodel=deepcopy(model);pointmodel["CSHELLs"]=Dict{String,Any}()
        Mp=S.assemble_mass(pointmodel,ids,X,R,ndof)
        reduced=S._apply_constraint_congruence(Mp,graph;expected_ndof=ndof)
        @test reduced[dof(2,3),dof(2,3)] ≈ 2.5
        @test reduced[dof(2,3),dof(3,3)] ≈ 2.5
        @test reduced[dof(3,3),dof(3,3)] ≈ 2.5
        @test iszero(reduced[dof(6,3),dof(6,3)])
        @test sum(diag(M)) > 30.
        # Unsupported nonlinear and sensitivity combinations remain explicit.
        @test_throws ErrorException J._tacs_validate_shell_slice(model;allowed_sol_types=(103,))
        @test_throws ErrorException J._tacs_assemble_sol101(model;allowed_sol_types=(103,),thickness_derivative_pid=1)
        model["SOL"]=105
        @test_throws ErrorException J._tacs_assemble_sol101(model;allowed_sol_types=(105,))
    end
end

function orientation_checks()
    mktempdir() do dir
        path=joinpath(dir,"coordinates.bdf")
        write_deck(path;linked=false)
        m=J.bdf_to_model(path);el=m["CSHELLs"]["1"]
        ids,X,_,R=J._tacs_node_tables(m)
        ctx=J._tacs_shell_element_context(m,el,ids,X,R)
        e=copy(el);e["MCID"]=0;e["MCID_SPECIFIED"]=true
        @test J._tacs_shell_material_angle(m,e,ctx,X) ≈ 0. atol=1e-15
        m["CORDs"]["99"]=Dict("U"=>[0.,1.,0.],"V"=>[-1.,0.,0.])
        e["MCID"]=99
        @test J._tacs_shell_material_angle(m,e,ctx,X) ≈ pi/2
        e["MCID"]=100
        @test_throws ErrorException J._tacs_shell_material_angle(m,e,ctx,X)
    end
end
end

@testset "TACS linear PSHELL sections and rigidly connected masses" begin
    TACSLinearCompatibilityFixture.constitutive_checks()
    TACSLinearCompatibilityFixture.connection_checks()
    TACSLinearCompatibilityFixture.orientation_checks()
end
