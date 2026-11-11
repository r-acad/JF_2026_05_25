"""Factor an exactly supported, positive-definite modal mass submatrix.

This is a bounded optimization for models whose inertia is concentrated at a
small subset of the free coordinates. No coordinate is removed from stiffness,
no diagonal mass threshold is used, and no small positive mass is discarded.
If the supported mass is singular or indefinite, use the general full pencil.
"""
function _sol103_mass_support(M::SparseMatrixCSC;
        max_support::Int=4096, max_fraction::Float64=0.25)
    n = size(M, 1)
    size(M, 2) == n || throw(DimensionMismatch("Modal mass must be square"))
    max_support > 0 || return (; eligible=false, reason="disabled")
    active = falses(n)
    rows, values = rowvals(M), nonzeros(M)
    for column in axes(M, 2), index in nzrange(M, column)
        value = values[index]
        isfinite(value) || return (; eligible=false, reason="nonfinite_mass")
        if !iszero(value)
            active[column] = true
            active[rows[index]] = true
        end
    end
    support = findall(active)
    r = length(support)
    0 < r <= max_support && r <= max_fraction * n ||
        return (; eligible=false, reason="support_not_small", support_size=r)
    Ms = M[support, support]
    diagonal = diag(Ms)
    all(x -> isfinite(x) && x > 0.0, diagonal) ||
        return (; eligible=false, reason="supported_mass_not_positive_definite", support_size=r)
    # A diagonal congruence makes the test insensitive to translation/rotation
    # units. Successful unregularized Cholesky retains every supported mass.
    root = sqrt.(diagonal)
    scale = Diagonal(inv.(root))
    scaled = scale * Ms * scale
    try
        factor = cholesky(Symmetric(scaled); check=true)
        # CHOLMOD factors scaled[p,p]. Undo that permutation before embedding
        # C, so M = E*C*C'*E' in the original free-coordinate order.
        C = Diagonal(root) * sparse(factor.L)[invperm(factor.p), :]
        all(isfinite, nonzeros(C)) ||
            return (; eligible=false, reason="nonfinite_mass_factor", support_size=r)
        return (; eligible=true, reason="exact_supported_mass_cholesky",
            support, C, full_size=n, support_size=r)
    catch err
        (err isa InterruptException || err isa OutOfMemoryError) && rethrow()
        return (; eligible=false, reason="supported_mass_cholesky_failed", support_size=r)
    end
end

"""Equivalent symmetric modal operator on the exact mass support.

For A=K+alpha*M and M=E*C*C'*E', H=alpha*C'*E'*A^-1*E*C has
the same nonzero transformed roots alpha/(lambda+alpha) as the full pencil.
Backmapping uses the full stiffness solve, including every massless stiff DOF.
Each returned vector is independently owned, as required by KrylovKit.
"""
function _sol103_mass_support_operator(factor, mass_support, alpha::Float64)
    support, C = mass_support.support, mass_support.C
    rhs = zeros(Float64, mass_support.full_size)
    function operator(y)
        rhs[support] = C * y
        solution = factor \ rhs
        return alpha .* Vector{Float64}(C' * view(solution, support))
    end
    function backmap(y)
        full_rhs = zeros(Float64, mass_support.full_size)
        full_rhs[support] = C * y
        return Vector{Float64}(factor \ full_rhs)
    end
    return operator, backmap
end
