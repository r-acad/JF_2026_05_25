/* Screen-space FE IDs and selection halo. No additional WebGL meshes/textures
 * are allocated per entity; labels follow the same deformed node coordinates
 * as the structural renderer. References are intentionally not FE annotations.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingAnnotations = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const COLORS = { node: "#78e1ed", support: "#ff8190", quad: "#8bbcff", tria: "#81e1ad",
    stringer: "#ffdf00", cap: "#ff9c39", ribStiffener: "#a9e4ef", bar: "#ffe8a0", rbe3: "#d9b1ff", fuel: "#91f5d5", selected: "#ffe478" };
  const LEGEND = [["GRID", "node"], ["Supported GRID", "support"], ["CQUAD4", "quad"],
    ["CTRIA3", "tria"], ["Stringer", "stringer"], ["Spar cap", "cap"], ["Rib stiffener", "ribStiffener"], ["RBE3", "rbe3"], ["Fuel reference", "fuel"]];
  const baseGroup = (name) => name.replace(/_KINKS$/, "").replace(/_P\d+$/, "");
  function elementStyle(element) {
    const group = element.group, name = group.base_group || baseGroup(group.name);
    if (group.kind === "quad") return { prefix: "Q", name: "CQUAD4", color: COLORS.quad };
    if (group.kind === "tria") return { prefix: "T", name: "CTRIA3", color: COLORS.tria };
    if (group.kind === "rbe3") return { prefix: "R", name: "RBE3", color: name === "FUEL_RBE3" ? COLORS.fuel : COLORS.rbe3 };
    if (group.kind === "conm2") return { prefix: "M", name: "CONM2", color: COLORS.fuel };
    return { prefix: "B", name: "CBAR", color: name === "SPAR_CAPS" ? COLORS.cap :
      name === "RIB_STIFFENERS" ? COLORS.ribStiffener : name.startsWith("STRINGER") ? COLORS.stringer : COLORS.bar };
  }
  function centroid(positions, nodes) {
    const p = [0, 0, 0];
    for (const node of nodes) for (let a = 0; a < 3; a++) p[a] += positions[3 * node + a] / nodes.length;
    return p;
  }
  function displayedPoint(state,id,p){return state.panelExplosion?.point(id,p)||p;}
  function visibleElement(state, element) {
    const layer = state.layers.get(element.group.name) || state.layers.get(element.group.base_group || baseGroup(element.group.name));
    return !layer || layer.visible;
  }
  function labelCandidates(state, positions, showNodes, showElements) {
    const candidates = [], visibleNodes = new Set(), nodeStyles = new Map();
    for (const [id, element] of state.elements) {
      if (!visibleElement(state, element)) continue;
      if (showNodes) for (const node of element.nodes) visibleNodes.add(node);
      if (showElements) {
        const style = elementStyle(element);
        candidates.push({ text: style.prefix + " " + id, id, kind: "element", color: style.color,
          point: displayedPoint(state,id,centroid(positions, element.group.kind === "rbe3" ? element.nodes.slice(0, 1) : element.nodes)) });
      }
    }
    if (showNodes) {
      for (const marker of state.markers) {
        const layer = state.layers.get(marker.kind);
        if (layer && layer.visible) {
          visibleNodes.add(marker.node);
          if (marker.kind === "SPC") nodeStyles.set(marker.node, COLORS.support);
          else if (marker.kind === "RBE3_NODES") nodeStyles.set(marker.node, COLORS.rbe3);
          else if (marker.kind === "FUEL_RBE3_NODES") nodeStyles.set(marker.node, COLORS.fuel);
        }
      }
      if(state.layers.get("SPC")?.visible)for(const node of state.supportGlyphs?.nodes || []){visibleNodes.add(node);nodeStyles.set(node,COLORS.support);}
      if (state.layers.get("NODES")?.visible) for (let i = 0; i < state.data.nodes.n_structural; i++) visibleNodes.add(i);
      for (const node of visibleNodes) candidates.push({ text: "N " + state.nodeIds[node], id: state.nodeIds[node], kind: "node",
        color: nodeStyles.get(node) || COLORS.node, point: Array.from(positions.subarray(3 * node, 3 * node + 3)) });
    }
    return candidates;
  }
  /** Triangle geometry whose visible surfaces really write opaque depth. */
  function opaqueOccluders(scene) {
    return scene.meshes.filter((mesh) => {
      const kind = mesh.metadata?.feGroup?.kind;
      if (!["quad", "tria", "bar"].includes(kind) && mesh.translucentAlpha === undefined && mesh.metadata?.wingReferenceId === undefined) return false;
      if (!mesh.isEnabled() || !mesh.isVisible || mesh.visibility < 1 || mesh.isDisposed()) return false;
      const material = mesh.material;
      if (!material || material.wireframe || mesh.getClassName().includes("Lines") || !mesh.getTotalIndices()) return false;
      return !material.needAlphaBlendingForMesh(mesh);
    });
  }

  /**
   * A screen-space triangle index provides the same front-surface comparison
   * as a depth buffer without a scene-wide ray pick for every possible ID.
   * Eye depth is interpolated perspectively, so zoom and camera distance do
   * not change the world-space tolerance for IDs attached to a shell face.
   */
  function buildOcclusionIndex(B, meshes, camera, matrix, viewport, width, height, renderWidth, renderHeight, modelSize = 1) {
    const cells = new Map(), cellSize = 48, screen = new B.Vector3(), point = new B.Vector3();
    const eye = camera.globalPosition || camera.position, forward = camera.getForwardRay(1).direction;
    const near = Math.max(1e-8, camera.minZ), far = camera.maxZ;
    const perspective = camera.mode !== B.Camera.ORTHOGRAPHIC_CAMERA;
    const metrics = { meshes: meshes.length, triangles: 0, queries: 0, triangleTests: 0 };
    function depth(p) { return (p[0] - eye.x) * forward.x + (p[1] - eye.y) * forward.y + (p[2] - eye.z) * forward.z; }
    function project(p, d = depth(p)) {
      point.copyFromFloats(...p); B.Vector3.ProjectToRef(point, B.Matrix.IdentityReadOnly, matrix, viewport, screen);
      return { x: screen.x * width / renderWidth, y: screen.y * height / renderHeight, depth: d, point: p };
    }
    function clip(vertices, limit, keepGreater) {
      const result = [];
      for (let i = 0; i < vertices.length; i++) {
        const a = vertices[i], b = vertices[(i + 1) % vertices.length];
        const insideA = keepGreater ? a.depth >= limit : a.depth <= limit;
        const insideB = keepGreater ? b.depth >= limit : b.depth <= limit;
        if (insideA) result.push(a);
        if (insideA !== insideB) {
          const t = (limit - a.depth) / (b.depth - a.depth);
          result.push(project(a.point.map((v, j) => v + t * (b.point[j] - v)), limit));
        }
      }
      return result;
    }
    function addTriangle(a, b, c, owner) {
      const denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
      if (!Number.isFinite(denominator) || Math.abs(denominator) < 1e-9) return;
      const minX = Math.max(0, Math.floor(Math.min(a.x, b.x, c.x) / cellSize));
      const maxX = Math.min(Math.floor(width / cellSize), Math.floor(Math.max(a.x, b.x, c.x) / cellSize));
      const minY = Math.max(0, Math.floor(Math.min(a.y, b.y, c.y) / cellSize));
      const maxY = Math.min(Math.floor(height / cellSize), Math.floor(Math.max(a.y, b.y, c.y) / cellSize));
      if (maxX < minX || maxY < minY) return;
      const triangle = { a, b, c, owner, denominator }; metrics.triangles++;
      for (let x = minX; x <= maxX; x++) for (let y = minY; y <= maxY; y++) {
        const key = x + ":" + y;
        if (!cells.has(key)) cells.set(key, []);
        cells.get(key).push(triangle);
      }
    }
    for (const mesh of meshes) {
      const coords = mesh.getVerticesData(B.VertexBuffer.PositionKind), indices = mesh.getIndices();
      if (!coords || !indices) continue;
      const world = mesh.computeWorldMatrix(true), vertices = new Array(coords.length / 3), transformed = new B.Vector3();
      for (let i = 0; i < vertices.length; i++) {
        point.copyFromFloats(coords[3*i], coords[3*i+1], coords[3*i+2]);
        B.Vector3.TransformCoordinatesToRef(point, world, transformed);
        vertices[i] = project([transformed.x, transformed.y, transformed.z]);
      }
      for (let i = 0; i < indices.length; i += 3) {
        let polygon = [vertices[indices[i]], vertices[indices[i+1]], vertices[indices[i+2]]];
        if (polygon.some((v) => v.depth < near)) polygon = clip(polygon, near, true);
        if (polygon.some((v) => v.depth > far)) polygon = clip(polygon, far, false);
        const face = i / 3, local = mesh.metadata?.faceElements ? mesh.metadata.faceElements[face] : Math.floor(face / (mesh.metadata?.facesPerElement || 1));
        const owner = mesh.elementIds ? mesh.elementIds[local] : undefined;
        for (let j = 1; j < polygon.length - 1; j++) addTriangle(polygon[0], polygon[j], polygon[j+1], owner);
      }
    }
    return {
      metrics,
      isOccluded(candidate, projected) {
        metrics.queries++;
        const d = depth(candidate.point), tolerance = Math.max(1e-7, modelSize * 1e-6, Math.abs(d) * 2e-7);
        const bucket = cells.get(Math.floor(projected.x / cellSize) + ":" + Math.floor(projected.y / cellSize)) || [];
        for (const t of bucket) {
          // A warped CQUAD4's averaged center can lie slightly behind one of
          // its own rendered triangles. Other elements still occlude it.
          if (candidate.kind === "element" && t.owner === candidate.id || candidate.ownEids?.includes(t.owner)) continue;
          metrics.triangleTests++;
          const a = ((t.b.y - t.c.y) * (projected.x - t.c.x) + (t.c.x - t.b.x) * (projected.y - t.c.y)) / t.denominator;
          const b = ((t.c.y - t.a.y) * (projected.x - t.c.x) + (t.a.x - t.c.x) * (projected.y - t.c.y)) / t.denominator;
          const c = 1 - a - b;
          if (a < -1e-7 || b < -1e-7 || c < -1e-7) continue;
          const surfaceDepth = perspective ? 1 / (a / t.a.depth + b / t.b.depth + c / t.c.depth) : a * t.a.depth + b * t.b.depth + c * t.c.depth;
          if (surfaceDepth < d - tolerance) return true;
        }
        return false;
      },
    };
  }

  function physicalLabelCandidates(state, positions, showRibs, showStringers) {
    const candidates = [], annotations = state.data?.annotations;
    if (!annotations) return candidates;
    const layerVisible = (name) => Array.from(state.layers).some(([key,layer]) => baseGroup(key) === name && layer.visible === true);
    const generatedRibs = new Map((state.data?.rib_layout?.ribs || []).map(rib => [rib.number, rib]));
    const add = (entry, kind, color) => {
      const nodes = entry.anchor_nodes || [], weights = entry.anchor_weights || [];
      if (!nodes.length) return;
      const point = [0, 0, 0];
      for (let i = 0; i < nodes.length; i++) for (let a = 0; a < 3; a++)
        point[a] += positions[3 * nodes[i] + a] * (weights[i] === undefined ? 1 / nodes.length : weights[i]);
      if (point.every(Number.isFinite)) candidates.push({ text: kind === "rib" ? "R " + entry.index : entry.label, id: entry.index, kind, color, point,
        ownEids: [...(entry.eids || []), ...(entry.runout_eids || [])] });
    };
    if (showRibs) for (const rib of annotations.ribs || []) {
      const generated = generatedRibs.get(rib.index);
      const ribVisible = generated?.eids?.length ? generated.eids.some(id => {const element=state.elements.get(id);return element && visibleElement(state,element);}) : layerVisible("RIB_WEBS");
      if(ribVisible)add({...rib,eids:generated?.eids || rib.eids},"rib",COLORS.tria);
      else if(layerVisible("LE_RIB_WEBS"))add({...rib,anchor_nodes:rib.leading_edge_anchor_nodes||[],anchor_weights:rib.leading_edge_anchor_weights||[]},"rib",COLORS.tria);
      else if(layerVisible("LE_RIB_NOSE"))add({...rib,anchor_nodes:rib.leading_edge_nose_anchor_nodes||[],anchor_weights:rib.leading_edge_nose_anchor_weights||[]},"rib",COLORS.tria);
    }
    if (showStringers) for (const stringer of annotations.stringers || []) {
      const membersVisible = (ids, family) => ids?.length && ids.some(id => state.elements.has(id)) ? ids.some(id => {const element=state.elements.get(id);return element && visibleElement(state,element);}) : layerVisible(family);
      if (membersVisible(stringer.eids,"STRINGERS")) add(stringer, "stringer", COLORS.stringer);
      else if (membersVisible(stringer.runout_eids,"STRINGER_RUNOUTS")) add({ ...stringer,
        anchor_nodes: stringer.runout_anchor_nodes || [], anchor_weights: stringer.runout_anchor_weights || [] }, "stringer", COLORS.stringer);
    }
    return candidates;
  }
  function panelLabelCandidates(state,positions){
    if(!state.panelView&&!state.panelExplosion?.active)return [];
    const candidates=[];
    for(const panel of state.panelIndex?.panels||[]){
      let elements=panel.shell_eids.map(id=>state.elements.get(id)).filter(e=>e&&visibleElement(state,e));
      if(!elements.length)elements=panel.stringer_eids.map(id=>state.elements.get(id)).filter(e=>e&&visibleElement(state,e));
      if(!elements.length)continue;
      const centers=elements.map(e=>displayedPoint(state,e.id,centroid(positions,e.nodes)));
      const mean=[0,1,2].map(a=>centers.reduce((sum,p)=>sum+p[a],0)/centers.length);
      let nearest=0,distance=Infinity;
      centers.forEach((p,i)=>{const d=p.reduce((sum,v,a)=>sum+(v-mean[a])**2,0);if(d<distance){nearest=i;distance=d;}});
      candidates.push({text:'P'+panel.id,id:panel.id,kind:'panel',color:'#ffffff',point:centers[nearest],ownEids:[elements[nearest].id]});
    }
    return candidates;
  }
  function create(options) {
    const B = options.BABYLON || globalThis.BABYLON;
    const { scene, camera, engine, canvas, getState, getPositions } = options;
    const doc = canvas.ownerDocument;
    const overlay = doc.createElement("canvas"); overlay.id = "fe-annotations";
    overlay.className = "fe-annotations"; overlay.setAttribute("aria-hidden", "true");
    canvas.parentElement.appendChild(overlay);
    const ctx = overlay.getContext("2d"), screen = new B.Vector3(), world = new B.Vector3();
    let dirty = true, lastKey = "", lastData = null, lastPositions = null, lastTime = -Infinity;
    let lastStatus = "", stats = { shown: 0, eligible: 0, occluded: 0, selected: null };
    const control = (id) => doc.getElementById(id);
    const invalidate = () => { dirty = true; };
    function legend() {
      const host = control("entity-color-legend"); if (!host) return;
      host.replaceChildren();
      for (const [name, key] of LEGEND) {
        const item = doc.createElement("span"), swatch = doc.createElement("i");
        swatch.style.backgroundColor = COLORS[key]; item.append(swatch, doc.createTextNode(name)); host.appendChild(item);
      }
    }
    function render(force = false) {
      if (!ctx) return;
      const state = getState(), positions = getPositions();
      const showNodes = !!control("show-node-ids")?.checked, showElements = !!control("show-element-ids")?.checked;
      const showRibs = !!(control("mesh-labels-ribs")?.checked || control("mesh-labels-both")?.checked);
      const showStringers = !!(control("mesh-labels-stringers")?.checked || control("mesh-labels-both")?.checked);
      const showPanels=!!state.panelView||!!state.panelExplosion?.active;
      const selected = state.elements.get(state.selectedElement);
      const size = Math.max(8, Math.min(24, Number(control("id-label-size")?.value) || 11));
      const width = canvas.clientWidth, height = canvas.clientHeight;
      const occluders = opaqueOccluders(scene);
      const occluderKey = occluders.map((mesh) => mesh.uniqueId + ":" + Array.from(mesh.computeWorldMatrix().m).join(",")).join(";");
      const key = [width, height, showNodes, showElements, showRibs, showStringers, showPanels, size, state.selectedElement,
        occluderKey, ...scene.getTransformMatrix().m, ...Array.from(state.layers, ([, layer]) => +layer.visible)].join("|");
      const now = performance.now();
      if (!force && (!dirty && key === lastKey && state.data === lastData && positions === lastPositions || now - lastTime < 30)) return;
      lastTime = now; lastKey = key; lastData = state.data; lastPositions = positions; dirty = false;
      const ratio = Math.min(2, doc.defaultView?.devicePixelRatio || 1);
      if (overlay.width !== Math.round(width * ratio) || overlay.height !== Math.round(height * ratio)) {
        overlay.width = Math.round(width * ratio); overlay.height = Math.round(height * ratio);
      }
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0); ctx.clearRect(0, 0, width, height);
      stats = { shown: 0, eligible: 0, occluded: 0, selected: null };
      if (!positions || !width || !height) { setStatus(""); return; }
      const renderWidth = engine.getRenderWidth(), renderHeight = engine.getRenderHeight();
      const viewport = camera.viewport.toGlobal(renderWidth, renderHeight), matrix = scene.getTransformMatrix();
      const project = (point) => {
        world.copyFromFloats(...point);
        B.Vector3.ProjectToRef(world, B.Matrix.IdentityReadOnly, matrix, viewport, screen);
        if (!Number.isFinite(screen.x + screen.y + screen.z) || screen.z < 0 || screen.z > 1) return null;
        return { x: screen.x * width / renderWidth, y: screen.y * height / renderHeight, z: screen.z };
      };
      const boxes = new Map(), cellSize = 48;
      let occlusion = null;
      const depthIndex = () => occlusion || (occlusion = buildOcclusionIndex(B, occluders, camera, matrix, viewport, width, height, renderWidth, renderHeight, state.diag || 1));
      function occupied(rect, insert = false) {
        let hit = false;
        for (let x = Math.floor(rect.x / cellSize); x <= Math.floor((rect.x + rect.w) / cellSize); x++)
          for (let y = Math.floor(rect.y / cellSize); y <= Math.floor((rect.y + rect.h) / cellSize); y++) {
            const key = x + ":" + y, bucket = boxes.get(key) || [];
            if (insert) { bucket.push(rect); boxes.set(key, bucket); }
            else for (const b of bucket) if (rect.x < b.x + b.w && rect.x + rect.w > b.x && rect.y < b.y + b.h && rect.y + rect.h > b.y) hit = true;
          }
        return hit;
      }
      function badge(text, point, color, picked = false, candidate = null) {
        ctx.font = (picked ? "bold " : "") + (picked ? size + 2 : size) + "px Segoe UI, sans-serif";
        const w = Math.ceil(ctx.measureText(text).width) + 10, h = size + (picked ? 12 : 7);
        const rect = { x: Math.max(2, Math.min(width - w - 2, point.x + 5)), y: Math.max(2, Math.min(height - h - 2, point.y - h - 3)), w, h };
        if (!picked && occupied(rect)) return false;
        if (candidate && depthIndex().isOccluded(candidate, point)) { if (!picked) stats.occluded++; return false; }
        occupied({ x: rect.x - 2, y: rect.y - 2, w: rect.w + 4, h: rect.h + 4 }, true);
        ctx.fillStyle = picked ? "#251d08" : "#08121ee8"; ctx.fillRect(rect.x, rect.y, w, h);
        ctx.strokeStyle = color; ctx.lineWidth = picked ? 2 : .65; ctx.strokeRect(rect.x, rect.y, w, h);
        ctx.fillStyle = color; ctx.textBaseline = "middle"; ctx.fillText(text, rect.x + 5, rect.y + h / 2);
        return true;
      }
      if (selected && visibleElement(state, selected)) {
        const anchors = Array.from(selected.nodes, (i) => displayedPoint(state,selected.id,Array.from(positions.subarray(3 * i, 3 * i + 3))));
        const points = anchors.map(project);
        const pairs = selected.group.kind === "rbe3" ? points.slice(1).map((_, i) => [0, i + 1]) :
          selected.nodes.length === 2 ? [[0, 1]] : points.map((_, i) => [i, (i + 1) % points.length]);
        ctx.save(); ctx.lineJoin = "round"; ctx.lineCap = "round";
        if (!occluders.length && ["quad", "tria"].includes(selected.group.kind) && points.every(Boolean)) {
          ctx.beginPath(); points.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.closePath();
          ctx.fillStyle = "rgba(255,220,82,0.18)"; ctx.fill();
        }
        ctx.beginPath();
        let segments = 0;
        for (const [a, b] of pairs) if (points[a] && points[b]) {
          // The glow is a canvas overlay, so clip its short edge segments
          // against the same opaque depth as IDs instead of drawing X-ray
          // outlines over a solid skin. Only one selected entity is sampled.
          const steps = Math.max(1, Math.min(256, Math.ceil(Math.hypot(points[b].x-points[a].x, points[b].y-points[a].y) / 4)));
          let previous = points[a];
          for (let i = 1; i <= steps; i++) {
            const p = anchors[a].map((v,j) => v + (anchors[b][j]-v) * i / steps);
            const next = project(p), midpoint = anchors[a].map((v,j) => v + (anchors[b][j]-v) * (i-.5) / steps);
            const middle = project(midpoint);
            if (previous && next && middle && !depthIndex().isOccluded({kind:"element",id:state.selectedElement,point:midpoint},middle)) {
              ctx.moveTo(previous.x,previous.y);ctx.lineTo(next.x,next.y);segments++;
            }
            previous = next;
          }
        }
        if (segments) {
          ctx.shadowColor = COLORS.selected; ctx.shadowBlur = 15; ctx.strokeStyle = "rgba(255,215,73,0.9)"; ctx.lineWidth = 7; ctx.stroke();
          ctx.shadowBlur = 0; ctx.strokeStyle = "#fffbea"; ctx.lineWidth = 2; ctx.stroke();
        }
        stats.selectedOutlineSegments = segments;
        ctx.restore();
        const anchor = displayedPoint(state,selected.id,centroid(positions, selected.group.kind === "rbe3" ? selected.nodes.slice(0, 1) : selected.nodes));
        const center = project(anchor);
        if (center && center.x >= 0 && center.x <= width && center.y >= 0 && center.y <= height) {
          const text = elementStyle(selected).name + " " + state.selectedElement;
          if (badge(text, center, COLORS.selected, true, { kind: "element", id: state.selectedElement, point: anchor }))
            stats.selected = { id: state.selectedElement, text, ...center };
        }
      }
      if (showNodes || showElements || showRibs || showStringers || showPanels) {
        const candidates = [...panelLabelCandidates(state,positions),...labelCandidates(state, positions, showNodes, showElements),
          ...physicalLabelCandidates(state, positions, showRibs, showStringers)].map((candidate) => ({ ...candidate, screen: project(candidate.point) }))
          .filter((item) => item.screen && item.screen.x >= 0 && item.screen.x <= width && item.screen.y >= 0 && item.screen.y <= height)
          .sort((a, b) => (b.kind==='panel')-(a.kind==='panel') || a.screen.z - b.screen.z);
        stats.eligible = candidates.length;
        stats.panelsShown=[];
        for (const item of candidates) {
          if (item.kind === "element" && item.id === state.selectedElement && stats.selected) { stats.shown++; continue; }
          if (badge(item.text, item.screen, item.color, false, item)){stats.shown++;if(item.kind==='panel')stats.panelsShown.push(item.id);}
        }
        stats.occlusion = occlusion && occlusion.metrics;
        setStatus(stats.shown + " / " + stats.eligible + " IDs shown" + (stats.occluded ? " · hidden IDs behind opaque surfaces omitted" : "") + (stats.shown + stats.occluded < stats.eligible ? " · zoom in to separate overlapping labels" : ""));
      } else setStatus("");
    }
    function setStatus(text) {
      if (text === lastStatus) return; lastStatus = text;
      const host = control("id-label-status"); if (host) host.textContent = text;
    }
    legend();
    for (const id of ["show-node-ids", "show-element-ids", "id-label-size", "mesh-labels-none", "mesh-labels-ribs", "mesh-labels-stringers", "mesh-labels-both"]) {
      const input = control(id); if (input) input.addEventListener("input", invalidate);
    }
    const observer = scene.onAfterRenderObservable.add(() => render());
    return { render, invalidate, get stats() { return stats; }, dispose() { scene.onAfterRenderObservable.remove(observer); overlay.remove(); } };
  }
  return { create, COLORS, LEGEND, elementStyle, centroid, labelCandidates, physicalLabelCandidates, panelLabelCandidates, visibleElement, opaqueOccluders, buildOcclusionIndex };
});
