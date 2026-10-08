/* Live fuel extent from the form, independent of the generated FE mesh. */
(function (root, factory) {
  const common = typeof module === "object" && module.exports;
  const api = factory(root,
    common ? require("./spar_view.js") : root.WingSparView,
    common ? require("./leading_edge_gaps.js") : root.WingLeadingEdgeGaps,
    common ? require("./rib_layout.js") : root.WingRibLayout);
  if (common) module.exports = api; else root.WingFuelTankView = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (root, Spar, Gaps, Ribs) {
  "use strict";
  const PARAM_KEYS = [...new Set([...Spar.PARAM_KEYS.filter(key => key !== "box.stringer_angle"),
    "box.rib_pitch", "ribs.masters", "fuel.enabled", "fuel.start_rib", "fuel.end_rib", "fuel.disabled_bays"])];
  const instances = new WeakMap();
  const number = value => root.WingNumbers ? root.WingNumbers.format(value, 4) : Number(value.toPrecision(5)).toString();
  const escape = value => String(value).replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));

  function derive(params) {
    // Stringer directions do not define the tank. An unfinished angle field
    // must not prevent previewing otherwise valid spar coordinates.
    const rear = params["box.rear_spar_points"];
    const geometryParams = {...params, "box.stringer_angle": 0};
    if (Array.isArray(rear)) geometryParams["box.rear_spar_points"] = rear.map(point =>
      point && typeof point === "object" ? {...point, stringer_angle: 0} : point);
    const geometry = Spar.derive(geometryParams);
    // Reuse the physical-rib arithmetic (including ties-to-even rounding),
    // without letting unrelated leading-edge gap drafts influence the tank.
    const layout = Gaps.derive({...params, "leading_edge.enabled": false,
      "leading_edge.start_rib": 1, "leading_edge.end_rib": 0,
      "leading_edge.disabled_bays": ""});
    const enabled = params["fuel.enabled"] === true;
    const result = {valid: false, drawable: !!(geometry.valid || geometry.drawable),
      geometry, enabled, ribs: [], selection: null, error: ""};
    let disabled=[];try{disabled=Gaps.parse(params["fuel.disabled_bays"]??"");}catch(e){result.error="Dry / vent bays: "+e.message;}
    if (!geometry.valid) result.error = geometry.error;
    if (!layout.valid) result.error ||= layout.error;
    if (!result.drawable || !layout.valid) return result;
    const first = params["fuel.start_rib"], requestedLast = params["fuel.end_rib"];
    const last = requestedLast === 0 ? layout.ribCount : requestedLast;
    const validRange = Number.isInteger(first) && Number.isInteger(requestedLast) &&
      first >= 1 && requestedLast >= 0 && first < last && last <= layout.ribCount;
    if (!validRange) result.error ||= `Choose tank ribs within 1–${layout.ribCount}, with the last rib after the first. Last rib 0 follows the box end.`;
    const endEta = params["box.end_eta"], etaAt = index => layout.layout ? layout.layout.at(index).eta : (index - 1) / layout.bayCount * endEta;
    Object.assign(result, {bayCount: layout.bayCount, ribCount: layout.ribCount,
      requestedLast, endEta, first, last,disabled});
    if(enabled&&disabled.some(b=>b>layout.bayCount))result.error ||= `Dry / vent bays cannot exceed ${layout.bayCount}, the final physical bay.`;
    const excluded=validRange?disabled.filter(b=>b>=first&&b<last):[],dry=new Set(excluded),regions=[],dryRegions=[];
    if(validRange)for(let bay=first;bay<last;bay++){const list=dry.has(bay)?dryRegions:regions,prior=list.at(-1);if(prior&&prior.last===bay)prior.last=bay+1;else list.push({first:bay,last:bay+1});}
    // Keep large rib counts responsive. Bounding ribs always remain visible.
    const stride = Math.max(1, Math.ceil(layout.bayCount / 100));
    const indices = new Set([1, layout.ribCount]);
    for (let index = 1; index <= layout.ribCount; index += stride) indices.add(index);
    if (validRange) { indices.add(first); indices.add(last); }
    for(const r of [...regions,...dryRegions]){indices.add(r.first);indices.add(r.last);}
    const oriented=Ribs?.derive(geometryParams,{maxRibs:100,include:[...indices]});
    if(oriented&&!oriented.valid)result.error ||= oriented.error;
    if(oriented?.warning)result.error ||= oriented.warning;
    result.ribs = [...indices].sort((a, b) => a - b).map(index => {
      const eta = etaAt(index);
      const rib=oriented?.ribs.find(r=>r.number===index);
      return {index, eta, front: rib?.front||Spar.sample(geometry, 0, eta).position,
        frontEta:rib?.frontEta??eta,rear: rib?.rear||Spar.sample(geometry, 1, eta).position,
        selected: validRange && regions.some(r=>index>=r.first&&index<=r.last),
        boundary: validRange && regions.some(r=>index===r.first||index===r.last)};
    });
    result.sampledRibs = result.ribs.length < layout.ribCount;
    if (!result.error&&geometry.valid && validRange && (!oriented || oriented.valid&&!oriented.warning)) {
      const etaStart = etaAt(first), etaEnd = etaAt(last);
      const knots = [...new Set([etaStart, etaEnd, ...Object.values(geometry.edgeVertices)
        .flat().map(point => point.eta).filter(eta => eta > etaStart && eta < etaEnd)])].sort((a, b) => a - b);
      const firstRib=result.ribs.find(r=>r.index===first),lastRib=result.ribs.find(r=>r.index===last);
      const frontKnots=[...new Set([firstRib.frontEta,lastRib.frontEta,...Object.values(geometry.edgeVertices).flat().map(p=>p.eta).filter(eta=>eta>firstRib.frontEta&&eta<lastRib.frontEta)])].sort((a,b)=>a-b);
      const front = frontKnots.map(eta => Spar.sample(geometry, 0, eta).position);
      const rearPoints = knots.map(eta => Spar.sample(geometry, 1, eta).position);
      const regionPolygon=region=>{const a=result.ribs.find(r=>r.index===region.first),b=result.ribs.find(r=>r.index===region.last),edgeKnots=Object.values(geometry.edgeVertices).flat().map(p=>p.eta);
        const frontEtas=[...new Set([a.frontEta,b.frontEta,...edgeKnots.filter(e=>e>a.frontEta&&e<b.frontEta)])].sort((x,y)=>x-y),rearEtas=[...new Set([a.eta,b.eta,...edgeKnots.filter(e=>e>a.eta&&e<b.eta)])].sort((x,y)=>x-y);
        return{...region,polygon:frontEtas.map(e=>Spar.sample(geometry,0,e).position).concat(rearEtas.reverse().map(e=>Spar.sample(geometry,1,e).position))};};
      result.selection = {first, last, etaStart, etaEnd,
        spanMetres: (etaEnd - etaStart) * geometry.semispan,
        bays: last-first-excluded.length,dryBays:excluded,ignored:disabled.filter(b=>b<first||b>=last),regions:regions.map(regionPolygon),dryRegions:dryRegions.map(regionPolygon),
        polygon: front.concat(rearPoints.slice().reverse())};
      result.valid = true;
    }
    return result;
  }

  function drawing(data) {
    if (!data.drawable) return "";
    const geometry = data.geometry, width = 580, height = 250;
    const range = geometry.bounds.xmax - geometry.bounds.xmin;
    const scale = Math.min(500 / geometry.semispan, 150 / range);
    const left = 40 + (500 - geometry.semispan * scale) / 2;
    const top = 48 + (150 - range * scale) / 2;
    const origin = geometry.points.rootReference;
    const map = point => [left + (point[1] - origin[1]) * scale, top + (point[0] - geometry.bounds.xmin) * scale];
    const polygon = (points, cls) => `<polygon class="${cls}" points="${points.map(point => map(point).join(",")).join(" ")}"/>`;
    const line = (a, b, cls, attributes = "") => { const p = map(a), q = map(b); return `<line class="${cls}" x1="${p[0]}" y1="${p[1]}" x2="${q[0]}" y2="${q[1]}" ${attributes}/>`; };
    const text = (x, y, value, cls = "", attributes = "") => `<text x="${x}" y="${y}" class="${cls}" ${attributes}>${escape(value)}</text>`;
    let svg = `<title>Fuel tank extent before FEM generation</title><desc>Untwisted right half-wing plan. Front and rear spar paths enclose the box. ${data.selection ? `Selected tank extends from physical rib ${data.first} to rib ${data.last}, ETA ${number(data.selection.etaStart)} to ${number(data.selection.etaEnd)}. ${data.enabled ? "Tank calculation is enabled." : "Tank calculation is off; the selected extent is retained."}` : "No valid fuel extent is shown until the rib selection and geometry are valid."}</desc>`;
    svg += polygon(geometry.surfaceRight, "ftv-wing") + polygon(geometry.right, "ftv-box");
    if (data.selection){for(const region of data.selection.regions)svg += polygon(region.polygon, "ftv-tank" + (data.enabled ? "" : " ftv-tank-off"));
      for(const region of data.selection.dryRegions){svg+=polygon(region.polygon,"ftv-dry");const center=region.polygon.reduce((p,q)=>p.map((v,i)=>v+q[i]/region.polygon.length),[0,0,0]),p=map(center);svg+=text(p[0],p[1],region.last===region.first+1?`Dry ${region.first}`:`Dry ${region.first}–${region.last-1}`,"ftv-dry-label",'text-anchor="middle"');}}
    for (const rib of data.ribs) {
      const cls = "ftv-rib" + (rib.selected && data.valid ? " ftv-rib-selected" : "") + (rib.boundary && data.valid ? " ftv-rib-boundary" : "");
      svg += line(rib.front, rib.rear, cls, `data-rib="${rib.index}"`);
    }
    // Spar paths and tank bounds are drawn above the fill and physical ribs.
    for (let edge = 0; edge < 2; edge++) {
      const points = geometry.activeVertices[Spar.POINT_KEYS[edge]];
      svg += `<polyline class="ftv-spar ftv-${edge ? "rear" : "front"}" points="${points.map(point => map(point.position).join(",")).join(" ")}"/>`;
    }
    const labels = new Set([1, data.ribCount]);
    if (data.valid) { labels.add(data.first); labels.add(data.last); }
    for(const rib of data.ribs)if(rib.boundary&&data.valid)labels.add(rib.index);
    for (const rib of data.ribs.filter(rib => labels.has(rib.index))) {
      const p = map(rib.rear);
      // Selected interior bounds receive a separate label tier from endpoints.
      const tier = rib.index !== 1 && rib.index !== data.ribCount ? 36 : 18;
      svg += text(p[0], p[1] + tier, `R ${rib.index}`, rib.boundary && data.valid ? "ftv-bound-label" : "ftv-rib-label", 'text-anchor="middle"');
    }
    svg += text(22, 24, "+x aft ↓", "ftv-axis") + text(width - 20, height - 12, "+y toward tip →", "ftv-axis", 'text-anchor="end"');
    return svg;
  }

  function install(host, {readValues,onViewChange}) {
    const doc = host.ownerDocument;
    instances.get(doc)?.destroy();
    const section = doc.createElement("section");
    section.className = "fuel-tank-view";
    section.setAttribute("aria-label", "Live fuel tank extent");
    section.innerHTML = '<h3>Tank extent</h3><p class="ftv-status" role="status" aria-live="polite"></p><div class="ftv-canvas"><svg id="fuel-tank-preview-svg" viewBox="0 0 580 250" role="img" aria-label="Live fuel tank span preview"></svg></div><div class="ftv-legend"><span><i class="front"></i>Front spar</span><span><i class="rear"></i>Rear spar</span><span><i class="tank"></i>Wet fuel bays</span><span><i class="dry"></i>Dry / vent bays</span></div><p class="ftv-error" role="status" aria-live="polite" hidden></p><p class="ftv-note">Untwisted half-wing plan; numbered ribs are physical ribs, independent of FE subdivisions. Create FEM to calculate volume.</p>';
    host.appendChild(section);
    const status = section.querySelector(".ftv-status"), error = section.querySelector(".ftv-error");
    const canvas = section.querySelector(".ftv-canvas"), svg = section.querySelector("svg");
    svg.dataset.viewKey="fuel-tank";
    const viewport=globalThis.WingSVGViewport?.install(svg,{host:canvas,snapSelector:"polygon,polyline,.ftv-rib",title:"Fuel tank extent",exportName:"fuel-tank.svg",onChange:onViewChange});
    const note = section.querySelector(".ftv-note");
    let destroyed = false;
    function refresh() {
      if (destroyed) return null;
      let data;
      try { data = derive(readValues()); }
      catch (exception) { data = {valid: false, drawable: false, error: exception.message || "Complete the tank and wing inputs to preview the extent."}; }
      error.hidden = data.valid;
      error.textContent = data.error || "";
      canvas.hidden = !data.drawable;
      svg.innerHTML = drawing(data);
      if(data.drawable){const g=data.geometry,range=g.bounds.xmax-g.bounds.xmin,s=Math.min(500/g.semispan,150/range),left=40+(500-g.semispan*s)/2,top=48+(150-range*s)/2;
        viewport?.setMetric?.({origin:{x:left-g.points.rootReference[1]*s,y:top-g.bounds.xmin*s},x:{x:s,y:0},y:{x:0,y:s},unit:"m",gridSpacing:1});}
      viewport?.refresh();
      section.classList.toggle("ftv-disabled", data.enabled === false);
      section.classList.toggle("ftv-invalid", !data.valid);
      section.dataset.valid = String(data.valid);
      if (data.selection) {
        const s = data.selection;
        status.textContent = `${data.enabled ? "Tank" : "Tank off · selected extent"}: ribs ${s.first}–${s.last} of ${data.ribCount} · ${s.bays} ${s.dryBays.length?"wet bays · "+s.dryBays.length+" dry / vent bays":s.bays===1?"bay":"bays"}. ETA ${number(s.etaStart)}–${number(s.etaEnd)} · ${number(s.spanMetres)} m projected span.${s.bays===0?" All selected bays are dry: zero fuel capacity.":""}`;
      } else status.textContent = data.ribCount ? `${data.ribCount} physical ribs · complete a valid tank range to show its extent.` : "Complete the wing and rib geometry to show the tank extent.";
      note.textContent = "Untwisted half-wing plan; numbered ribs are physical ribs, independent of FE subdivisions. " +
        (data.sampledRibs ? "Intermediate rib lines are sampled for clarity; selected boundaries are exact. " : "") +
        (data.selection?.ignored.length?"Dry-bay exclusions outside the selected tank range are retained and ignored: "+data.selection.ignored.join(", ")+". ":"")+"Dry / vent bays contribute no fuel volume, mass, inertia or loads. Create FEM to calculate volume.";
      return data;
    }
    const onEdit = event => { if (PARAM_KEYS.some(key => event.target?.id === "p-" + key)) refresh(); };
    doc.addEventListener("input", onEdit);
    doc.addEventListener("change", onEdit);
    const view = {refresh,viewport,captureView:()=>viewport?.capture(),restoreView:value=>viewport?.restore(value), destroy() {
      if (destroyed) return;
      destroyed = true;
      viewport?.destroy();
      doc.removeEventListener("input", onEdit);
      doc.removeEventListener("change", onEdit);
      section.remove();
      if (instances.get(doc) === view) instances.delete(doc);
    }};
    instances.set(doc, view);
    refresh();
    return view;
  }
  return {PARAM_KEYS, derive, drawing, install};
});
