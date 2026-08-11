# constraints.jl — RBE2, RBE3, MPC constraint assembly and DOF elimination

# Extracted from assemble_stiffness: processes all constraint elements and
# redistributes stiffness triplets for dependent DOFs.
# Returns: (rbe3_map, I_idx, J_idx, V_val)  — rbe3_map is the merged constraint map,
# and triplet arrays may be replaced if constraints exist.
@inline function _rigid_offset_matrix(dx::Float64, dy::Float64, dz::Float64)
    return [
        0.0   dz   -dy;
       -dz   0.0   dx;
        dy   -dx   0.0;
    ]
end

@inline function _rigid_component_row(node_R::AbstractMatrix, q_R::AbstractMatrix,
                                      dx::Float64, dy::Float64, dz::Float64,
                                      comp_dof::Int)
    comp_map = node_R' * q_R
    if comp_dof <= 3
        offset_map = node_R' * _rigid_offset_matrix(dx, dy, dz) * q_R
        return vcat(vec(comp_map[comp_dof, :]), vec(offset_map[comp_dof, :]))
    end
    return vcat(zeros(3), vec(comp_map[comp_dof - 3, :]))
end

@inline function _push_rigid_pairs!(pairs::Vector{Tuple{Int,Float64}}, base_dof::Int,
                                    coeff_row::AbstractVector{<:Real})
    for j in 1:length(coeff_row)
        coeff = Float64(coeff_row[j])
        if abs(coeff) > 1e-15
            push!(pairs, (base_dof + j, coeff))
        end
    end
    return pairs
end

@inline function _component_digits(value)
    return sort!([parse(Int, string(ch)) for ch in string(Int(value)) if isdigit(ch)])
end

@inline function _add_row_coeff!(row::Dict{Int,Float64}, dof::Int, coeff::Float64)
    abs(coeff) <= 1e-15 && return row
    row[dof] = get(row, dof, 0.0) + coeff
    if abs(row[dof]) <= 1e-15
        delete!(row, dof)
    end
    return row
end

@inline function _push_nonzero_triplet!(I_idx, J_idx, V_val,
                                        row::Int, col::Int, value)
    numeric_value = Float64(value)
    iszero(numeric_value) && return false
    push!(I_idx, row)
    push!(J_idx, col)
    push!(V_val, numeric_value)
    return true
end

