using Test

module PlyFaceRecoveryFixture
using Test, OpenJFEM, LinearAlgebra
const S = OpenJFEM.Solver

# Independent tensor rotation, retaining engineering shear only at the boundary.
function rotate_strain(e,angle)
    c,s=cos(angle),sin(angle);R=[c s;-s c]
    t=R*[e[1] e[3]/2;e[3]/2 e[2]]*R'
    [t[1,1],t[2,2],2t[1,2]]
end
function fixture(path;triangle=false,isotropic=false,sol=101,angle=23.)
    points=triangle ? [0. 0. 0.;1. 0. 0.;.1 .5 0.] : [0. 0. 0.;1. 0. 0.;1. .5 0.;0. .5 0.]
    lines=["SOL $sol","CEND","BEGIN BULK","PARAM,K6ROT,0.","PARAM,SNORM,0."]
    for i in axes(points,1);push!(lines,"GRID,$i,,"*join(points[i,:],","));end
    push!(lines,triangle ? "CTRIA3,1,101,1,2,3,$angle" : "CQUAD4,1,101,1,2,3,4,$angle")
    append!(lines,["MAT1,1,7.E10,,.3,2700.","MAT8,2,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600."])
    mid=isotropic ? 1 : 2
    append!(lines,["PCOMP,101,-.003","+,$mid,.002,0.,YES,$mid,.002,45.,YES","+,$mid,.002,-30.,YES","ENDDATA"])
    write(path,join(lines,'\n')*"\n")
    OpenJFEM.bdf_to_model(path),points
end
function run_checks()
    mktempdir() do dir
        eps=[.0002,-.0001,.0003];kap=[.003,-.002,.004]
        for triangle in (false,true),isotropic in (false,true),sol in (101,105,106)
            m,X=fixture(joinpath(dir,"ply.bdf");triangle,isotropic,sol)
            n=size(X,1);idmap=Dict(i=>i for i=1:n);R=[Matrix{Float64}(I,3,3) for _=1:n];u=zeros(6n)
            for i=1:n
                x,y=X[i,1],X[i,2]
                u[6(i-1)+1]=eps[1]*x+eps[3]*y/2
                u[6(i-1)+2]=eps[2]*y+eps[3]*x/2
                u[6(i-1)+4]=-kap[2]*y-kap[3]*x/2
                u[6(i-1)+5]=kap[1]*x+kap[3]*y/2
            end
            result=Dict{String,Any}(k=>Dict("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
            S.recover_shell_stresses!(m,idmap,X,R,u,Dict{Int,typeof(OpenJFEM.SVector(0.,0.,0.))}(),Dict{Int,Float64}(),result)
            family=triangle ? "tria3" : "quad4";strain=only(result["strains"][family]);stress=only(result["stresses"][family])
            @test strain["ply_faces_complete"] && stress["ply_faces_complete"]
            @test length(strain["ply_faces"])==3
            @test strain["z1"]["fiber_dist"]==0.
            @test strain["z2"]["fiber_dist"]==-1.
            for (i,(er,sr)) in enumerate(zip(strain["ply_faces"],stress["ply_faces"]))
                @test er["ply"]==i
                @test er["material_id"]==(isotropic ? 1 : 2)
                @test er["material_type"]==(isotropic ? "MAT1" : "MAT8")
                mat=m["MATs"][string(er["material_id"])];E1=get(mat,"E1",get(mat,"E",0.));E2=get(mat,"E2",E1)
                nu=get(mat,"NU12",get(mat,"NU",0.));G=get(mat,"G12",get(mat,"G",0.));d=1-nu^2*E2/E1
                Q=[E1/d nu*E2/d 0.;nu*E2/d E2/d 0.;0. 0. G]
                for (face,z) in (("bottom",er["z_bottom"]),("top",er["z_top"]))
                    expected=rotate_strain(eps+z*kap,deg2rad(23+er["angle_deg"]))
                    actual=[er[face][k] for k in ("e1","e2","g12")]
                    @test actual≈expected rtol=1e-9 atol=1e-12
                    sigma=Q*expected
                    @test [sr[face][k] for k in ("s1","s2","t12")]≈sigma rtol=1e-9 atol=1e-4
                    @test sr[face]["von_mises"]≈sqrt(sigma[1]^2-sigma[1]*sigma[2]+sigma[2]^2+3sigma[3]^2) rtol=1e-9
                end
            end
            # Compact static preload recovery must retain its small legacy schema.
            compact=Dict{Int,Any}()
            S.recover_shell_stresses!(m,idmap,X,R,u,Dict{Int,typeof(OpenJFEM.SVector(0.,0.,0.))}(),Dict{Int,Float64}(),Dict{String,Any}();static_fields=compact)
            @test length(compact)==1
            @test length(compact[1])==3
        end
        m,_=fixture(joinpath(dir,"unavailable.bdf"));prop=m["PSHELLs"]["101"]
        a,b,note=S._recovery_ply_face_rows(prop,m["MATs"],eps,kap,.1,.2)
        @test isempty(a)&&isempty(b)&&occursin("different",note)
        a,b,note=S._recovery_ply_face_rows(prop,m["MATs"],[NaN,0.,0.],kap,0.,0.)
        @test isempty(a)&&isempty(b)&&occursin("nonfinite",note)
        # General anisotropy may retain an equivalent E for legacy kernels;
        # that convenience value must not reclassify a MAT2 ply as isotropic.
        unsupported=deepcopy(m["MATs"])
        unsupported["2"]=Dict{String,Any}("TYPE"=>"MAT2","E"=>7e10,"G11"=>7e10)
        a,b,note=S._recovery_ply_face_rows(prop,unsupported,eps,kap,0.,0.)
        @test isempty(a)&&isempty(b)&&occursin("unsupported",note)
    end
end
end

@testset "Explicit all-ply bottom/top recovery in material axes" begin
    PlyFaceRecoveryFixture.run_checks()
end
