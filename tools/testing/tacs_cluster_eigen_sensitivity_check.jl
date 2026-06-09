# Synthetic guard for repeated/clustered eigenvalue sensitivity helpers.
#
# For an exact repeated eigenvalue, the directional derivatives are the
# eigenvalues of the perturbation projected onto the repeated-mode subspace with
# the correct generalized metric. This guard checks modal and buckling variants
# and verifies invariance under a non-orthonormal subspace basis.
#
# Usage:
#   julia --project=. tools/testing/tacs_cluster_eigen_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relerr(a, b)
    return norm(sort(Float64.(a)) .- sort(Float64.(b))) / max(norm(a), norm(b), 1e-30)
end

function main()
    cluster = OpenJFEM._tacs_eigenvalue_cluster_modes([10.0, 10.0 + 5e-9, 12.0], 1; rel_tol=1e-8)
    @test cluster == [1, 2]
    derivatives = [2.0, -1.0, 0.5]
    @test OpenJFEM._tacs_select_cluster_derivative(derivatives, 0.25; policy=:current_mode) == 0.25
    @test OpenJFEM._tacs_select_cluster_derivative(derivatives, 0.25; policy=:min) == -1.0
    @test OpenJFEM._tacs_select_cluster_derivative(derivatives, 0.25; policy=:max) == 2.0
    @test OpenJFEM._tacs_select_cluster_derivative(derivatives, 0.25; policy=:mean) == 0.5

    tracking_modes = [1.0 0.0; 0.0 1.0; 0.0 0.0]
    selected_mode, mac_scores = OpenJFEM._tacs_select_mode_by_mac(
        tracking_modes,
        [0.05, 0.95, 0.0];
        candidate_modes=[1, 2],
    )
    @test selected_mode == 2
    @test mac_scores[2] > mac_scores[1]

    D = [2.0 0.5; 0.5 -1.0]
    Phi = [1.0 0.30; 0.20 1.10]
    modal_expected = eigvals(Symmetric(D))
    modal_hook = OpenJFEM._tacs_modal_cluster_projected_derivatives(
        Phi,
        D,
        zeros(2, 2),
        Matrix{Float64}(I, 2, 2),
        5.0,
    )
    modal_relerr = _relerr(modal_hook, modal_expected)
    @test modal_relerr < 1e-12

    M = Diagonal([2.0, 3.0])
    dK = Diagonal([4.0, 9.0])
    modal_metric_hook = OpenJFEM._tacs_modal_cluster_projected_derivatives(
        Matrix{Float64}(I, 2, 2),
        dK,
        zeros(2, 2),
        M,
        7.0,
    )
    modal_metric_expected = [2.0, 3.0]
    modal_metric_relerr = _relerr(modal_metric_hook, modal_metric_expected)
    @test modal_metric_relerr < 1e-12

    B = [4.0 -0.2; -0.2 1.0]
    buckling_expected = eigvals(Symmetric(B))
    buckling_hook = OpenJFEM._tacs_buckling_cluster_projected_derivatives(
        Phi,
        B,
        zeros(2, 2),
        -Matrix{Float64}(I, 2, 2),
        3.0,
    )
    buckling_relerr = _relerr(buckling_hook, buckling_expected)
    @test buckling_relerr < 1e-12

    println("TACS clustered eigenvalue sensitivity check passed")
    println("  cluster modes          = ", cluster)
    println("  policy derivatives     = ", derivatives)
    println("  MAC selected mode      = ", selected_mode)
    println("  modal derivatives      = ", modal_hook)
    println("  modal rel error        = ", modal_relerr)
    println("  modal metric rel error = ", modal_metric_relerr)
    println("  buckling derivatives   = ", buckling_hook)
    println("  buckling rel error     = ", buckling_relerr)
end

main()