"""
    _flatten_constraint_dependency_map(dependency_map; coefficient_tolerance=1e-15)

Recursively expand a merged RBE/MPC dependency map so every dependent DOF is
written directly in terms of terminal (non-dependent) DOFs. Already-flat rows
retain their exact original order and finite coefficients, including repeated
DOFs and zeros. Rows containing nested dependencies combine repeated terminal
coefficients, prune numerical zeros, and sort by terminal DOF.

Returns `(flat_map, diagnostics)`. A dependency cycle raises `ArgumentError`
with the deterministic cycle path before any matrix triplets are redistributed.
"""
function _flatten_constraint_dependency_map(dependency_map;
                                            coefficient_tolerance::Real=1e-15)
    atol = Float64(coefficient_tolerance)
    isfinite(atol) || throw(ArgumentError("Constraint coefficient tolerance must be finite"))
    atol = max(atol, 0.0)

    flat_map = Dict{Int,Vector{Tuple{Int,Float64}}}()
    states = Dict{Int,UInt8}()  # 0/unseen, 1/visiting, 2/complete
    depths = Dict{Int,Int}()
    stack = Int[]

    input_terms = Ref(0)
    nested_dependency_terms = Ref(0)
    combined_input_terms = Ref(0)
    terminal_contributions = Ref(0)
    combined_terminal_contributions = Ref(0)
    zero_input_terms_pruned = Ref(0)
    cancelled_input_dofs_pruned = Ref(0)
    zero_terminal_contributions_pruned = Ref(0)
    cancelled_terminal_dofs_pruned = Ref(0)
    changed_dependent_dofs = Ref(0)

    function accumulate_terminal!(row::Dict{Int,Float64}, dof::Int, coeff::Float64)
        terminal_contributions[] += 1
        isfinite(coeff) || throw(ArgumentError(
            "Non-finite flattened constraint coefficient for terminal DOF $dof"))
        if abs(coeff) <= atol
            zero_terminal_contributions_pruned[] += 1
            return
        end

        if haskey(row, dof)
            combined_terminal_contributions[] += 1
            combined = row[dof] + coeff
            if abs(combined) <= atol
                delete!(row, dof)
                cancelled_terminal_dofs_pruned[] += 1
            else
                row[dof] = combined
            end
        else
            row[dof] = coeff
        end
        return
    end

    function expand_dependency!(dep_dof::Int)
        state = get(states, dep_dof, UInt8(0))
        state == UInt8(2) && return flat_map[dep_dof]
        if state == UInt8(1)
            cycle_start = findfirst(==(dep_dof), stack)
            cycle = cycle_start === nothing ? vcat(copy(stack), dep_dof) :
                    vcat(stack[cycle_start:end], dep_dof)
            throw(ArgumentError(
                "MPC/RBE dependency cycle detected: " * join(cycle, " -> ")))
        end

        states[dep_dof] = UInt8(1)
        push!(stack, dep_dof)

        original_pairs = Tuple{Int,Float64}[]
        for pair in dependency_map[dep_dof]
            input_terms[] += 1
            ind_dof = Int(pair[1])
            coeff = Float64(pair[2])
            isfinite(coeff) || throw(ArgumentError(
                "Non-finite constraint coefficient on dependency $dep_dof -> $ind_dof"))
            push!(original_pairs, (ind_dof, coeff))
        end

        # Preserve the historical row exactly when no flattening work is
        # required. K/Kg redistribution consumes these vectors in insertion
        # order, and needlessly sorting an already-flat constraint changes the
        # sparse triplet accumulation order (and therefore CSC/cache details).
        # Nested rows still proceed through DFS, so self/cross dependency
        # cycles remain covered by the visiting-state check above.
        flat_terminal_only = all(
            !haskey(dependency_map, ind_dof) for (ind_dof, _) in original_pairs)
        if flat_terminal_only
            terminal_contributions[] += length(original_pairs)
            flat_map[dep_dof] = original_pairs
            depths[dep_dof] = isempty(original_pairs) ? 0 : 1
            pop!(stack)
            states[dep_dof] = UInt8(2)
            return original_pairs
        end

        canonical_row = Dict{Int,Float64}()
        for (ind_dof, coeff) in sort(copy(original_pairs); by=p -> (p[1], p[2]))
            if abs(coeff) <= atol
                zero_input_terms_pruned[] += 1
                continue
            end
            if haskey(canonical_row, ind_dof)
                combined_input_terms[] += 1
                combined = canonical_row[ind_dof] + coeff
                if abs(combined) <= atol
                    delete!(canonical_row, ind_dof)
                    cancelled_input_dofs_pruned[] += 1
                else
                    canonical_row[ind_dof] = combined
                end
            else
                canonical_row[ind_dof] = coeff
            end
        end
        sorted_pairs = sort!(
            Tuple{Int,Float64}[(dof, coeff) for (dof, coeff) in canonical_row];
            by=first,
        )

        row = Dict{Int,Float64}()
        row_depth = 0
        for (ind_dof, coeff) in sorted_pairs
            if haskey(dependency_map, ind_dof)
                nested_dependency_terms[] += 1
                child_pairs = expand_dependency!(ind_dof)
                row_depth = max(row_depth, 1 + depths[ind_dof])
                for (terminal_dof, child_coeff) in child_pairs
                    accumulate_terminal!(row, terminal_dof, coeff * child_coeff)
                end
            else
                row_depth = max(row_depth, 1)
                accumulate_terminal!(row, ind_dof, coeff)
            end
        end

        flattened_pairs = sort!(
            Tuple{Int,Float64}[(dof, coeff) for (dof, coeff) in row];
            by=first,
        )
        flat_map[dep_dof] = flattened_pairs
        depths[dep_dof] = row_depth
        original_pairs == flattened_pairs || (changed_dependent_dofs[] += 1)

        pop!(stack)
        states[dep_dof] = UInt8(2)
        return flattened_pairs
    end

    for dep_dof in sort!(Int[Int(dof) for dof in keys(dependency_map)])
        expand_dependency!(dep_dof)
    end

    diagnostics = Dict{String,Any}(
        "dependent_dofs" => length(flat_map),
        "input_terms" => input_terms[],
        "output_terms" => sum(length, values(flat_map); init=0),
        "nested_dependency_terms" => nested_dependency_terms[],
        "combined_input_terms" => combined_input_terms[],
        "terminal_contributions" => terminal_contributions[],
        "combined_terminal_contributions" => combined_terminal_contributions[],
        "zero_input_terms_pruned" => zero_input_terms_pruned[],
        "cancelled_input_dofs_pruned" => cancelled_input_dofs_pruned[],
        "zero_terminal_contributions_pruned" => zero_terminal_contributions_pruned[],
        "cancelled_terminal_dofs_pruned" => cancelled_terminal_dofs_pruned[],
        "changed_dependent_dofs" => changed_dependent_dofs[],
        "max_dependency_depth" => maximum(values(depths); init=0),
        "coefficient_tolerance" => atol,
    )
    return flat_map, diagnostics
