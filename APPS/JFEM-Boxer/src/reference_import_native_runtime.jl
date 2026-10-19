# Read-only native input context. These are the same parser/model builders and
# load definitions used by OpenJFEM, without loading its numerical pipeline,
# result writers, AD stack or package precompile workload just to inspect a mesh.
module ImportNative
using LinearAlgebra, SparseArrays, Statistics, StaticArrays, Dates
import JSON
const REPOSITORY=getfield(parentmodule(@__MODULE__),:IMPORT_REPO)
include(joinpath(REPOSITORY,"src","parsing","ReferenceParser.jl"))
include(joinpath(REPOSITORY,"src","ModelBuilder.jl"))
include(joinpath(REPOSITORY,"src","abaqus_input.jl"))
include(joinpath(REPOSITORY,"src","card_inventory.jl"))

module Solver
using LinearAlgebra, SparseArrays, Statistics, StaticArrays, Dates
import JSON
const REPOSITORY=parentmodule(@__MODULE__).REPOSITORY
# Input inspection never enters an assembly snapshot. Preserve the native
# helpers' live-environment behavior without loading element kernels.
module FEM
_fem_env_get(key::AbstractString,default::AbstractString)=get(ENV,key,default)
end
include(joinpath(REPOSITORY,"src","solver","input_context.jl"))
include(joinpath(REPOSITORY,"src","solver","helpers.jl"))
include(joinpath(REPOSITORY,"src","solver","loads.jl"))
end

"""Whether a selected visualization load needs the numerical mass/beam operators.

Simple point forces, moments and face pressures use the shared read-only load
resolver. Body/ACCEL1 loads and PLOAD1 use the complete native runtime only when
selected, so their display remains exactly consistent with the analysis.
"""
function needs_numerical_load_runtime(model)
    control=model["CASE_CONTROL"];subcases=get(control,"SUBCASES",Dict())
    rows=isempty(subcases) ? [control] : [merge(Dict(key=>value for (key,value) in control if key!="SUBCASES"),sub) for sub in values(subcases)]
    selected=Set{Int}();thermal=false
    for row in rows
        sid=get(row,"LOAD",nothing)
        sid===nothing||union!(selected,keys(Solver._load_sid_scales(model,Int(sid);include_zero=true)))
        thermal|=any(haskey(row,key) for key in ("TEMP","TEMPERATURE"))
    end
    thermal&&return true
    any(any(Int(get(card,"SID",0)) in selected for card in get(model,key,Any[])) for key in ("GRAVs","RFORCEs","ACCEL1s","PLOAD1s"))
end
end
