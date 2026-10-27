using Test
module NodeCoordinateNormalBranchFixture
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver

function fixture(dir; angle=80., y=-.6, z=.8)
    path=joinpath(dir,"normal_geometry_derivative.bdf")
    write(path,"""
SOL 101
CEND
BEGIN BULK
PARAM,SNORM,$angle
PARAM,K6ROT,1.
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,1.,0.
GRID,4,,0.,$y,$z
CTRIA3,1,1,1,2,3
CTRIA3,2,1,1,4,2
PSHELL,1,1,.04,1,,1
MAT1,1,73000.,,.27,2.6
ENDDATA
""")
    return OpenJFEM.bdf_to_model(path)
end

function independent_difference(m,u)
    coords=m["GRIDs"]["4"]["X"];x=Float64(coords[2]);h=max(abs(x)*1e-6,1e-8)
    try
        coords[2]=x+h;Kp,=S.assemble_stiffness(m)
        coords[2]=x-h;Km,=S.assemble_stiffness(m)
        return ((Kp-Km)*u)/(2h)
    finally
        coords[2]=x
    end
end

function audit_action_cancellation(m,u,actual)
    coords=m["GRIDs"]["4"]["X"];x=Float64(coords[2]);h=max(abs(x)*1e-6,1e-8)
    try
        coords[2]=x+h;Kp,=S.assemble_stiffness(m)
        coords[2]=x-h;Km,=S.assemble_stiffness(m)
        # These are the same Float64 matrices and vector used by the existing
        # derivative. Only the products/subtraction are recomputed at 256 bits.
        # The conservative gamma_(n+4) bound covers each dot product, subtraction
        # and final scaling; eps rather than unit roundoff adds a factor of two.
        n=length(u);gamma=(n+4)*eps(Float64)/(1-(n+4)*eps(Float64))
        bound=gamma*((abs.(Kp)+abs.(Km))*abs.(u))/(2h)
        exact=setprecision(BigFloat,256) do
            (BigFloat.(Matrix(Kp))*BigFloat.(u)-BigFloat.(Matrix(Km))*BigFloat.(u))/(2BigFloat(h))
        end
        product_error=Float64(norm(BigFloat.(actual)-exact))
        matrix_difference=((Kp-Km)*u)/(2h)
        matrix_error=Float64(norm(BigFloat.(matrix_difference)-exact))
        println("NODE_COORD_FD_CONDITIONING ",
            (coordinate=x,step=h,action_norm=norm(actual),
             action_product_error=product_error,matrix_difference_error=matrix_error,
             action_product_error_bound=norm(bound),
             two_arithmetic_forms_difference=norm(actual-matrix_difference)))
        @test all(isfinite,actual)
        @test product_error<=norm(bound)
    finally
        coords[2]=x
    end
end

function checks()
    mktempdir() do dir
        dv=Dict{String,Any}("type"=>"node_coord","grid"=>4,"comp"=>2)
        u=sin.(collect(1.:24.))
        m=fixture(dir);original=deepcopy(m["GRIDs"])
        trace=S._node_coord_snorm_branch_signature(m)
        @test Set(keys(trace))==Set(1:4)
        actual=S._dKdx_u_node_coord(dv,m,u,24)
        expected=independent_difference(m,u)
        @test norm(expected)>1e-6
        @test actual≈expected rtol=3e-8 atol=3e-7
        @test m["GRIDs"]==original
        # Signatures record topology only, so ordinary small geometry changes
        # and a common proper rotation do not look like branch transitions.
        moved=deepcopy(m);moved["GRIDs"]["4"]["X"][2]+=.01
        @test S._node_coord_snorm_branch_signature(moved)==trace
        Q=[0. -1. 0.;1. 0. 0.;0. 0. 1.]
        rotated=deepcopy(m)
        for g in values(rotated["GRIDs"]);g["X"]=Q*g["X"];end
        @test S._node_coord_snorm_branch_signature(rotated)==trace
        reordered=deepcopy(m)
        reordered["CSHELLs"]=Dict(reverse(collect(m["CSHELLs"])))
        @test S._node_coord_snorm_branch_signature(reordered)==trace

        # At orthogonal incident normals the coherent-axis partition changes
        # across the geometry step. The old central quotient is only a secant.
        boundary=fixture(dir;y=0.,z=1.)
        before=deepcopy(boundary["GRIDs"])
        err=try S._dKdx_u_node_coord(dv,boundary,u,24);nothing catch e;e end
        @test err isa ArgumentError
        @test occursin("generated SNORM",sprint(showerror,err))
        @test boundary["GRIDs"]==before

        # A separate generated-angle acceptance switch is also rejected.
        acceptance=fixture(dir;angle=30.,y=-.5,z=sqrt(3.)/2)
        before=deepcopy(acceptance["GRIDs"])
        @test_throws ArgumentError S._dKdx_u_node_coord(dv,acceptance,u,24)
        @test acceptance["GRIDs"]==before

        # Both shared hinge GRIDs are prescribed, so their unused generated
        # choices must not disable an otherwise smooth geometry derivative.
        for n in (1,2)
            boundary["SNORMs"][string(n)]=Dict("GID"=>n,"CID"=>0,"N"=>[0.,.6,.8])
        end
        explicit_trace=S._node_coord_snorm_branch_signature(boundary)
        @test !haskey(explicit_trace,1) && !haskey(explicit_trace,2)
        explicit_coordinates=deepcopy(boundary["GRIDs"])
        actual=S._dKdx_u_node_coord(dv,boundary,u,24)
        # This boundary is excluded from the generated trace. Verify the guard
        # and restoration independently of cancellation in an h=1e-8 quotient.
        @test all(isfinite,actual)
        @test boundary["GRIDs"]==explicit_coordinates
        audit_action_cancellation(boundary,u,actual)
        @test boundary["GRIDs"]==explicit_coordinates

        # A common rigid translation preserves the physical hinge and prescribed
        # normals, while conditioning the existing relative geometry-FD step.
        # Keep the original accuracy tolerances on the translated geometry.
        translated=deepcopy(boundary)
        for g in values(translated["GRIDs"]);g["X"][2]+=2.;end
        @test S._node_coord_snorm_branch_signature(translated)==explicit_trace
        translated_coordinates=deepcopy(translated["GRIDs"])
        actual=S._dKdx_u_node_coord(dv,translated,u,24)
        @test actual≈independent_difference(translated,u) rtol=3e-8 atol=3e-7
        @test translated["GRIDs"]==translated_coordinates

        # Preserve forward STATIC/generic override precedence in the trace.
        withenv("JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"80", "JFEM_PARAM_SNORM_OVERRIDE"=>"-1") do
            @test isempty(S._node_coord_snorm_branch_signature(m))
        end
        withenv("JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"-1", "JFEM_PARAM_SNORM_OVERRIDE"=>"80") do
            @test S._node_coord_snorm_branch_signature(m)==trace
        end
        withenv("JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"-1", "JFEM_PARAM_SNORM_OVERRIDE"=>"invalid") do
            @test isempty(S._node_coord_snorm_branch_signature(m))
        end
    end
end
end
@testset "Node-coordinate finite differences retain generated-normal branches" begin
    NodeCoordinateNormalBranchFixture.checks()
end
