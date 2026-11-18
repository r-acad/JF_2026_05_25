# Certified all-mode bound for the equivalent simply-supported plate model.
# For engineering curvature k=(w_xx,w_yy,2w_xy):
#   int k'Dk >= lambda_min(D) int (Laplacian w)^2
#   int grad(w)'N grad(w) <= max_cell lambda_max(N) int |grad(w)|^2
#   int (Laplacian w)^2 >= pi^2(1/L^2+1/W^2) int |grad(w)|^2.
# Thus this utilization is an upper bound even when a finite Ritz basis has
# not converged. It is an optimization constraint, NOT the displayed plate RF.
using LinearAlgebra
import ForwardDiff

rf_membrane_tensor(N)=[N[1] N[3];N[3] N[2]]

function rf_extreme_space(matrix;minimum=false,tolerance=128size(matrix,1)*eps(Float64))
    pair=eigen(Symmetric(Matrix{Float64}(matrix)))
    value=minimum ? first(pair.values) : last(pair.values)
    indices=findall(v->abs(v-value)<=tolerance*max(maximum(abs,pair.values),floatmin(Float64)),pair.values)
    vectors=pair.vectors[:,indices]
    (;value,vectors,projector=vectors*transpose(vectors)/length(indices))
end

"""Conservative differentiable constraint for an unconverged Ritz response.

The reported physical RF stays on the original row. This separate response
uses a rigorous lower bound on capacity; it can be conservative in mass.
At repeated extrema, the matrix gradient is a declared Clarke selection and
the directional hook evaluates the projected extreme-eigenspace derivative.
"""
function rf_conservative_plate_response(row)
    haskey(row,"_plate_matrices")||throw(ArgumentError("A conservative plate bound needs its actual membrane and bending primitives"))
    unpack=row["_plate_matrices"];x=vcat(row["feature_values"],row["capacity_values"])
    baseline=unpack(x);Dscale=maximum(abs,rf_flat(baseline.D))
    isfinite(Dscale)&&Dscale>0||throw(ArgumentError("Plate bound needs a finite nonzero bending law"))
    Dspace=rf_extreme_space(rf_matrix(baseline.D)./Dscale;minimum=true)
    Dspace.value>0||throw(ArgumentError("Plate bound requires a positive definite bending law"))
    loads=baseline.cells===nothing ? [baseline.N] : [cell.N for cell in baseline.cells]
    Nscale=maximum(abs,reduce(vcat,loads));iszero(Nscale)&&(Nscale=1.)
    spaces=[rf_extreme_space(rf_membrane_tensor(N)./Nscale) for N in loads]
    peak=maximum(space.value for space in spaces)
    active=findall(space->abs(space.value-peak)<=256eps(Float64)*max(maximum(abs,reduce(vcat,loads))/Nscale,floatmin(Float64)),spaces)
    factor=Float64(row["assessment_factor"])/Float64(row["fixity_coefficient"])
    kernel=function(values)
        a=unpack(values);D=rf_matrix(a.D);N=a.cells===nothing ? [a.N] : [cell.N for cell in a.cells]
        d=sum(Dspace.projector.*D)/Dscale
        principal=sum(sum(spaces[i].projector.*rf_membrane_tensor(N[i])) for i in active)/(length(active)*Nscale)
        wave=pi^2*(1/a.L^2+1/a.W^2)
        factor*(Nscale/Dscale)*max(zero(principal),principal)/(d*wave)
    end
    # The primal certificate uses the actual extrema, never near-tie projector
    # averages (which could raise D_min or lower N_max).
    value=factor*(Nscale/Dscale)*max(0.,peak)/(Dspace.value*pi^2*(1/baseline.L^2+1/baseline.W^2))
    gradient=ForwardDiff.gradient(kernel,x);nf=length(row["feature_values"])
    bound=copy(row)
    bound["utilization"]=value;bound["raw_RF"]=value>0 ? 1/value : nothing;bound["no_demand"]=iszero(value)
    bound["feature_gradient"]=gradient[1:nf];bound["capacity_gradient"]=gradient[nf+1:end]
    bound["reported_raw_RF"]=row["raw_RF"];bound["reported_utilization"]=row["utilization"]
    bound["reported_basis_id"]=get(row,"basis_id",nothing)
    bound["constraint_value_origin"]="certified_all_mode_plate_bound"
    bound["certified_bound"]=true;bound["approximation"]=false;bound["converged"]=true
    bound["basis_id"]="all_modes_poincare_bound";bound["selected_modes"]=Any[];bound["basis_size"]=0
    bound["method"]="Conservative bending-eigenvalue / maximum membrane / Poincare bound"
    nonsmooth=length(active)>1||size(Dspace.vectors,2)>1||any(size(spaces[i].vectors,2)>1 for i in active)||iszero(peak)
    bound["derivative_status"]=nonsmooth ? "piecewise_smooth" : "analytic_local"
    bound["gradient_class"]=nonsmooth ? "selected_Clarke_subgradient_of_certified_bound" : "classical_derivative_of_certified_bound"
    bound["status"]="ok";bound["reason"]="Optimization uses a certified upper utilization bound; the displayed finite-basis RF is preserved separately"
    bound["_evaluate"]=function(values)
        a=unpack(values);dminimum=minimum(eigvals(Symmetric(Matrix(rf_matrix(a.D)./Dscale))))
        dminimum>0||throw(ArgumentError("Plate certificate requires positive bending stiffness"))
        N=a.cells===nothing ? [a.N] : [cell.N for cell in a.cells]
        nmaximum=maximum(maximum(eigvals(Symmetric(rf_membrane_tensor(n)./Nscale))) for n in N)
        factor*(Nscale/Dscale)*max(0.,nmaximum)/(dminimum*pi^2*(1/a.L^2+1/a.W^2))
    end
    bound["_directional"]=function(direction)
        length(direction)==length(x)||throw(ArgumentError("Plate-bound direction has the wrong length"))
        packet=ForwardDiff.jacobian([0.]) do alpha
            a=unpack(x.+only(alpha).*direction)
            N=a.cells===nothing ? [a.N] : [cell.N for cell in a.cells]
            vcat(rf_flat(a.D),reduce(vcat,N),[a.L,a.W])
        end
        dv=vec(packet);dD=rf_matrix(dv[1:9])./Dscale
        dminimum=minimum(eigvals(Symmetric(transpose(Dspace.vectors)*dD*Dspace.vectors)))
        dmaximum=maximum(begin
            local_dN=dv[9+3(i-1)+1:9+3i]./Nscale
            V=spaces[i].vectors
            maximum(eigvals(Symmetric(transpose(V)*rf_membrane_tensor(local_dN)*V)))
        end for i in active)
        positive=max(0.,peak);dpositive=peak>0 ? dmaximum : peak<0 ? 0. : max(0.,dmaximum)
        wave=pi^2*(1/baseline.L^2+1/baseline.W^2)
        dwave=-2pi^2*(dv[end-1]/baseline.L^3+dv[end]/baseline.W^3)
        factor*(Nscale/Dscale)*(dpositive/(Dspace.value*wave)-positive*dminimum/(Dspace.value^2*wave)-
            positive*dwave/(Dspace.value*wave^2))
    end
    bound
