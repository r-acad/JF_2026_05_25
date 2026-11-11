(function (root, factory) {
  const api = factory(root);
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WingFEEdit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function (root) {
  'use strict';

  function finite(value, label) {
    if (value === '' || value == null) throw Error('Enter ' + label + '.');
    const number = Number(value);
    if (!Number.isFinite(number)) throw Error(label + ' must be a finite number.');
    return number;
  }
  function vector(values, label) {
    if (!Array.isArray(values) || values.length !== 3) throw Error(label + ' needs X, Y and Z.');
    return values.map((value, index) => finite(value, label + ' ' + 'XYZ'[index]));
  }
  function unitVector(values, label) {
    const result = vector(values, label), length = Math.hypot(...result);
    if (!(length > 0) || !Number.isFinite(length)) throw Error(label + ' must have a finite, non-zero length.');
    return result.map(value => value / length);
  }
  function plane(values) {
    const point = vector(values.point, 'Plane point'), normal = unitVector(values.normal, 'Plane normal');
    const side_length = finite(values.side_length, 'Plane side length');
    const tolerance = finite(values.tolerance, 'Cut tolerance');
    if (!(side_length > 0)) throw Error('Plane side length must be greater than zero.');
    if (!(tolerance > 0)) throw Error('Cut tolerance must be greater than zero.');
    return {point, normal, side_length, tolerance};
  }
  function selection(kind, first, depth) {
    if (!['positive', 'negative', 'slab'].includes(kind)) throw Error('Choose a side or a slice between two planes.');
    const result = {kind, plane: plane(first)};
    if (kind === 'slab') {
      const distance = finite(depth, 'Slice thickness');
      if (!(distance > 0)) throw Error('Slice thickness must be greater than zero.');
      result.second_plane = {...result.plane, point: result.plane.point.map((value, index) => value + distance * result.plane.normal[index])};
    }
    return result;
  }
  function translation(values, mode, distance) {
    const result = mode === 'direction' ? unitVector(values, 'Movement direction').map(value => value * finite(distance, 'Movement distance')) : vector(values, 'Movement');
    if (!(Math.hypot(...result) > 0)) throw Error('The movement must have a non-zero distance.');
    return result.map(value => value === 0 ? 0 : value);
  }
  function candidateGroups(raw) {
    if (!Array.isArray(raw)) return [];
    return raw.map((group, index) => {
      const nodes = [...new Set(Array.isArray(group) ? group : group.nodes || [])];
      if (nodes.length < 2 || nodes.some(id => !Number.isSafeInteger(id) || id < 1)) throw Error('Invalid coincident-node group ' + (index + 1) + ' returned by the model editor.');
      const result = {nodes, retained_node: group.retained_node ?? Math.min(...nodes), max_distance: Number(group.max_distance || 0)};
      for (const key of ['affected_nodes','anchor_nodes']) if (Array.isArray(group[key])) {if (group[key].some(id => !Number.isSafeInteger(id)||id<1||key==='affected_nodes'&&!nodes.includes(id))) throw Error('Invalid operation coincidence membership.'); result[key] = [...new Set(group[key])];}
      return result;
    });
  }
  function pickedNodes(value) {
    const rows = Array.isArray(value) ? value : value?.nodes;
    if (!Array.isArray(rows)) throw Error('The 3D picker did not return GRID coordinates.');
    return rows.map(row => {
      if (!Number.isSafeInteger(row?.id) || row.id < 1) throw Error('The 3D picker returned an invalid GRID ID.');
      return {id: row.id, xyz: vector(row.xyz, 'GRID ' + row.id + ' coordinate')};
    });
  }
  function pickedVector(value) {
    const nodes = pickedNodes(value);
    if (nodes.length !== 2) throw Error('Pick a start GRID and an end GRID for the translation vector.');
    const delta = nodes[1].xyz.map((value, index) => value - nodes[0].xyz[index]);
    if (delta.some(value => !Number.isFinite(value))) throw Error('The picked GRID separation exceeds the finite coordinate range.');
    if (!(Math.hypot(...delta) > 0)) throw Error('The selected GRID points are coincident. Choose two points with a non-zero separation.');
    return {nodes, delta: delta.map(value => value === 0 ? 0 : value)};
  }
  function pickedPart(value) {
    const ids = value?.element_ids || value?.part?.element_ids;
    if (!Array.isArray(ids) || !ids.length || ids.some(id => !Number.isSafeInteger(id) || id < 1)) throw Error('The 3D picker did not return valid element IDs for this part.');
    return {element_ids: [...new Set(ids)], part: {...value.part}, requires_cut: !!(value.requires_cut || value.part?.requires_cut)};
  }
  const numberText = value => {
    const number = Number(value);
    if (!Number.isFinite(number)) return '—';
    return number !== 0 && (Math.abs(number) < .001 || Math.abs(number) >= 1e7) ? number.toExponential(3).replace(/\.0+(?=e)/, '') : number.toLocaleString(undefined, {maximumSignificantDigits: 5});
  };

  function install(host, {readContext = () => ({}), request, onPreview = () => {}, onCommit = () => {}, onExport, onPickNodes, onPickPart} = {}) {
    if (!host || !host.ownerDocument) throw Error('Provide a host element for the model editing tools.');
    if (typeof request !== 'function') throw Error('Provide the FE model editing request function.');
    const doc = host.ownerDocument;
    const element = doc.createElement('section'); element.className = 'fe-edit';
    element.innerHTML = `
      <div class="fe-edit-intro"><h3>Cut, move and join an FE model</h3><p>Edit a working copy of the current FEM. For a fuselage extension: cut at two stations, move the aft part, repeat the slice, then review and join coincident nodes.</p></div>
      <div class="fe-edit-source" data-role="source"></div>
      <div class="fe-edit-toolbar"><button type="button" data-action="initialize" class="primary" title="Create an editable copy of the displayed imported or generated finite-element model. The original file is retained.">Start editable copy</button><button type="button" data-action="undo" title="Undo the last successful model operation.">Undo</button><button type="button" data-action="reset" title="Restore the original model used to start this working copy.">Reset to original</button></div>
      <p class="fe-edit-summary" data-role="summary" aria-live="polite">Create or read an FE model, then start an editable copy.</p>
      <div class="fe-edit-stale" data-role="stale" hidden>Edited geometry: existing solver results belong to the previous model. Save the edited model and run the analysis again before using its results.</div>
      <div class="fe-edit-message" data-role="message" role="status" hidden><span data-role="message-text"></span><button type="button" data-action="dismiss" aria-label="Dismiss model editing message" title="Close this message">×</button></div>
      <div class="fe-edit-pick-status" data-role="node-pick" role="status" hidden><span data-role="node-pick-text"></span><button type="button" data-action="cancel-pick" title="Cancel 3D picking. Incomplete picks do not change the existing point, translation vector or selected part.">Cancel pick · Esc</button></div>
      <fieldset class="fe-edit-section" data-role="plane-fields"><legend>1 · Define the cutting plane</legend>
        <p class="fe-edit-help">Coordinates and distances use <strong data-role="units">model length units</strong>. The plane normal points toward the positive side. The square must cover the cross-section to cut.</p>
        <div class="fe-edit-vector"><span>Point on plane</span><label>X<input data-field="point_x" type="number" step="any" value="0" title="X coordinate of any point on the cutting plane, in model length units."></label><label>Y<input data-field="point_y" type="number" step="any" value="0" title="Y coordinate of the cutting-plane point, in model length units."></label><label>Z<input data-field="point_z" type="number" step="any" value="0" title="Z coordinate of the cutting-plane point, in model length units."></label></div>
        <button type="button" data-action="pick-plane-point" title="Click a GRID in the 3D view to use its stored model X, Y and Z coordinates as the plane point. The plane normal stays unchanged.">Pick plane point in 3D</button><p class="fe-edit-picked" data-role="plane-picked" hidden></p>
        <label class="fe-edit-inline">Normal direction<select data-field="normal_axis" title="Choose a plane perpendicular to a global axis, or enter a custom normal vector."><option value="x">Global X · transverse cut</option><option value="y">Global Y</option><option value="z">Global Z</option><option value="custom">Custom direction</option></select></label>
        <div class="fe-edit-vector"><span>Normal vector</span><label>X<input data-field="normal_x" type="number" step="any" value="1" title="X component of the plane normal. The vector is normalized automatically."></label><label>Y<input data-field="normal_y" type="number" step="any" value="0" title="Y component of the plane normal. Its magnitude does not change the cut location."></label><label>Z<input data-field="normal_z" type="number" step="any" value="0" title="Z component of the plane normal. All three components cannot be zero."></label></div>
        <div class="fe-edit-pair"><label>Square side length<input data-field="side_length" type="number" step="any" min="0" value="10" title="Side length of the square cutting tool in model length units. It must cover the model cross-section; increase it if the preview shows uncovered elements."></label><label>Cut tolerance<input data-field="tolerance" type="number" step="any" min="0" value="1e-7" title="Distance from the plane at which a node is treated as lying on it, in model length units. Use a value small relative to the shortest intended mesh edge."></label></div>
        <div class="fe-edit-toolbar"><button type="button" data-action="preview" title="Show the plane and inspect the affected elements without modifying the working model.">Preview plane &amp; selection</button><button type="button" data-action="hide-preview" title="Hide the cutting-plane overlay and temporary selection highlights.">Hide preview</button></div>
        <label class="fe-edit-check"><input data-field="duplicate_nodes" type="checkbox" checked title="Create separate nodes for the two sides of the cut so they can be moved independently. Leave unchecked to keep the cut edges connected until a later separation.">Duplicate nodes at the cut</label>
        <button type="button" data-action="cut" class="primary" title="Split supported intersected elements at this plane. Node duplication separates the two cut faces; the operation can be undone.">Cut at this plane</button>
      </fieldset>
      <fieldset class="fe-edit-section" data-role="transform-fields"><legend>2 · Select and move a part</legend>
        <div class="fe-edit-toolbar"><button type="button" data-action="parts" title="Refresh the physically connected components and color them in the 3D view. Successful cuts show them automatically.">Refresh connected parts</button><button type="button" data-action="pick-part" title="Click an element in the 3D view to select its connected part for movement or copying. This selection takes precedence over the plane-side selector below.">Pick part in 3D</button></div><ul class="fe-edit-parts" data-role="parts-summary" hidden></ul><div class="fe-edit-part-selection" data-role="part-selection" hidden><p data-role="part-selection-text"></p></div><p class="fe-edit-help" data-role="selection-prompt">Pick a connected part in 3D, or deliberately use the plane / slice selection below.</p>
        <label>Part to select<select data-field="selection" title="Select the side of the cutting plane to translate or copy. For a slice, cut at both boundaries before moving or copying it."><option value="positive">Positive side · along the normal</option><option value="negative">Negative side · opposite the normal</option><option value="slab">Slice between two parallel planes</option></select></label>
        <button type="button" data-action="clear-part" title="Use the plane-side or slice selector instead of a picked connected component.">Use plane / slice selection</button>
        <div data-role="slab" hidden><label>Slice thickness<input data-field="depth" type="number" step="any" min="0" value="1" title="Distance from the first plane to the second plane along the positive normal, in model length units."></label><p class="fe-edit-help">The first boundary is the plane above; the second is one slice thickness along its normal. Cut both boundaries before moving or copying the slice.</p><button type="button" data-action="cut-second" title="Cut at the second slice boundary, retaining the plane and slice selection above.">Cut at the second boundary</button></div>
        <div class="fe-edit-pair"><label>Operation<select data-field="transform_action" title="Move changes the selected region in place. Copy creates one translated copy and keeps the original region at its current location."><option value="move">Move selected region</option><option value="copy">Copy selected region</option></select></label><label>Movement input<select data-field="movement_mode" title="Enter an XYZ displacement directly, or a direction vector and a signed distance."><option value="vector">Translation vector · ΔX, ΔY, ΔZ</option><option value="direction">Direction and distance</option></select></label></div>
        <div class="fe-edit-vector"><span data-role="movement-label">Translation vector</span><label>X<input data-field="move_x" type="number" step="any" value="1" title="X displacement in model length units, or X component of the normalized movement direction."></label><label>Y<input data-field="move_y" type="number" step="any" value="0" title="Y displacement in model length units, or Y component of the normalized movement direction."></label><label>Z<input data-field="move_z" type="number" step="any" value="0" title="Z displacement in model length units, or Z component of the normalized movement direction."></label></div>
        <button type="button" data-action="pick-translation-vector" title="Pick a start GRID A, then an end GRID B. The translation is B minus A in the model coordinate system. You can edit ΔX, ΔY and ΔZ afterwards, including setting individual components to zero.">Pick vector from two GRIDs in 3D</button><p class="fe-edit-picked" data-role="vector-picked" hidden></p><p class="fe-edit-help">A picked vector runs from the first GRID to the second. Edit X, Y or Z above to remove a component, for example set Z to 0 for movement in the XY plane.</p>
        <label data-role="distance" hidden>Signed distance<input data-field="distance" type="number" step="any" value="1" title="Distance in model length units along the normalized direction. A negative value reverses the movement."></label>
        <label class="fe-edit-check" data-role="detach-control"><input data-field="detach_shared" type="checkbox" title="Duplicate boundary nodes that are shared with unselected elements before moving. This separates the two parts; it does not stretch connecting elements. Rigid or multi-point connections crossing the boundary still require review.">Detach shared boundary nodes before moving</label>
        <p class="fe-edit-help" data-role="detach-help" hidden>The selected and unselected parts will have separate boundary nodes. Their connection is removed until you explicitly join compatible nodes again.</p>
        <label>New-overlap tolerance<input data-field="node_tolerance" type="number" step="any" min="0" value="1e-6" title="Distance in model length units used after the next move or copy to find newly coincident nodes. Preexisting and unrelated coincidences are excluded from that review."></label>
        <button type="button" data-action="translate" class="primary" title="Apply the selected Move or Copy operation to the picked part or explicitly selected plane region.">Apply move</button>
        <div class="fe-edit-operation-overlaps" data-role="operation-coincidences" hidden><p data-role="operation-coincidences-text"></p><div class="fe-edit-toolbar"><button type="button" data-action="review-operation">Review &amp; equivalence new nodes</button><button type="button" data-action="highlight-operation">Highlight new pairs</button></div></div>
        <details class="fe-edit-repeat-tools" data-role="repeat-tools"><summary>Advanced · repeat copies</summary><div class="fe-edit-repeat"><label>Number of new copies<input data-field="copy_count" type="number" step="1" min="1" max="1000" value="1" title="Number of additional copies, excluding the original. Copy 1 is one translation vector away; copy 2 is two vectors away, and so on."></label><button type="button" data-action="copy" title="Copy the selected elements and their nodes repeatedly at integer multiples of the movement vector. Copies receive new IDs. Coincident boundary nodes are joined only when you explicitly merge them below.">Copy &amp; repeat selected part</button></div></details>
        <p class="fe-edit-help">Copies remain separate until you review and merge their coincident nodes. Check the element orientation, connections, loads and constraints after editing.</p>
      </fieldset>
      <fieldset class="fe-edit-section" data-role="join-fields"><legend>3 · Review and equivalence nodes</legend>
        <p class="fe-edit-help">A move or copy lists only the new coincidences it created. Choose which existing GRID to keep when several anchors coincide. Equivalence joins the selected new nodes to that GRID and updates their connectivity; other existing anchors remain separate.</p>
        <details data-role="global-search"><summary>Advanced · global node search</summary><div class="fe-edit-pair"><label>Global search tolerance<input data-field="global_node_tolerance" type="number" step="any" min="0" value="1e-6" title="Search all model nodes, including preexisting coincidences. This is separate from the operation-only review after a move or copy."></label><button type="button" data-action="candidates" title="Find all coincident-node candidates without modifying the model. This global search may include intentional preexisting coincidences.">Find all candidate nodes</button></div><p class="fe-edit-help">Global search includes preexisting coincidences. Review these separately; it does not restrict candidates to the latest operation.</p></details>
        <div data-role="candidate-results" hidden><div class="fe-edit-toolbar"><label class="fe-edit-check"><input data-field="select_all" type="checkbox" title="Select or deselect all candidate groups, including groups on other pages.">Select all groups</label><span data-role="candidate-count"></span></div><div class="fe-edit-table-wrap"><table><caption data-role="candidate-caption">Coincident-node candidates</caption><thead><tr><th scope="col">Join</th><th scope="col">Node IDs</th><th scope="col">Keep GRID</th><th scope="col">Max. gap</th><th scope="col">Inspect</th></tr></thead><tbody data-role="candidate-rows"></tbody></table></div><div class="fe-edit-toolbar"><button type="button" data-action="previous">Previous</button><span data-role="candidate-page"></span><button type="button" data-action="next">Next</button></div><button type="button" data-action="equivalence" class="primary" title="Equivalence only the selected reviewed groups. The chosen GRID survives and all connectivity is updated; this operation can be undone.">Equivalence selected groups</button></div>
      </fieldset>
      <div class="fe-edit-footer"><button type="button" data-action="export" class="primary" title="Save the complete edited Nastran deck to a file and folder of your choice. Save Study also retains the edited source.">Save edited Nastran model…</button><p class="fe-edit-help">Save Study keeps this edited model with the project. The lifting-surface parameter forms do not regenerate edits made to an FE working copy.</p></div>`;
    host.append(element);
    const field = name => element.querySelector('[data-field="' + name + '"]');
    const role = name => element.querySelector('[data-role="' + name + '"]');
    const button = action => element.querySelector('[data-action="' + action + '"]');
    const state = {session: null, revision: null, source: null, summary: null, modelKey: null, busy: false, changed: false, undoDepth: 0, groups: [], selected: new Set(), anchors: new Map(), candidateScope: null, candidateRevision: null, candidateTolerance: null, operationInfo: null, page: 0, previewVisible: false, planeTouched: false, destroyed: false, picking: null, pickSerial: 0, planePick: null, vectorPick: null, parts: [], explicitPart: null, usePlaneSelection: false};
    const units = () => String(readContext().unitsLabel || 'source model length units');
    const inputVector = prefix => ['x', 'y', 'z'].map(axis => field(prefix + '_' + axis).value);
    const readPlane = () => plane({point: inputVector('point'), normal: inputVector('normal'), side_length: field('side_length').value, tolerance: field('tolerance').value});
    const readSelection = () => selection(field('selection').value, readPlane(), field('depth').value);
    const readMovement = () => translation(inputVector('move'), field('movement_mode').value, field('distance').value);
    const ambiguousNodes = info => Array.isArray(info?.ambiguous_affected_nodes) ? info.ambiguous_affected_nodes.filter(id=>Number.isSafeInteger(id)&&id>0) : [];
    const currentPreview = extra => {
      const selected = readSelection();
      return {plane: selected.plane, second_plane: selected.second_plane || null, selection: selected, show_plane: true, ...(state.parts.length ? {parts: state.parts, show_parts: true} : {}), ...(state.explicitPart ? {selected_element_ids: state.explicitPart.element_ids} : {}), ...(state.candidateScope === 'operation' ? {candidate_groups: state.groups.map((group,index)=>({...group,nodes:[...new Set([...group.nodes,...(group.anchor_nodes||[])])],retained_node:state.anchors.get(index)??group.retained_node})),ambiguous_node_ids:ambiguousNodes(state.operationInfo)} : {}), ...extra};
    };
    function showMessage(text, error = false) {
      role('message-text').textContent = text; role('message').hidden = !text;
      role('message').dataset.error = String(error); role('message').setAttribute('role', error ? 'alert' : 'status');
    }
    function clearCandidates() {
      state.groups = []; state.selected.clear(); state.anchors.clear(); state.candidateScope = null; state.candidateRevision = null; state.candidateTolerance = null; state.operationInfo = null; state.page = 0; role('candidate-results').hidden = true; updateOperationReport();
    }
    function updateOperationReport() {
      const info=state.operationInfo;role('operation-coincidences').hidden=!info;if(!info)return;
      const groups=info.candidate_groups||[],nodes=info.node_count??new Set(groups.flatMap(group=>group.nodes)).size,ambiguous=ambiguousNodes(info),unresolved=Math.max(Number(info.unresolved_affected_count||0),ambiguous.length);
      const message=groups.length?groups.length+' new coincidence group(s) · '+nodes+' nodes · tolerance '+numberText(info.tolerance)+' · revision '+info.revision+'. Only coincidences caused by this '+(info.operation||'operation')+' are included. Review the surviving GRID before equivalence.':unresolved?'No automatically mergeable groups; '+unresolved+' affected node(s) need manual review. No nodes have been merged.':'No new coincident nodes were created by this '+(info.operation||'operation')+' at tolerance '+numberText(info.tolerance)+'. Preexisting and unrelated coincidences are excluded.';
      role('operation-coincidences-text').textContent=message+(groups.length?'\nMarkers: green rim = kept GRID; orange = other candidate nodes.':'')+(groups.length&&unresolved?'\n'+unresolved+' additional affected node(s) need manual review.':'')+(ambiguous.length?'\nMagenta markers: ambiguous affected GRID IDs '+ambiguous.join(', ')+'.':'')+(info.warnings?.length?'\nReview notes:\n'+info.warnings.join('\n'):'');
      const disabled=state.busy||!!state.picking||info.revision!==state.revision;button('review-operation').disabled=disabled||!groups.length;button('highlight-operation').disabled=disabled||(!groups.length&&!ambiguous.length);
    }
    function showOperationCandidates() {
      const info=state.operationInfo;if(!info||info.revision!==state.revision)throw Error('This operation review is stale. Move or copy again to obtain a current list.');
      state.groups=info.candidate_groups;state.selected.clear();state.anchors.clear();state.candidateScope='operation';state.candidateRevision=info.revision;state.candidateTolerance=info.tolerance;state.page=0;renderCandidates();
    }
    button('review-operation').onclick=()=>attempt(()=>{showOperationCandidates();role('join-fields').scrollIntoView?.({block:'start',behavior:'smooth'});});
    button('highlight-operation').onclick=()=>attempt(()=>{showOperationCandidates();state.previewVisible=true;onPreview(currentPreview());});
    function hidePreview() { state.previewVisible = false; onPreview({clear: true}); }
    function clearSession(message) {
      cancelPicking(); state.planePick = null; state.vectorPick = null; updatePickReports(); clearPartSelection();
      state.session = null; state.revision = null; state.source = null; state.summary = null;
      state.changed = false; state.undoDepth = 0; state.modelKey = null; clearCandidates(); hidePreview();
      if (message) showMessage(message);
    }
    function updateCandidateControls() {
      const count = state.selected.size, total = state.groups.length;
      field('select_all').checked = total > 0 && count === total;
      field('select_all').indeterminate = count > 0 && count < total;
      role('candidate-count').textContent = count + ' of ' + total + ' groups selected';
      button('equivalence').textContent = (state.candidateScope === 'operation' ? 'Equivalence ' : 'Merge global ') + count + ' selected group' + (count === 1 ? '' : 's');
      button('equivalence').disabled = state.busy || !!state.picking || !count || state.candidateRevision !== state.revision;
      button('previous').disabled = state.busy || !!state.picking || !state.page;
      button('next').disabled = state.busy || !!state.picking || (state.page + 1) * 50 >= total;
      role('candidate-page').textContent = total ? 'Groups ' + (state.page * 50 + 1) + '–' + Math.min((state.page + 1) * 50, total) + ' of ' + total : 'No candidate groups';
    }
    function renderCandidates() {
      const rows = role('candidate-rows'); rows.replaceChildren();
      const total = state.groups.length; role('candidate-results').hidden = !total;
      role('candidate-caption').textContent = state.candidateScope === 'operation' ? 'New coincidences from the latest ' + (state.operationInfo?.operation || 'move / copy') + ' · revision ' + state.candidateRevision : 'Global coincident-node candidates · includes preexisting nodes';
      state.groups.slice(state.page * 50, state.page * 50 + 50).forEach((group, offset) => {
        const index = state.page * 50 + offset, row = doc.createElement('tr');
        const checkCell = doc.createElement('td'), check = doc.createElement('input'); check.type = 'checkbox';
        check.checked = state.selected.has(index); check.setAttribute('aria-label', 'Select node group ' + (index + 1));
        check.title = 'Select this group for equivalence using the survivor shown in Keep GRID.';
        check.onchange = () => {if (check.checked) state.selected.add(index); else state.selected.delete(index); updateCandidateControls();}; checkCell.append(check);
        const ids = doc.createElement('td'); ids.className = 'fe-edit-node-ids'; ids.textContent = group.nodes.join(', ');
        const kept = doc.createElement('td'),anchors=group.anchor_nodes||[];
        if(state.candidateScope==='operation'&&anchors.length>1){const select=doc.createElement('select');select.title='Choose the existing GRID to keep. Other existing coincident anchors will remain separate.';select.setAttribute('aria-label','Surviving GRID for group '+(index+1));for(const id of anchors){const option=doc.createElement('option');option.value=String(id);option.textContent=String(id);select.append(option);}select.value=String(state.anchors.get(index)??(anchors.includes(group.retained_node)?group.retained_node:anchors[0]));state.anchors.set(index,Number(select.value));select.onchange=()=>{state.anchors.set(index,Number(select.value));if(state.previewVisible)onPreview(currentPreview());};kept.append(select);}else{const retained=anchors[0]??group.retained_node;state.anchors.set(index,retained);kept.textContent=String(retained);}
        const gap = doc.createElement('td'); gap.textContent = numberText(group.max_distance); gap.title = units();
        const inspectCell = doc.createElement('td'), inspect = doc.createElement('button'); inspect.type = 'button'; inspect.textContent = 'Highlight';
        inspect.title = 'Highlight nodes ' + group.nodes.join(', ') + ' in the 3D view.';
        inspect.onclick = () => {try {onPreview(currentPreview({candidate_groups: [{...group,nodes:[...new Set([...group.nodes,...(group.anchor_nodes||[])])],retained_node:state.anchors.get(index)??group.retained_node}]})); state.previewVisible = true;} catch (error) {showMessage(error.message, true);}};
        inspectCell.append(inspect); row.append(checkCell, ids, kept, gap, inspectCell); rows.append(row);
      });
      updateCandidateControls();
      updateOperationReport();
    }
    function sync() {
      if (state.destroyed) return;
      const context = readContext() || {}, available = context.available !== false;
      role('source').textContent = context.sourceName ? 'Current model: ' + context.sourceName : 'Current finite-element model';
      role('units').textContent = units();
      role('summary').textContent = state.summary ? numberText(state.summary.nodes) + ' nodes · ' + numberText(state.summary.elements) + ' elements · revision ' + state.revision : available ? 'Start an editable copy to use these tools.' : 'Create a FEM or read an external model before using these tools.';
      role('stale').hidden = !state.changed;
      element.setAttribute('aria-busy', String(state.busy));
      for (const name of ['plane-fields', 'transform-fields', 'join-fields']) role(name).disabled = state.busy || !!state.picking || !state.session || !!context.busy;
      button('initialize').disabled = state.busy || !!state.picking || !available || !!context.busy;
      button('initialize').textContent = state.session ? 'Start again from current model' : 'Start editable copy';
      button('undo').disabled = state.busy || !!state.picking || !state.session || state.undoDepth < 1 || !!context.busy;
      button('reset').disabled = state.busy || !!state.picking || !state.session || !state.changed || !!context.busy;
      button('export').disabled = state.busy || !!state.picking || !state.session || !!context.busy;
      button('hide-preview').disabled = state.busy || !state.previewVisible;
      role('slab').hidden = field('selection').value !== 'slab';
      role('distance').hidden = field('movement_mode').value !== 'direction';
      role('detach-control').hidden = field('transform_action').value === 'copy';
      role('detach-help').hidden = !field('detach_shared').checked || field('transform_action').value === 'copy';
      role('movement-label').textContent = field('movement_mode').value === 'direction' ? 'Direction vector' : 'Translation vector · ΔX, ΔY, ΔZ';
      button('pick-plane-point').disabled = button('pick-translation-vector').disabled = typeof onPickNodes !== 'function';
      button('pick-part').disabled = typeof onPickPart !== 'function';
      role('node-pick').hidden = !state.picking;
      const selected = !!state.explicitPart || state.usePlaneSelection;
      button('translate').disabled = button('copy').disabled = state.busy || !!state.picking || !state.session || !!context.busy || !selected;
      button('translate').textContent = field('transform_action').value === 'copy' ? 'Apply copy · keep original' : 'Apply move';
      role('selection-prompt').hidden = selected;
      updateCandidateControls();
      updateOperationReport();
    }
    const coordinateText = xyz => '(' + xyz.map(value => String(value)).join(', ') + ')';
    const pickedNodeText = node => 'GRID ' + node.id + ' · XYZ ' + coordinateText(node.xyz);
    function updatePartReport() {
      role('part-selection').hidden = !state.explicitPart;
      if (state.explicitPart) role('part-selection-text').textContent = 'Selected: ' + (state.explicitPart.part.label || state.explicitPart.part.id || 'Connected part') + ' · ' + state.explicitPart.element_ids.length + ' elements. This picked part overrides the plane selection.' + (state.explicitPart.lastOperation==='copy'?' The original source part remains selected; pick the new copy in 3D to select it.':state.explicitPart.lastOperation==='translate'?' The moved part remains selected.':'') + (state.explicitPart.requires_cut ? ' This component crosses the cutting plane; cut it first if you intend to move only one side.' : '');
      role('parts-summary').hidden = !state.parts.length; role('parts-summary').replaceChildren();
      for (const part of state.parts.slice(0, 50)) {const row = doc.createElement('li'); row.textContent = (part.label || part.id) + ' · ' + (part.element_count ?? part.element_ids?.length ?? '—') + ' elements' + (part.side ? ' · ' + part.side : '') + (part.requires_cut ? ' · crosses the plane' : ''); role('parts-summary').append(row);}
      if (state.parts.length > 50) {const row = doc.createElement('li'); row.textContent = 'Showing 50 of ' + state.parts.length + ' parts. Pick any connected part directly in 3D.'; role('parts-summary').append(row);}
    }
    function clearPartSelection({keepParts = false} = {}) {state.explicitPart = null; state.usePlaneSelection = false; if (!keepParts) state.parts = []; updatePartReport();}
    function updatePickReports() {
      role('plane-picked').hidden = !state.planePick;
      if (state.planePick) role('plane-picked').textContent = 'Plane point: ' + pickedNodeText(state.planePick.node) + ' · ' + units() + ' · picked at revision ' + state.planePick.revision;
      role('vector-picked').hidden = !state.vectorPick;
      if (state.vectorPick) {
        const picked = state.vectorPick;
        role('vector-picked').textContent = 'Start A: ' + pickedNodeText(picked.nodes[0]) + '\nEnd B: ' + pickedNodeText(picked.nodes[1]) + '\nPicked Δ = B − A: ' + coordinateText(picked.delta) + ' · ' + units() + ' · revision ' + picked.revision + (picked.edited ? '\nThe current movement inputs have been edited after picking.' : '');
      }
    }
    function cancelPicking(message) {
      if (!state.picking) return;
      const active = state.picking; state.picking = null; state.pickSerial++; active.controller.abort();
      if (message) showMessage(message);
      sync();
    }
    async function startNodePick(kind) {
      if (state.busy || state.picking || !state.session || typeof onPickNodes !== 'function') return;
      const count = kind === 'plane-point' ? 1 : 2, controller = new (doc.defaultView?.AbortController || root.AbortController)(), serial = ++state.pickSerial;
      const context = {session: state.session, revision: state.revision, modelKey: readContext()?.modelKey};
      state.picking = {kind, controller}; role('message').hidden = true;
      role('node-pick-text').textContent = kind === 'plane-point' ? 'Click the GRID to place the cutting plane. Coordinates use the stored model system.' : 'Click the start GRID A, then the end GRID B. Translation will be B − A.'; sync();
      try {
        const result = await onPickNodes({kind, count, signal: controller.signal, onProgress: progress => {
          if (serial !== state.pickSerial || state.destroyed) return;
          const nodes = pickedNodes(progress);
          const message = progress?.message || (nodes.length < count ? count === 1 ? 'Click a GRID to place the plane point.' : nodes.length ? 'Now click the end GRID B. Existing movement inputs are retained until the second pick.' : 'Click the start GRID A, then the end GRID B.' : 'Reading stored model coordinates…');
          role('node-pick-text').textContent = nodes.map(pickedNodeText).join('\n') + (nodes.length ? '\n' : '') + message;
        }});
        if (serial !== state.pickSerial || state.destroyed) return;
        if (result?.cancelled) {showMessage('GRID picking cancelled. The previous inputs were retained.'); return;}
        if (state.session !== context.session || state.revision !== context.revision || context.modelKey != null && readContext()?.modelKey !== context.modelKey) {clearSession('The model changed while picking. Start a new editable copy and pick again.'); return;}
        if (kind === 'plane-point') {
          const nodes = pickedNodes(result); if (nodes.length !== 1) throw Error('Pick one GRID for the plane point.');
          clearPartSelection();
          ['x', 'y', 'z'].forEach((axis, index) => {field('point_' + axis).value = String(nodes[0].xyz[index]);});
          state.planeTouched = true; state.planePick = {node: nodes[0], revision: state.revision};
          state.previewVisible = true; onPreview(currentPreview());
          showMessage('Plane point set from GRID ' + nodes[0].id + '. The normal direction is unchanged.');
        } else {
          const picked = pickedVector(result); field('movement_mode').value = 'vector';
          ['x', 'y', 'z'].forEach((axis, index) => {field('move_' + axis).value = String(picked.delta[index]);});
          state.vectorPick = {...picked, revision: state.revision, edited: false};
          showMessage('Translation vector set from GRID ' + picked.nodes[0].id + ' to GRID ' + picked.nodes[1].id + '. Edit any component before moving or copying.');
        }
        // Computed native coordinates intentionally retain their double precision.
        // No input/change event is emitted: those events quantize explicit user edits.
        updatePickReports();
      } catch (error) {
        if (serial === state.pickSerial && !state.destroyed) showMessage(error?.name === 'AbortError' ? 'GRID picking cancelled. The previous inputs were retained.' : error?.message || String(error), error?.name !== 'AbortError');
      } finally {if (serial === state.pickSerial) {state.picking = null; sync();}}
    }
    button('pick-plane-point').onclick = () => startNodePick('plane-point');
    button('pick-translation-vector').onclick = () => startNodePick('translation-vector');
    button('cancel-pick').onclick = () => cancelPicking('3D picking cancelled. The previous inputs and part selection were retained.');
    const escapePick = event => {if (event.key === 'Escape' && state.picking) {event.preventDefault(); cancelPicking('3D picking cancelled. The previous inputs and part selection were retained.');}};
    doc.addEventListener('keydown', escapePick, true);
    button('parts').onclick = () => attempt(async () => {
      const data = await operation('parts', {plane: readPlane(), selection: readSelection()}, {label: 'Identify connected parts'});
      if (!data) return;
      if (!Array.isArray(data.parts)) throw Error('The model editor did not return its connected parts.');
      state.parts = data.parts; updatePartReport(); state.previewVisible = true; onPreview(currentPreview()); sync();
      showMessage(state.parts.length + ' connected parts identified. Use Pick part in 3D, then click the part to move or copy.');
    });
    button('pick-part').onclick = () => attempt(async () => {
      if (state.busy || state.picking || !state.session || typeof onPickPart !== 'function') return;
      const plane = readPlane(), controller = new (doc.defaultView?.AbortController || root.AbortController)(), serial = ++state.pickSerial;
      const context = {session: state.session, revision: state.revision, modelKey: readContext()?.modelKey};
      state.picking = {kind: 'part', controller}; role('message').hidden = true; role('node-pick-text').textContent = 'Click an element belonging to the connected part to move or copy.'; sync();
      try {
        const result = await onPickPart({plane, signal: controller.signal, onProgress: progress => {if (serial === state.pickSerial && !state.destroyed) role('node-pick-text').textContent = typeof progress === 'string' ? progress : progress?.message || 'Identifying the connected part…';}});
        if (serial !== state.pickSerial || state.destroyed) return;
        if (result?.cancelled) {showMessage('Part picking cancelled. The previous selection was retained.'); return;}
        if (state.session !== context.session || state.revision !== context.revision || context.modelKey != null && readContext()?.modelKey !== context.modelKey) {clearSession('The model changed while picking. Start a new editable copy and identify its parts again.'); return;}
        state.explicitPart = pickedPart(result); state.usePlaneSelection = false; updatePartReport(); state.previewVisible = true; onPreview(currentPreview());
        showMessage(result.warning || 'Picked ' + (state.explicitPart.part.label || state.explicitPart.part.id || 'connected part') + '. Movement and copying will use its ' + state.explicitPart.element_ids.length + ' selected elements.');
      } catch (error) {if (serial === state.pickSerial && !state.destroyed) showMessage(error?.name === 'AbortError' ? 'Part picking cancelled. The previous selection was retained.' : error?.message || String(error), error?.name !== 'AbortError');}
      finally {if (serial === state.pickSerial) {state.picking = null; sync();}}
    });
    button('clear-part').onclick = () => {clearPartSelection({keepParts: true}); state.usePlaneSelection = true; sync(); if (state.previewVisible) attempt(() => onPreview(currentPreview()));};
    function centerPlane(bounds) {
      if (state.planeTouched || !bounds || !Array.isArray(bounds.min) || !Array.isArray(bounds.max)) return;
      const lengths = bounds.max.map((value, index) => value - bounds.min[index]);
      if (lengths.some(value => !Number.isFinite(value))) return;
      ['x', 'y', 'z'].forEach((axis, index) => {field('point_' + axis).value = String((bounds.min[index] + bounds.max[index]) / 2);});
      const size = Math.max(...lengths, 1e-6);
      field('side_length').value = String(size * 1.2); field('tolerance').value = String(Number((size * 1e-8).toPrecision(4)));
      field('node_tolerance').value = String(Number((size * 1e-7).toPrecision(4))); field('depth').value = String(Math.max(lengths[0] / 10, size / 100));
    }
    async function operation(action, payload, {commit = false, label = action} = {}) {
      if (state.busy || state.picking || state.destroyed) return null;
      const started = {session: state.session, revision: state.revision, modelKey: readContext()?.modelKey};
      state.busy = true; showMessage(label + '…'); sync();
      try {
        const data = await request(action, {...(state.session ? {session_id: state.session, revision: state.revision} : {}), ...payload});
        if (!data || data.ok === false) throw Error(data?.error || 'The model operation did not return a valid result.');
        if (state.destroyed) return null;
        if (!commit && (state.session !== started.session || state.revision !== started.revision || readContext()?.modelKey !== started.modelKey)) return null;
        if (commit) {
          if (!data.session_id || data.revision == null) throw Error('The model editor did not return its working-copy revision.');
          state.session = data.session_id; state.revision = data.revision; state.summary = data.summary || state.summary; state.source = data.source || state.source;
          state.changed = action !== 'initialize';
          state.undoDepth = Number.isInteger(data.undo_depth) ? data.undo_depth : action === 'initialize' ? 0 : action === 'undo' ? Math.max(0, state.undoDepth - 1) : state.undoDepth + 1;
          clearCandidates();
          state.parts = Array.isArray(data.parts) ? data.parts : ['translate','copy'].includes(action) ? state.parts : [];
          if (!['translate', 'copy'].includes(action)) {state.explicitPart = null; state.usePlaneSelection = false;}
          else if(state.explicitPart){
            const ids=state.explicitPart.element_ids;
            if(Array.isArray(data.parts)){const part=data.parts.find(part=>{const members=new Set(part.element_ids||[]);return ids.every(id=>members.has(id));});if(part)state.explicitPart.part=part;else state.explicitPart=null;}
            if(state.explicitPart)state.explicitPart.lastOperation=action;
          }
          updatePartReport();
          if (action === 'initialize') centerPlane(data.summary?.bounds);
          await onCommit(data, action); state.modelKey = readContext()?.modelKey ?? null;
          if(['translate','copy'].includes(action)&&data.operation_coincidences){
            const info=data.operation_coincidences;
            state.operationInfo={...info,candidate_groups:candidateGroups(info.candidate_groups)};
            if(state.operationInfo.revision!==state.revision||!state.operationInfo.operation_id)throw Error('The move / copy returned an invalid coincidence-review identity. The edited model is retained; no nodes were merged.');
            showOperationCandidates();state.previewVisible=true;updateOperationReport();
          }
          if (action === 'cut') {
            // Current servers include connected parts in the validated cut reply.
            // The fallback supports an already running older server, once only.
            if (!Array.isArray(data.parts)) {
              const version = {session: state.session, revision: state.revision, modelKey: state.modelKey};
              try{const parts = await request('parts', {session_id: state.session, revision: state.revision, plane: readPlane(), selection: readSelection()});
                if (state.destroyed || state.session !== version.session || state.revision !== version.revision || readContext()?.modelKey !== version.modelKey) return null;
                if (parts?.ok !== false && Array.isArray(parts?.parts)) state.parts = parts.parts;
              }catch(error){data.summary??={};data.summary.warnings=[...(data.summary.warnings||[]),'Cut succeeded; connected-part display could not be refreshed: '+error.message];}
            }
            state.previewVisible = true; updatePartReport();
          }
          if (state.previewVisible) onPreview(currentPreview());
        }
        const warnings = data.summary?.warnings || data.warnings || [];
        showMessage((data.message || (label + ' complete.')) + (action === 'cut' && state.parts.length ? '\n' + state.parts.length + ' connected parts are shown. Pick the part to move or copy in 3D.' : '') + (warnings.length ? '\n' + warnings.join('\n') : ''));
        return data;
      } catch (error) {
        if (!state.destroyed) showMessage(error?.message || String(error), true);
        return null;
      } finally {state.busy = false; refresh();}
    }
    function attempt(work) {
      try {
        const result = work();
        return result && typeof result.catch === 'function' ? result.catch(error => {showMessage(error?.message || String(error), true); return null;}) : result;
      } catch (error) {showMessage(error?.message || String(error), true); return null;}
    }
    button('initialize').onclick = () => attempt(() => operation('initialize', readContext()?.initialize || {}, {commit: true, label: 'Prepare editable model'}));
    button('preview').onclick = () => attempt(async () => {
      const preview = currentPreview(); onPreview(preview); state.previewVisible = true; sync();
      const data = await operation('preview', {plane: preview.plane, selection: preview.selection}, {label: 'Preview cut and selection'});
      if (data) onPreview({...preview, ...data, show_plane: true});
    });
    button('hide-preview').onclick = () => {hidePreview(); sync();};
    button('cut').onclick = () => attempt(() => operation('cut', {plane: readPlane(), duplicate_nodes: field('duplicate_nodes').checked}, {commit: true, label: 'Cut model'}));
    button('cut-second').onclick = () => attempt(() => operation('cut', {plane: readSelection().second_plane, duplicate_nodes: field('duplicate_nodes').checked}, {commit: true, label: 'Cut second slice boundary'}));
    button('translate').onclick = () => attempt(() => {
      if (!state.explicitPart && !state.usePlaneSelection) throw Error('Pick a connected part in 3D, or explicitly use the plane / slice selection.');
      const copying = field('transform_action').value === 'copy';
      const coincidence_tolerance=finite(field('node_tolerance').value,'New-overlap tolerance');if(!(coincidence_tolerance>0))throw Error('New-overlap tolerance must be positive.');
      return operation(copying ? 'copy' : 'translate', {selection: readSelection(), vector: readMovement(), coincidence_tolerance, ...(copying ? {count: 1} : {detach_shared: field('detach_shared').checked}), ...(state.explicitPart ? {element_ids: state.explicitPart.element_ids} : {})}, {commit: true, label: copying ? 'Copy selected part' : 'Move selected part'});
    });
    button('copy').onclick = () => attempt(() => {
      const count = finite(field('copy_count').value, 'Number of copies');
      if (!Number.isInteger(count) || count < 1 || count > 1000) throw Error('Enter between 1 and 1000 whole copies.');
      const coincidence_tolerance=finite(field('node_tolerance').value,'New-overlap tolerance');if(!(coincidence_tolerance>0))throw Error('New-overlap tolerance must be positive.');
      return operation('copy', {selection: readSelection(), vector: readMovement(), count, coincidence_tolerance, ...(state.explicitPart ? {element_ids: state.explicitPart.element_ids} : {})}, {commit: true, label: 'Copy selected part'});
    });
    button('candidates').onclick = () => attempt(async () => {
      const tolerance = finite(field('global_node_tolerance').value, 'Global search tolerance');
      if (!(tolerance > 0)) throw Error('Node search tolerance must be greater than zero.');
      const data = await operation('candidates', {tolerance}, {label: 'Find coincident nodes'});
      if (!data) return;
      try {state.groups = candidateGroups(data.candidate_groups);state.candidateScope='global';state.candidateRevision=state.revision;state.candidateTolerance=tolerance;state.anchors.clear();state.selected.clear(); state.page = 0; renderCandidates();if(state.previewVisible)onPreview(currentPreview()); showMessage(state.groups.length ? state.groups.length + ' global candidate groups found, including preexisting coincidences. Review these separately from the latest operation.' : 'No global coincident-node candidates were found at this tolerance.');}
      catch (error) {showMessage(error.message, true);}
    });
    field('select_all').onchange = () => {state.selected = field('select_all').checked ? new Set(state.groups.map((_, index) => index)) : new Set(); renderCandidates();};
    button('previous').onclick = () => {state.page--; renderCandidates();};
    button('next').onclick = () => {state.page++; renderCandidates();};
    button('equivalence').onclick = () => attempt(() => {
      if(state.candidateRevision!==state.revision)throw Error('The coincidence review is stale. Search again on the current model.');
      const operationScoped=state.candidateScope==='operation',info=state.operationInfo;
      const groups = [...state.selected].map(index => {const group=state.groups[index];if(!operationScoped)return group.nodes;const retained_node=state.anchors.get(index)??(group.anchor_nodes?.length&&!group.anchor_nodes.includes(group.retained_node)?group.anchor_nodes[0]:group.retained_node),affected=group.affected_nodes||group.nodes.filter(id=>!(group.anchor_nodes||[]).includes(id));return{nodes:[...new Set([retained_node,...affected])],retained_node};});
      if (!groups.length) throw Error('Select the candidate groups that should be joined.');
      if(operationScoped&&(!info?.operation_id||info.revision!==state.revision))throw Error('The operation review is stale. No nodes were merged.');
      return operation('equivalence', {groups, tolerance: state.candidateTolerance, ...(operationScoped?{operation_id:info.operation_id}:{})}, {commit: true, label: 'Equivalence selected node groups'});
    });
    button('undo').onclick = () => operation('undo', {}, {commit: true, label: 'Undo last operation'});
    button('reset').onclick = () => operation('reset', {}, {commit: true, label: 'Restore original working model'});
    button('dismiss').onclick = () => {role('message').hidden = true;};
    async function fallbackExport(data) {
      const name = data.name || 'edited_model.bdf', browser = doc.defaultView || root;
      let destination;
      if (root.WingWorkspace?.requestStudyDestination) destination = root.WingWorkspace.requestStudyDestination(name, {saveAs: true, preferNative: true}, browser);
      else if (typeof browser.showSaveFilePicker === 'function') destination = browser.showSaveFilePicker({suggestedName: name, types: [{description: 'Nastran model', accept: {'text/plain': ['.bdf', '.dat', '.nas']}}]}).then(handle => ({method: 'picker', handle}));
      else throw Error('The file chooser is unavailable. Save Study retains the edited source; restart Boxer to enable its system file picker.');
      try {
        destination = await destination; if (destination?.cancelled) return false;
        if (root.WingWorkspace?.writeDestination) return root.WingWorkspace.writeDestination(destination, data.deck_text, 'text/plain', doc, browser);
        const writer = await destination.handle.createWritable(); try {await writer.write(data.deck_text); await writer.close();} catch (error) {await writer.abort?.(); throw error;}
        return true;
      } catch (error) {if (error?.name === 'AbortError') return false; throw error;}
    }
    button('export').onclick = () => attempt(async () => {
      if (state.busy) return;
      state.busy = true; showMessage('Choose a name and folder for the edited Nastran model…'); sync();
      try {
        // Cached source keeps the file-picker call within this click's activation.
        let data = {session_id: state.session, revision: state.revision, source: state.source, name: state.source?.name || 'edited_model.bdf', deck_text: state.source?.text};
        if (typeof data.deck_text !== 'string') data = {...data, ...await request('export', {session_id: state.session, revision: state.revision})};
        if (typeof data.deck_text !== 'string') throw Error(data.error || 'The model editor did not return a complete Nastran deck.');
        const saved = await (onExport || fallbackExport)(data);
        showMessage(saved === false || saved?.cancelled ? 'Save cancelled. Your edited model remains available.' : 'Edited Nastran model saved. Save Study also retains the working model.');
      } catch (error) {showMessage(error?.message || String(error), true);}
      finally {state.busy = false; sync();}
    });
    element.addEventListener('input', event => {
      const key = event.target.dataset.field;
      if (/^(point_|normal_|side_length|tolerance)/.test(key || '')) state.planeTouched = true;
      if (/^(point_|normal_|side_length|tolerance|depth)/.test(key || '')) clearPartSelection();
      if (/^point_[xyz]$/.test(key || '')) {state.planePick = null; updatePickReports();}
      if (/^move_[xyz]$/.test(key || '') && state.vectorPick) {state.vectorPick.edited = true; updatePickReports();}
      if (/^normal_[xyz]$/.test(key || '')) field('normal_axis').value = 'custom';
      if (key === 'global_node_tolerance' && state.candidateScope==='global') {const info=state.operationInfo;clearCandidates();state.operationInfo=info;updateOperationReport();showMessage('Global search tolerance changed. Search again before merging.');}
    });
    element.addEventListener('change', event => {
      const key = event.target.dataset.field;
      if (key === 'normal_axis' && field(key).value !== 'custom') {
        ['x', 'y', 'z'].forEach(axis => {field('normal_' + axis).value = axis === field(key).value ? '1' : '0';}); state.planeTouched = true;
      }
      if (['selection', 'normal_axis'].includes(key)) {clearPartSelection({keepParts: key === 'selection'}); if (key === 'selection') state.usePlaneSelection = true;}
      if (['selection', 'movement_mode', 'normal_axis', 'detach_shared', 'transform_action'].includes(key)) sync();
      if (['movement_mode', 'distance'].includes(key) && state.vectorPick) {state.vectorPick.edited = true; updatePickReports();}
      if (state.previewVisible && /^(point_|normal_|side_length|tolerance|depth|selection)/.test(key || '')) attempt(() => onPreview(currentPreview()));
    });
    function snapshot() {
      const inputs = {};
      for (const input of element.querySelectorAll('[data-field]')) if (input.dataset.field !== 'select_all') inputs[input.dataset.field] = input.type === 'checkbox' ? input.checked : input.value;
      return {version: 1, inputs};
    }
    function restore(saved) {
      if (!saved || saved.version !== 1 || !saved.inputs || typeof saved.inputs !== 'object') return false;
      cancelPicking(); state.planePick = null; state.vectorPick = null; updatePickReports(); clearPartSelection();
      for (const [key, value] of Object.entries(saved.inputs)) {
        const input = field(key); if (!input || key === 'select_all') continue;
        if (input.type === 'checkbox') {if (typeof value === 'boolean') input.checked = value;}
        else if (typeof value === 'string' || typeof value === 'number') {
          if (input.tagName !== 'SELECT' || [...input.options].some(option => option.value === String(value))) input.value = String(value);
        }
      }
      state.planeTouched = true; sync(); return true;
    }
    function refresh() {
      const context = readContext() || {};
      if (!state.busy && state.session && state.modelKey != null && context.modelKey != null && state.modelKey !== context.modelKey) clearSession('The current model changed. Start a new editable copy to edit this FEM.');
      sync();
    }
    sync();
    return {refresh, restore, snapshot, reset() {clearSession(); state.planeTouched = false; showMessage(''); sync();}, destroy() {cancelPicking(); state.destroyed = true; doc.removeEventListener('keydown', escapePick, true); hidePreview(); element.remove();}, get busy() {return state.busy;}, get picking() {return !!state.picking;}, get session() {return state.session;}, get revision() {return state.revision;}};
  }
  return {finite, vector, unitVector, plane, selection, translation, candidateGroups, pickedNodes, pickedVector, pickedPart, install};
});
