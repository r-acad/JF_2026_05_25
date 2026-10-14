# Worker processes activate the selected solver project before reaching here.
# Reuse its normal package cache, while preventing a different LOAD_PATH entry
# from silently selecting another installation.
function load_cached_jfem(repository::AbstractString)
    isdefined(@__MODULE__,:OpenJFEM)||Core.eval(@__MODULE__,:(import OpenJFEM))
    # `import` may have created this binding after the caller's world began.
    native=Base.invokelatest(getfield,@__MODULE__,:OpenJFEM)
    actual=realpath(pathof(native))
    expected=realpath(joinpath(repository,"src","OpenJFEM.jl"))
    matches=Sys.iswindows() ? lowercase(actual)==lowercase(expected) : actual==expected
    matches||error("Loaded JFEM package does not match the selected repository: $actual (expected $expected)")
    native
end