end

function rf_optimization_responses(rows,bound_ids::Set{String};discover=true)
    if discover
        for row in rows
            (get(row,"approximation",false)||get(row,"converged",true)===false)&&push!(bound_ids,row["response_id"])
        end
    end
    [row["response_id"] in bound_ids ? rf_conservative_plate_response(row) : row for row in rows]
end

"""Monotonic mathematical constraint policy for one sizing run or checkpoint."""
mutable struct RFOptimizationConstraintPolicy
    revision::Int
    bound_ids::Set{String}
end

function RFOptimizationConstraintPolicy(restart=nothing)
    restart===nothing&&return RFOptimizationConstraintPolicy(0,Set{String}())
    revision=get(restart,"constraint_revision",0)
    revision isa Integer&&revision>=0||throw(ArgumentError("Saved sizing constraint revision must be a nonnegative integer"))
    raw=get(restart,"certified_bound_response_ids",String[])
    raw isa AbstractVector||throw(ArgumentError("Saved sizing certificate IDs must be an array"))
    ids=String.(raw)
    length(unique(ids))==length(ids)||throw(ArgumentError("Saved sizing certificate IDs must be unique"))
    !isempty(ids)&&revision==0&&throw(ArgumentError("Saved sizing certificate membership requires a constraint revision"))
    isempty(ids)&&revision>0&&throw(ArgumentError("Saved sizing constraint revision requires certified plate membership"))
    RFOptimizationConstraintPolicy(Int(revision),Set(ids))
end

function rf_optimization_policy_responses!(policy::RFOptimizationConstraintPolicy,rows)
    membership=Set(String(row["response_id"]) for row in rows)
    issubset(policy.bound_ids,membership)||throw(ArgumentError("Saved certified plate membership is absent from the current sizing responses"))
    # Discover transactionally: failed conversion must not install a certificate
    # or advance the revision before its physical primitives are validated.
    proposal=copy(policy.bound_ids)
    result=rf_optimization_responses(rows,proposal;discover=true)
    if proposal!=policy.bound_ids
        policy.bound_ids=proposal;policy.revision+=1
    end
    result
end

rf_optimization_policy_metadata(policy::RFOptimizationConstraintPolicy)=Dict{String,Any}(
    "constraint_revision"=>policy.revision,"certified_bound_response_ids"=>sort!(collect(policy.bound_ids)))

rf_optimization_cache_valid(last_design,cached,x,policy::RFOptimizationConstraintPolicy)=
    last_design==x&&cached!==nothing&&get(cached,"constraint_revision",0)==policy.revision
