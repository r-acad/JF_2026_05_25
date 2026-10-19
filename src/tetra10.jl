# Quadratic continuum tetrahedron and displacement-only C3D8 compatibility.
# Included inside FEM after iso_3d_constitutive is available.
# Interpolation/integration reference (C3D10: four stiffness points):
# https://docs.software.vt.edu/abaqusv2025/English/SIMACAETHERefMap/simathe-c-tritetwedge.htm

const _TETRA10_EDGES = ((1,2),(2,3),(1,3),(1,4),(2,4),(3,4))
const _TETRA10_A = (5.0 + 3.0sqrt(5.0))/20.0
const _TETRA10_B = (5.0 - sqrt(5.0))/20.0
const _TETRA10_STIFFNESS_POINTS = ((_TETRA10_B,_TETRA10_B,_TETRA10_B),
    (_TETRA10_A,_TETRA10_B,_TETRA10_B),(_TETRA10_B,_TETRA10_A,_TETRA10_B),
    (_TETRA10_B,_TETRA10_B,_TETRA10_A))
const _TETRA10_GAUSS5_X = (0.0469100770306680,0.2307653449471585,0.5,0.7692346550528415,0.9530899229693320)
const _TETRA10_GAUSS5_W = (0.1184634425280945,0.2393143352496832,0.2844444444444444,0.2393143352496832,0.1184634425280945)

function _tetra10_shape(r::Float64,s::Float64,t::Float64)
    L = SVector(1.0-r-s-t,r,s,t)
    dL = @SMatrix [-1.0 1.0 0.0 0.0; -1.0 0.0 1.0 0.0; -1.0 0.0 0.0 1.0]
    N = MVector{10,Float64}(undef)
    dN = MMatrix{3,10,Float64}(undef)
    @inbounds for i in 1:4
        N[i] = L[i]*(2.0L[i]-1.0)
        for k in 1:3; dN[k,i] = (4.0L[i]-1.0)*dL[k,i]; end
    end
    @inbounds for (edge,(i,j)) in enumerate(_TETRA10_EDGES)
        N[edge+4] = 4.0L[i]*L[j]
        for k in 1:3; dN[k,edge+4] = 4.0*(L[j]*dL[k,i]+L[i]*dL[k,j]); end
    end
    return SVector(N),SMatrix(dN)
end

function _solid_positive_jacobian(J)
    d = det(J)
    isfinite(d) && d > 0.0 || throw(DomainError(d,"Solid element has a nonpositive or nonfinite Jacobian at an integration point"))
    return d
end

function _tetra10_coordinates(coords::AbstractMatrix{Float64})
    size(coords) == (10,3) || throw(DimensionMismatch("TETRA10 coordinates must be 10 by 3"))
    all(isfinite,coords) || throw(ArgumentError("TETRA10 coordinates must be finite"))
    return SMatrix{10,3,Float64}(coords)
end

function _solid_B_tetra10(dNdx)
    B = zeros(6,3size(dNdx,2))
    @inbounds for i in axes(dNdx,2)
        c = 3(i-1); dx,dy,dz = dNdx[1,i],dNdx[2,i],dNdx[3,i]
        B[1,c+1]=dx; B[2,c+2]=dy; B[3,c+3]=dz
        B[4,c+1]=dy; B[4,c+2]=dx
        B[5,c+2]=dz; B[5,c+3]=dy
        B[6,c+1]=dz; B[6,c+3]=dx
    end
    return B
end

function _solid_elasticity_tetra10(E,nu)
    isfinite(E) && E > 0 && isfinite(nu) && -1 < nu < 0.5 || throw(ArgumentError("Isotropic elasticity requires finite E > 0 and -1 < nu < 0.5"))
    return iso_3d_constitutive(E,nu)
end