end

function _rbe3_um_dependent_dofs(um_pairs, id_map)
    dep_dofs = Int[]
    seen = Set{Int}()
    for pair in um_pairs
        grid = Int(pair isa AbstractDict ? pair["grid"] : getproperty(pair, :grid))
        comps = Int(pair isa AbstractDict ? pair["comps"] : getproperty(pair, :comps))
        gi = get(id_map, grid, 0)
        gi == 0 && continue
        for dof in _component_digits(comps)
            1 <= dof <= 6 || continue
            gdof = (gi - 1) * 6 + dof
            if !(gdof in seen)
                push!(dep_dofs, gdof)
                push!(seen, gdof)
            end
        end
    end
    return dep_dofs
end

@inline function _rbe3_basic_frame_diagnostic_enabled()
    return solver_env_bool("JFEM_RBE3_BASIC_FRAME_DIAGNOSTIC", false)
end

@inline function _rbe3_offset_sign_diagnostic()
    raw = solver_env_float("JFEM_RBE3_OFFSET_SIGN_DIAGNOSTIC", 1.0)
    return raw < 0.0 ? -1.0 : 1.0
end

function assemble_constraints(model, id_map, node_coords, node_R, I_idx, J_idx, V_val;
                              prebuilt_map=nothing)
    # Reuse a previously built merged dependency map (the Kg assembly
    # receives K's map as an argument; its contents depend only on
    # connectivity cards + geometry, which cannot change between the K and
    # Kg builds of one solve). Skips the full RBE2/RBE1/RSPLINE/RBE3/MPC
    # map rebuild — including the per-RBE3 pseudo-inverse solves — and
    # produces bit-identical triplets (redistribution reads per-key vectors,
    # not map iteration order). An EMPTY prebuilt map is deliberately NOT
    # trusted: several call sites pass a default empty Dict.
    if prebuilt_map !== nothing && !isempty(prebuilt_map)
        return _redistribute_constraint_triplets(prebuilt_map, I_idx, J_idx, V_val)
    end
    rbe2s = get(model, "RBE2s", Dict())

    # --- RBE2 (rigid body element - MPC constraint via DOF elimination) ---
    rbe2_map = Dict{Int, Vector{Tuple{Int, Float64}}}()
    n_rbe2 = 0
    n_rbe2_dep = 0
    for (id, rbe) in rbe2s
        gn = rbe["GN"]   # master node
        if !haskey(id_map, gn); continue; end
        i_master = id_map[gn]
        cm_digits = [parse(Int, string(ch)) for ch in string(rbe["CM"]) if isdigit(ch)]
        p_m = SVector{3}(node_coords[i_master,1], node_coords[i_master,2], node_coords[i_master,3])
        R_master = node_R[i_master]

        for gs in rbe["GM"]  # slave nodes
            if !haskey(id_map, gs); continue; end
            i_slave = id_map[gs]
            p_s = SVector{3}(node_coords[i_slave,1], node_coords[i_slave,2], node_coords[i_slave,3])
            dx, dy, dz = p_s[1]-p_m[1], p_s[2]-p_m[2], p_s[3]-p_m[3]
            R_slave = node_R[i_slave]

            for c in cm_digits
                slave_dof = (i_slave-1)*6 + c
                pairs = Tuple{Int,Float64}[]
                coeff_row = _rigid_component_row(R_slave, R_master, dx, dy, dz, c)
                _push_rigid_pairs!(pairs, (i_master-1)*6, coeff_row)
                if !isempty(pairs)
                    rbe2_map[slave_dof] = pairs
                    n_rbe2_dep += 1
                end
            end
            n_rbe2 += 1
        end
    end
    if n_rbe2 > 0
        log_msg("[SOLVER] RBE2: $(length(rbe2s)) elements, $n_rbe2 master-slave pairs, $n_rbe2_dep dependent DOFs (MPC elimination)")
    end

    # --- RBE1 (general rigid element - distributed independent DOFs) ---
    rbe1s = get(model, "RBE1s", Dict())
    rbe1_map = Dict{Int, Vector{Tuple{Int, Float64}}}()
    n_rbe1 = 0
    global_R = Matrix(1.0I, 3, 3)
    for (id, rbe1) in rbe1s
        indep = rbe1["INDEP"]   # [(grid, dof_digit), ...]
        dep = rbe1["DEP"]       # [(grid, dof_digit), ...]
        n_indep = length(indep)
        if n_indep < 1 || n_indep > 6; continue; end

        # Collect independent DOFs and build rigid body transformation matrix A
        # A × q = u_indep, where q = [ux_ref, uy_ref, uz_ref, wx, wy, wz] in global axes.
        # Use centroid of independent grids as reference point
        indep_grids_unique = unique([g for (g,d) in indep])
        x_ref = zeros(3)
        n_valid = 0
        for g in indep_grids_unique
            if !haskey(id_map, g); continue; end
            gi = id_map[g]
            x_ref .+= [node_coords[gi,1], node_coords[gi,2], node_coords[gi,3]]
            n_valid += 1
        end
        if n_valid == 0; continue; end
        x_ref ./= n_valid

        # Build A matrix (n_indep × 6) and collect global DOF indices
        A_mat = zeros(n_indep, 6)
        indep_global = Int[]
        valid = true
        for (k, (g, dof)) in enumerate(indep)
            if !haskey(id_map, g); valid = false; break; end
            gi = id_map[g]
            dx = node_coords[gi,1] - x_ref[1]
            dy = node_coords[gi,2] - x_ref[2]
            dz = node_coords[gi,3] - x_ref[3]
            push!(indep_global, (gi-1)*6 + dof)
            A_mat[k,:] = _rigid_component_row(node_R[gi], global_R, dx, dy, dz, dof)
        end
        if !valid; continue; end

        # q = A_inv × u_indep (use pseudoinverse for robustness)
        A_inv = pinv(A_mat, rtol=1e-10)  # 6 × n_indep

        # For each dependent DOF: u_dep = b' × q = b' × A_inv × u_indep
        for (g, dof) in dep
            if !haskey(id_map, g); continue; end
            gi = id_map[g]
            dx = node_coords[gi,1] - x_ref[1]
            dy = node_coords[gi,2] - x_ref[2]
            dz = node_coords[gi,3] - x_ref[3]
            gdof = (gi-1)*6 + dof
            b = _rigid_component_row(node_R[gi], global_R, dx, dy, dz, dof)
            c_vec = A_inv' * b  # n_indep coefficients
            pairs = Tuple{Int,Float64}[]
            for (j, coeff) in enumerate(c_vec)
                if abs(coeff) > 1e-15
                    push!(pairs, (indep_global[j], coeff))
                end
            end
            if !isempty(pairs)
                rbe1_map[gdof] = pairs
            end
        end
        n_rbe1 += 1
    end
    if n_rbe1 > 0
        log_msg("[SOLVER] RBE1: $n_rbe1 elements, $(length(rbe1_map)) dependent DOFs")
    end

    # --- RSPLINE (spline interpolation constraint via linear interpolation) ---
    rsplines = get(model, "RSPLINEs", Dict())
    rspline_map = Dict{Int, Vector{Tuple{Int, Float64}}}()
    n_rspline = 0
    for (id, rsp) in rsplines
        indep_grids = rsp["INDEP_GRIDS"]
        dep_list = rsp["DEP"]  # [(grid, dof_digit), ...]

        # Get coordinates of independent grids (spline control points)
        indep_coords = Tuple{Int,Float64,Float64,Float64}[]
        for g in indep_grids
            if !haskey(id_map, g); continue; end
            gi = id_map[g]
            push!(indep_coords, (gi, node_coords[gi,1], node_coords[gi,2], node_coords[gi,3]))
        end
        if length(indep_coords) < 2; continue; end

        # Compute cumulative arc length along the spline control points
        arc_len = Float64[0.0]
        for i in 2:length(indep_coords)
            dx = indep_coords[i][2] - indep_coords[i-1][2]
            dy = indep_coords[i][3] - indep_coords[i-1][3]
            dz = indep_coords[i][4] - indep_coords[i-1][4]
            push!(arc_len, arc_len[end] + sqrt(dx^2 + dy^2 + dz^2))
        end
        total_len = arc_len[end]
        if total_len < 1e-30; continue; end

        for (g, dof) in dep_list
            if !haskey(id_map, g); continue; end
            gi = id_map[g]
            px = node_coords[gi,1]; py = node_coords[gi,2]; pz = node_coords[gi,3]

            # Project dependent point onto spline: find closest segment
            best_seg = 1; best_t = 0.0; best_dist = Inf
            for seg in 1:(length(indep_coords)-1)
                ax = indep_coords[seg][2]; ay = indep_coords[seg][3]; az = indep_coords[seg][4]
                bx = indep_coords[seg+1][2]; by = indep_coords[seg+1][3]; bz = indep_coords[seg+1][4]
                dx = bx-ax; dy = by-ay; dz = bz-az
                seg_len2 = dx^2 + dy^2 + dz^2
                if seg_len2 < 1e-30; continue; end
                t = clamp(((px-ax)*dx + (py-ay)*dy + (pz-az)*dz) / seg_len2, 0.0, 1.0)
                cx = ax + t*dx; cy = ay + t*dy; cz = az + t*dz
                dist = sqrt((px-cx)^2 + (py-cy)^2 + (pz-cz)^2)
                if dist < best_dist
                    best_dist = dist; best_seg = seg; best_t = t
                end
            end

            # Linear interpolation between the two bounding independent nodes
            gi_left = indep_coords[best_seg][1]
            gi_right = indep_coords[best_seg+1][1]
            gdof = (gi-1)*6 + dof
            left_dof = (gi_left-1)*6 + dof
            right_dof = (gi_right-1)*6 + dof
            w_left = 1.0 - best_t
            w_right = best_t
            pairs = Tuple{Int,Float64}[]
            if abs(w_left) > 1e-15; push!(pairs, (left_dof, w_left)); end
            if abs(w_right) > 1e-15; push!(pairs, (right_dof, w_right)); end
            if !isempty(pairs)
                rspline_map[gdof] = pairs
            end
        end
        n_rspline += 1
    end
    if n_rspline > 0
        log_msg("[SOLVER] RSPLINE: $n_rspline elements, $(length(rspline_map)) dependent DOFs")
    end

    # --- RBE3 (weighted interpolation constraint via DOF elimination) ---
    # Uses full 6-DOF rigid body formulation: fit all 6 RB modes at reference,
    # then extract only the REFC components. This properly handles offset reference nodes.
    rbe3s = get(model, "RBE3s", Dict())
    rbe3_map = Dict{Int, Vector{Tuple{Int, Float64}}}()
    n_rbe3 = 0
    n_rbe3_um = 0
    rbe3_basic_frame_diagnostic = _rbe3_basic_frame_diagnostic_enabled()
    rbe3_offset_sign = _rbe3_offset_sign_diagnostic()
    if rbe3_basic_frame_diagnostic
        log_msg("[SOLVER] RBE3 diagnostic: interpreting RBE3 interpolation components in the basic frame")
    end
    if rbe3_offset_sign < 0.0
        log_msg("[SOLVER] RBE3 diagnostic: reversing reference-to-independent offset sign")
    end
    for (id, rbe) in rbe3s
        ref_gid = rbe["REFGRID"]
        ref_idx = get(id_map, ref_gid, 0)
        if ref_idx == 0; continue; end

        refc_digits = _component_digits(rbe["REFC"])
        if isempty(refc_digits); continue; end

        p_ref = SVector{3}(node_coords[ref_idx,1], node_coords[ref_idx,2], node_coords[ref_idx,3])
        R_ref = rbe3_basic_frame_diagnostic ? Matrix(1.0I, 3, 3) : node_R[ref_idx]

        # Build weighted Gram matrix G'WG (6×6) and per-grid G_i matrices
        # G_i maps independent DOFs at node i to full 6 RB DOFs at reference
        A6 = zeros(6, 6)
        grid_Gi = Tuple{Int, Matrix{Float64}, Float64, Vector{Int}}[]

        wt_groups = get(rbe, "WT_GROUPS", [])
        for group in wt_groups
            # Support both NamedTuple (.wt) and Dict (["wt"]) access for JSON compatibility
            wt = Float64(group isa AbstractDict ? group["wt"] : group.wt)
            comps_raw = group isa AbstractDict ? group["comps"] : group.comps
            comps_digits = _component_digits(comps_raw)
            if isempty(comps_digits); continue; end
            grids_raw = group isa AbstractDict ? group["grids"] : group.grids
            for dg in grids_raw
                di = get(id_map, dg, 0)
                if di == 0; continue; end
                p_i = SVector{3}(node_coords[di,1], node_coords[di,2], node_coords[di,3])
                dx = rbe3_offset_sign * (p_i[1] - p_ref[1])
                dy = rbe3_offset_sign * (p_i[2] - p_ref[2])
                dz = rbe3_offset_sign * (p_i[3] - p_ref[3])
                R_i = rbe3_basic_frame_diagnostic ? Matrix(1.0I, 3, 3) : node_R[di]

                n_comp = length(comps_digits)
                G_i = zeros(n_comp, 6)  # maps comp DOFs → 6 RB DOFs at ref
                for (jj, cdof) in enumerate(comps_digits)
                    G_i[jj, :] = _rigid_component_row(R_i, R_ref, dx, dy, dz, cdof)
                end

                A6 .+= wt .* (G_i' * G_i)
                push!(grid_Gi, (di, G_i, wt, comps_digits))
            end
        end
        if isempty(grid_Gi); continue; end

        A6_inv = pinv(A6, rtol=1e-10)

        equation_rows = Dict{Int,Float64}[]
        row_by_ref_dof = Dict{Int,Int}()
        for (di, G_i, wt, comps_digits) in grid_Gi
            C_i = A6_inv * (wt .* G_i')
            for rdof in refc_digits
                1 <= rdof <= 6 || continue
                ref_dof = (ref_idx - 1) * 6 + rdof
                row_index = get(row_by_ref_dof, ref_dof, 0)
                if row_index == 0
                    row = Dict{Int,Float64}()
                    _add_row_coeff!(row, ref_dof, 1.0)
                    push!(equation_rows, row)
                    row_index = length(equation_rows)
                    row_by_ref_dof[ref_dof] = row_index
                end
                row = equation_rows[row_index]
                for (jj, cdof) in enumerate(comps_digits)
                    coeff = C_i[rdof, jj]
                    if abs(coeff) > 1e-15
                        ind_dof = (di - 1) * 6 + cdof
                        _add_row_coeff!(row, ind_dof, -coeff)
                    end
                end
            end
        end
        if isempty(equation_rows); continue; end

        default_dep_dofs = Int[]
        for rdof in refc_digits
            1 <= rdof <= 6 || continue
            push!(default_dep_dofs, (ref_idx - 1) * 6 + rdof)
        end

        um_dep_dofs = _rbe3_um_dependent_dofs(get(rbe, "UM", []), id_map)
        dep_dofs = default_dep_dofs
        if !isempty(um_dep_dofs) && solver_env_bool("JFEM_RBE3_USE_UM_DEPENDENT", false)
            if length(um_dep_dofs) == length(equation_rows)
                dep_dofs = um_dep_dofs
                n_rbe3_um += 1
            else
                log_msg("[SOLVER] RBE3 $(rbe["ID"]): ignored UM dependent set because it has $(length(um_dep_dofs)) DOFs for $(length(equation_rows)) equations")
            end
        end

        all_dof_set = Set{Int}()
        for row in equation_rows
            for dof in keys(row)
                push!(all_dof_set, dof)
            end
        end
        dep_set = Set(dep_dofs)
        ind_dofs = sort!(collect(setdiff(all_dof_set, dep_set)))

        A_dep = zeros(length(equation_rows), length(dep_dofs))
        B_ind = zeros(length(equation_rows), length(ind_dofs))
        for (ri, row) in enumerate(equation_rows)
            for (ci, dof) in enumerate(dep_dofs)
                A_dep[ri, ci] = get(row, dof, 0.0)
            end
            for (ci, dof) in enumerate(ind_dofs)
                B_ind[ri, ci] = get(row, dof, 0.0)
            end
        end

        C_dep = try
            -(A_dep \ B_ind)
        catch
            -(pinv(A_dep, rtol=1e-10) * B_ind)
        end
        for (dep_col, dep_dof) in enumerate(dep_dofs)
            pairs = Tuple{Int,Float64}[]
            for (ind_col, ind_dof) in enumerate(ind_dofs)
                coeff = C_dep[dep_col, ind_col]
                if abs(coeff) > 1e-15
                    push!(pairs, (ind_dof, coeff))
                end
            end
            if !isempty(pairs)
                rbe3_map[dep_dof] = pairs
            end
        end
        n_rbe3 += 1
    end

    # --- Explicit MPC constraints ---
    mpc_cards = get(model, "MPCs", [])
    mpc_map = Dict{Int, Vector{Tuple{Int, Float64}}}()
    n_mpc_explicit = 0
    for mpc in mpc_cards
        terms = mpc["TERMS"]
        if length(terms) < 2; continue; end
        dep_g = terms[1]["G"]; dep_c = terms[1]["C"]; dep_a = terms[1]["A"]
        if !haskey(id_map, dep_g) || dep_c < 1 || dep_c > 6; continue; end
        if abs(dep_a) < 1e-30; continue; end
        dep_dof = (id_map[dep_g]-1)*6 + dep_c
        pairs = Tuple{Int,Float64}[]
        for i in 2:length(terms)
            t = terms[i]
            if !haskey(id_map, t["G"]) || t["C"] < 1 || t["C"] > 6; continue; end
            ind_dof = (id_map[t["G"]]-1)*6 + t["C"]
            coeff = -t["A"] / dep_a
            push!(pairs, (ind_dof, coeff))
        end
        if !isempty(pairs)
            mpc_map[dep_dof] = pairs
            n_mpc_explicit += 1
        end
    end
    if n_mpc_explicit > 0
        log_msg("[SOLVER] MPC: $n_mpc_explicit explicit MPC constraints")
    end

    # Merge all constraint maps: RBE2, RBE1, RSPLINE, RBE3, MPC
    merge!(rbe3_map, rbe2_map, rbe1_map, rspline_map, mpc_map)
    n_mpc_total = length(rbe3_map)
    n_rbe3_only = length(rbe3_map) - length(rbe2_map) - length(rbe1_map) - length(rspline_map) - length(mpc_map)

    if n_rbe3 > 0
        log_msg("[SOLVER] RBE3: $n_rbe3 elements, $n_rbe3_only dependent DOFs")
        if n_rbe3_um > 0
            log_msg("[SOLVER] RBE3: $n_rbe3_um elements used UM dependent DOFs")
        end
    end

    if n_mpc_total > 0
        log_msg("[SOLVER] MPC elimination: $n_mpc_total total dependent DOFs (RBE2: $(length(rbe2_map)), RBE1: $(length(rbe1_map)), RSPLINE: $(length(rspline_map)), RBE3: $n_rbe3_only, MPC: $(length(mpc_map)))")
    end

    return _redistribute_constraint_triplets(rbe3_map, I_idx, J_idx, V_val)
end

# Redistribute triplets involving dependent DOFs onto their terminal
# independent DOFs. Split from the map build so a prebuilt map can skip the
# build. Flattening here makes every caller (K, Kg, and M) use the same complete
# congruence map and makes all one-pass dependent-DOF recovery paths valid.
function _redistribute_constraint_triplets(rbe3_map, I_idx, J_idx, V_val;
                                           skip_zeros::Bool=false)
    isempty(rbe3_map) && return rbe3_map, I_idx, J_idx, V_val
    rbe3_map, flatten_diagnostics = _flatten_constraint_dependency_map(rbe3_map)
    if flatten_diagnostics["changed_dependent_dofs"] > 0
        log_msg("[SOLVER] MPC dependency map flattened: $(flatten_diagnostics["dependent_dofs"]) dependent DOFs, $(flatten_diagnostics["nested_dependency_terms"]) nested terms, depth=$(flatten_diagnostics["max_dependency_depth"]), terms $(flatten_diagnostics["input_terms"]) -> $(flatten_diagnostics["output_terms"])")
    end
    n_orig = length(I_idx)
    expected_triplets = skip_zeros ? 0 : n_orig + n_orig ÷ 10
    zero_input_triplets = 0
    if skip_zeros
        for k in 1:n_orig
            if iszero(V_val[k])
                zero_input_triplets += 1
                continue
            end
            i = I_idx[k]
            j = J_idx[k]
            n_i = haskey(rbe3_map, i) ? length(rbe3_map[i]) : 1
            n_j = haskey(rbe3_map, j) ? length(rbe3_map[j]) : 1
            expected_triplets = Base.checked_add(
                expected_triplets, Base.checked_mul(n_i, n_j))
        end
    end

    new_I = Int[]; new_J = Int[]; new_V = Float64[]
    sizehint!(new_I, expected_triplets)
    sizehint!(new_J, expected_triplets)
    sizehint!(new_V, expected_triplets)

    for k in 1:n_orig
        i = I_idx[k]; j = J_idx[k]; v = V_val[k]
        skip_zeros && iszero(v) && continue
        i_dep = haskey(rbe3_map, i)
        j_dep = haskey(rbe3_map, j)

        if !i_dep && !j_dep
            if skip_zeros
                _push_nonzero_triplet!(new_I, new_J, new_V, i, j, v)
            else
                push!(new_I, i); push!(new_J, j); push!(new_V, v)
            end
        elseif i_dep && !j_dep
            for (ind_dof, coeff) in rbe3_map[i]
                value = v * coeff
                if skip_zeros
                    _push_nonzero_triplet!(new_I, new_J, new_V, ind_dof, j, value)
                else
                    push!(new_I, ind_dof); push!(new_J, j); push!(new_V, value)
                end
            end
        elseif !i_dep && j_dep
            for (ind_dof, coeff) in rbe3_map[j]
                value = v * coeff
                if skip_zeros
                    _push_nonzero_triplet!(new_I, new_J, new_V, i, ind_dof, value)
                else
                    push!(new_I, i); push!(new_J, ind_dof); push!(new_V, value)
                end
            end
        else
            for (ind_i, ci) in rbe3_map[i]
                for (ind_j, cj) in rbe3_map[j]
                    value = v * ci * cj
                    if skip_zeros
                        _push_nonzero_triplet!(new_I, new_J, new_V,
                                               ind_i, ind_j, value)
                    else
                        push!(new_I, ind_i); push!(new_J, ind_j); push!(new_V, value)
                    end
                end
            end
        end
    end
    if skip_zeros
        log_msg("[SOLVER] MPC: Triplets redistributed: $n_orig → $(length(new_I)) (exact-zero inputs skipped: $zero_input_triplets)")
    else
        log_msg("[SOLVER] MPC: Triplets redistributed: $n_orig → $(length(new_I))")
    end
    return rbe3_map, new_I, new_J, new_V
end

"""
    _apply_constraint_congruence(matrix, constraint_map; expected_ndof=nothing)

Apply the same flattened `T' * matrix * T` congruence used by native stiffness
and mass assembly to an already assembled custom matrix. The custom matrix is
interpreted in the full GRID coordinate space and returned as a sparse matrix
in the MPC-reduced coordinate space. Callers must invoke this exactly once.
"""
function _apply_constraint_congruence(matrix::AbstractMatrix, constraint_map;
                                      expected_ndof=nothing)
    nrow, ncol = size(matrix)
    nrow == ncol || throw(DimensionMismatch(
        "Constraint congruence requires a square matrix; got $(nrow)x$(ncol)"))
    if expected_ndof !== nothing && nrow != Int(expected_ndof)
        throw(DimensionMismatch(
            "Constraint congruence expected $(Int(expected_ndof)) DOFs; matrix has $nrow"))
    end
    (constraint_map === nothing || isempty(constraint_map)) && return matrix

    matrix_sparse = sparse(matrix)
    I_idx, J_idx, V_val = findnz(matrix_sparse)
    _, I_idx, J_idx, V_val = _redistribute_constraint_triplets(
        constraint_map, I_idx, J_idx, V_val; skip_zeros=true)
    return sparse(I_idx, J_idx, V_val, nrow, ncol)
end
