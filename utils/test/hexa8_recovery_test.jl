using Test
module Hexa8RecoveryPhysicalFixture
using Test,LinearAlgebra,Random,OpenJFEM
const H=OpenJFEM.FEM
const hs=[-1. -1. -1.;1. -1. -1.;1. 1. -1.;-1. 1. -1.;-1. -1. 1.;1. -1. 1.;1. 1. 1.;-1. 1. 1.]
const gp=[Tuple(hs[i,:]/sqrt(3)) for i=1:8]
const all_points=vcat([(0.,0.,0.)],[Tuple(hs[i,:]) for i=1:8],gp)
@testset "Enhanced solid work-conjugate recovery" begin
    rng=MersenneTwister(821)
    for kind in (:rectangular,:skew,:distorted),nu in (.0,.3,.49)
        X=hs.*[.5 .2 .1]
        kind!=:rectangular && (X[:,1].+=.4X[:,2])
        kind==:distorted && (X[7,:].+=[.08,.04,.03])
        E=7e10;D=H.iso_3d_constitutive(E,nu);u=1e-3randn(rng,24)
        fields=H.hexa8_section_fields(X,E,nu,u;points=all_points)
        states=fields.states[end-7:end]
        energy=sum(s.weight*dot(s.strain,s.stress) for s in states)
        force=sum(s.weight*s.B'*s.stress for s in states)
        internal=sum(s.weight*s.internal_B'*s.stress for s in states)
        @test energy≈dot(u,fields.stiffness*u) rtol=1e-12
        @test force≈fields.stiffness*u rtol=1e-12
        @test norm(internal)<1e-11norm(force)
        A=[.01 -.003 .002;.004 -.005 .007;-.002 .001 .008]
        patch=vec((X*A')')
        expected=[A[1,1],A[2,2],A[3,3],A[1,2]+A[2,1],A[2,3]+A[3,2],A[1,3]+A[3,1]]
        patchfields=H.hexa8_section_fields(X,E,nu,patch;points=all_points)
        for s in patchfields.states
            @test s.strain≈expected rtol=1e-12 atol=1e-14
            @test s.stress≈D*expected rtol=1e-12 atol=1e-5
        end
        axis=[.3,.7,-.2];axis/=norm(axis);V=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
        Q=I+sin(.73)*V+(1-cos(.73))*V^2
        Xq=X*Q'.+[.2 -.3 .4];uq=vec(Q*reshape(u,3,8))
        rotated=H.hexa8_section_fields(Xq,E,nu,uq;points=all_points)
        for (a,b) in zip(fields.states,rotated.states)
            stress=[a.stress[1] a.stress[4] a.stress[6];a.stress[4] a.stress[2] a.stress[5];a.stress[6] a.stress[5] a.stress[3]]
            stress=Q*stress*Q'
            @test b.stress≈[stress[1,1],stress[2,2],stress[3,3],stress[1,2],stress[2,3],stress[1,3]] rtol=2e-11 atol=1e-5
        end
        if kind!=:distorted
            @test fields.states[1].B≈H.solid_centroid_B_hexa8(X) rtol=1e-12 atol=1e-13
        else
            @test norm(fields.states[1].B-H.solid_centroid_B_hexa8(X))>1e-3
        end
    end
end

end # module Hexa8RecoveryPhysicalFixture

using Test
module Hexa8RecoveryRouteFixture
using Test, LinearAlgebra, OpenJFEM
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver
const signs=[-1. -1. -1.;1. -1. -1.;1. 1. -1.;-1. 1. -1.;
             -1. -1. 1.;1. -1. 1.;1. 1. 1.;-1. 1. 1.]
function compatible_B(X,point)
    r,s,t=point;dN=zeros(3,8)
    for i=1:8
        ri,si,ti=signs[i,:]
        dN[1,i]=ri*(1+si*s)*(1+ti*t)/8
        dN[2,i]=si*(1+ri*r)*(1+ti*t)/8
        dN[3,i]=ti*(1+ri*r)*(1+si*s)/8
    end
    G=(dN*X)\dN;B=zeros(6,24)
    for i=1:8
        c=3(i-1);dx,dy,dz=G[:,i]
        B[1,c+1]=dx;B[2,c+2]=dy;B[3,c+3]=dz
        B[4,c+1]=dy;B[4,c+2]=dx
        B[5,c+2]=dz;B[5,c+3]=dy
        B[6,c+1]=dz;B[6,c+3]=dx
    end
    B
end
function checks()
    mktempdir() do dir
        X=signs.*[.5 .2 .1];X[7,:].+=[.08,.04,.03]
        path=joinpath(dir,"nonaffine_solid.bdf")
        grids=join(["GRID,$i,,"*join(X[i,:],",") for i=1:8],"\n")
        write(path,"SOL 101\nCEND\nBEGIN BULK\n"*grids*
            "\nCHEXA,1,1,1,2,3,4,5,6\n+,7,8\nPSOLID,1,1\n"*
            "MAT1,1,7.e10,,.3,2700.\nENDDATA\n")
        for route in (:natural,:wilson,:alternate_eas,:abaqus)
            model=OpenJFEM.bdf_to_model(path)
            route===:abaqus && (only(values(model["CSOLIDs"]))["ABAQUS_TYPE"]="C3D8")
            withenv("JFEM_CHEXA8_EAS" => string(route!==:wilson),
                    "JFEM_CHEXA8_NATURAL_SHEAR" => string(route!==:alternate_eas)) do
                K,ids,coords,ndof,R,_,rbe,normals=S.assemble_stiffness(model)
                tdofs=[6(ids[i]-1)+d for i=1:8 for d=1:3]
                fields=F.hexa8_section_fields(X,7e10,.3,zeros(24))
                expected_K=route===:abaqus ? F.stiffness_hexa8_abaqus(X,7e10,.3) : F.stiffness_hexa8(X,7e10,.3)
                @test Matrix(K[tdofs,tdofs])≈expected_K rtol=2e-13
                route===:natural && @test expected_K≈fields.stiffness rtol=2e-13
                D=F.iso_3d_constitutive(7e10,.3)
                for pattern in (:general,:affine)
                    A=[.01 -.003 .002;.004 -.005 .007;-.002 .001 .008]
                    u_el=pattern===:affine ? vec((X*A')') : 1e-3sin.(collect(1.:24.))
                    u=zeros(ndof);u[tdofs]=u_el
                    output=Dict{String,Any}(k=>Dict("chexa"=>Any[],"ctetra"=>Any[],"cpenta"=>Any[]) for k in ("stresses","strains"))
                    stressmax=Dict{Int,Float64}()
                    S.recover_solid_stresses!(model,ids,coords,R,u,stressmax,output)
                    row=only(output["stresses"]["chexa"])
                    strains=only(output["strains"]["chexa"])
                    points=vcat([(0.,0.,0.)],[Tuple(signs[i,:]) for i=1:8])
                    fields=F.hexa8_section_fields(X,7e10,.3,u_el;points=points)
                    centroid_B=route===:natural ? fields.states[1].B :
                        route===:abaqus ? F.solid_centroid_B_hexa8_abaqus(X) : F.solid_centroid_B_hexa8(X)
                    expected_stress,expected_strain,vm=F.stress_solid_3d(centroid_B,D,u_el)
                    @test [row[k] for k in ("sxx","syy","szz","txy","tyz","tzx")]≈expected_stress rtol=2e-12
                    @test [strains[k] for k in ("exx","eyy","ezz","gxy","gyz","gzx")]≈expected_strain rtol=2e-12
                    @test row["von_mises"]≈vm rtol=2e-12
                    @test stressmax[1]≈vm rtol=2e-12
                    if route===:abaqus
                        @test !haskey(row,"corners")
                    else
                        @test length(row["corners"])==8
                        for (i,corner) in enumerate(row["corners"])
                            B=route===:natural ? fields.states[i+1].B : compatible_B(X,points[i+1])
                            @test [corner[k] for k in ("sxx","syy","szz","txy","tyz","tzx")]≈D*B*u_el rtol=2e-12
                        end
                    end
                    # Kg deliberately retains the existing constant-prestress
                    # integration; only the field used to compute that stress
                    # must match the elastic element.
                    Kg=S.assemble_geometric_stiffness(model,ids,coords,R,ndof,u,normals,rbe)
                    prestress_B=route===:natural ? fields.states[1].B : F.solid_centroid_B_hexa8(X)
                    @test Matrix(Kg[tdofs,tdofs])≈F.geometric_stiffness_hexa8(X,D*prestress_B*u_el) rtol=2e-12
                    if route===:natural && pattern===:general
                        @test norm(expected_stress-D*F.solid_centroid_B_hexa8(X)*u_el)>1e-3norm(expected_stress)
                    elseif route===:natural && pattern===:affine
                        @test expected_stress≈D*[A[1,1],A[2,2],A[3,3],A[1,2]+A[2,1],A[2,3]+A[3,2],A[1,3]+A[3,1]] rtol=2e-12
                    end
                end
            end
        end
    end
end
@testset "Enhanced solid parser, assembly, output and prestress routes" begin
    checks()
end
end