"""
    stiffness_tetra10(coords, E, nu) -> 30 by 30 matrix

Full quadratic, isoparametric ten-node tetrahedron, with three translations
at every node. Corner nodes 1:4 precede edges (1,2),(2,3),(1,3),(1,4),(2,4),(3,4).
Uses the symmetric four-point stiffness rule. Every sampled Jacobian must be
positive; inverted elements are rejected rather than integrated with abs(detJ).
"""
function stiffness_tetra10(coords::AbstractMatrix{Float64},E::Float64,nu::Float64)
    X = _tetra10_coordinates(coords)
    D = _solid_elasticity_tetra10(E,nu)
    K = zeros(30,30)
    for (r,s,t) in _TETRA10_STIFFNESS_POINTS
        _,dN = _tetra10_shape(r,s,t)
        J = dN*X; weight = _solid_positive_jacobian(J)/24.0
        B = _solid_B_tetra10(J\dN)
        K .+= weight .* (B'*D*B)
    end
    return Matrix(Symmetric(K))
end

"""
    consistent_mass_tetra10(coords, rho) -> 30 by 30 matrix

Positive 5 by 5 by 5 Duffy-product Gauss integration of rho*N_i*N_j*detJ.
This integrates the degree-seven polynomial of quadratic curved geometry
exactly to roundoff (including the Duffy Jacobian). It is deliberately more
expensive than the fifteen-point rule used by some implementations.
Row-sum lumping is invalid: quadratic corner shape functions integrate to a
negative value. This routine returns the full positive definite consistent mass.
"""
function consistent_mass_tetra10(coords::AbstractMatrix{Float64},rho::Float64)
    X = _tetra10_coordinates(coords)
    isfinite(rho) && rho >= 0 || throw(ArgumentError("Density must be finite and nonnegative"))
    scalar = zeros(10,10)
    for i in 1:5,j in 1:5,k in 1:5
        a,b,c = _TETRA10_GAUSS5_X[i],_TETRA10_GAUSS5_X[j],_TETRA10_GAUSS5_X[k]
        N,dN = _tetra10_shape(a,(1-a)*b,(1-a)*(1-b)*c)
        weight = rho*_solid_positive_jacobian(dN*X)*(1-a)^2*(1-b)*
            _TETRA10_GAUSS5_W[i]*_TETRA10_GAUSS5_W[j]*_TETRA10_GAUSS5_W[k]
        scalar .+= weight .* (N*N')
    end
    M = zeros(30,30)
    @inbounds for i in 1:10,j in 1:10,a in 1:3
        M[3(i-1)+a,3(j-1)+a] = scalar[i,j]
    end
    return Matrix(Symmetric(M))
end

"""Engineering-strain matrix at the TETRA10 natural centroid (6 by 30)."""
function solid_centroid_B_tetra10(coords::AbstractMatrix{Float64})
    X = _tetra10_coordinates(coords)
    _,dN = _tetra10_shape(0.25,0.25,0.25)
    J = dN*X; _solid_positive_jacobian(J)
    return _solid_B_tetra10(J\dN)
end

function _geometric_stiffness_tetra10(coords,stress_at)
    X = _tetra10_coordinates(coords)
    scalar = zeros(10,10)
    for (r,s,t) in _TETRA10_STIFFNESS_POINTS
        _,dN = _tetra10_shape(r,s,t)
        J = dN*X; weight = _solid_positive_jacobian(J)/24.0; grad = J\dN
        sigma = stress_at(grad)
        length(sigma)==6 && all(isfinite,sigma) || throw(ArgumentError("Solid stress needs six finite Voigt components"))
        xx,yy,zz,xy,yz,zx = sigma
        S = @SMatrix [xx xy zx; xy yy yz; zx yz zz]
        scalar .+= weight .* (grad'*S*grad)
    end
    K = zeros(30,30)
    @inbounds for i in 1:10,j in 1:10,a in 1:3
        K[3(i-1)+a,3(j-1)+a] = scalar[i,j]
    end
    return Matrix(Symmetric(K))
end

"""TETRA10 initial-stress matrix; stress order is xx,yy,zz,xy,yz,zx."""
geometric_stiffness_tetra10(coords::AbstractMatrix{Float64},stress::AbstractVector{Float64}) =
    _geometric_stiffness_tetra10(coords,_ -> stress)

"""TETRA10 initial-stress matrix using displacement-derived stress at all four points."""
function geometric_stiffness_tetra10(coords::AbstractMatrix{Float64},u::AbstractVector{Float64},E::Float64,nu::Float64)
    length(u)==30 || throw(DimensionMismatch("TETRA10 displacement vector must have 30 entries"))
    D = _solid_elasticity_tetra10(E,nu)
    return _geometric_stiffness_tetra10(coords,grad -> D*(_solid_B_tetra10(grad)*u))
end

function _hexa8_abaqus_gradients(coords::AbstractMatrix{Float64})
    size(coords)==(8,3) || throw(DimensionMismatch("HEXA8 coordinates must be 8 by 3"))
    all(isfinite,coords) || throw(ArgumentError("HEXA8 coordinates must be finite"))
    xi = (-1.,1.,1.,-1.,-1.,1.,1.,-1.); eta = (-1.,-1.,1.,1.,-1.,-1.,1.,1.); zeta = (-1.,-1.,-1.,-1.,1.,1.,1.,1.)
    points = Tuple{Matrix{Float64},Float64}[]
    average = zeros(3,8); volume = 0.0; g = 1/sqrt(3.0)
    for r in (-g,g),s in (-g,g),t in (-g,g)
        dN = [xi[i]*(1+eta[i]*s)*(1+zeta[i]*t)/8 for k in 1:1,i in 1:8]
        dN = vcat(dN,[eta[i]*(1+xi[i]*r)*(1+zeta[i]*t)/8 for k in 1:1,i in 1:8],
            [zeta[i]*(1+xi[i]*r)*(1+eta[i]*s)/8 for k in 1:1,i in 1:8])
        J = dN*coords; weight = _solid_positive_jacobian(J); grad = J\dN
        average .+= weight .* grad; volume += weight
        push!(points,(grad,weight))
    end
    average ./= volume
    return points,average,volume
end

"""
    stiffness_hexa8_full(coords, E, nu; mean_dilatation=true)

Eight-point trilinear displacement brick, without incompatible/EAS modes.
The default mean-dilatation (B-bar) correction replaces the volumetric strain
by its volume average, as documented for the C3D8 formulation. Setting false
returns the unmodified full-integration displacement matrix for diagnostics.
This does not change the native CHEXA8 enhanced-strain implementation.
See https://docs.software.vt.edu/abaqusv2025/English/SIMACAETHERefMap/simathe-c-solidisoquadhex.htm
"""
function stiffness_hexa8_full(coords::AbstractMatrix{Float64},E::Float64,nu::Float64;mean_dilatation::Bool=true)
    points,average,_ = _hexa8_abaqus_gradients(coords)
    D = _solid_elasticity_tetra10(E,nu); K = zeros(24,24)
    for (grad,weight) in points
        B = _solid_B_tetra10(grad)
        if mean_dilatation
            @inbounds for node in 1:8,component in 1:3,row in 1:3
                B[row,3(node-1)+component] += (average[component,node]-grad[component,node])/3
            end
        end
        K .+= weight .* (B'*D*B)
    end
    return Matrix(Symmetric(K))
end

stiffness_hexa8_abaqus(coords::AbstractMatrix{Float64},E::Float64,nu::Float64) =
    stiffness_hexa8_full(coords,E,nu;mean_dilatation=true)

"""Centroid strain matrix with the same volume-averaged trace as C3D8 stiffness."""
function solid_centroid_B_hexa8_abaqus(coords::AbstractMatrix{Float64})
    _,average,_ = _hexa8_abaqus_gradients(coords)
    dN = (@SMatrix [-1.0 1.0 1.0 -1.0 -1.0 1.0 1.0 -1.0;
                   -1.0 -1.0 1.0 1.0 -1.0 -1.0 1.0 1.0;
                   -1.0 -1.0 -1.0 -1.0 1.0 1.0 1.0 1.0]) / 8.0
    J=dN*coords; _solid_positive_jacobian(J);grad=J\dN
    B=_solid_B_tetra10(grad)
    @inbounds for node in 1:8,component in 1:3,row in 1:3
        B[row,3(node-1)+component]+=(average[component,node]-grad[component,node])/3
    end
    return B
end
