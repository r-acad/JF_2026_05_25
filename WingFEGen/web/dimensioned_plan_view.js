/* Full-page, dimensioned untwisted plan view with an independently editable image. */
(function (root, factory) {
  const common = typeof module === "object" && module.exports;
  const api = factory(root, common ? require("./planform_view.js") : root.WingPlanformView,
    common ? require("./spar_view.js") : root.WingSparView,
    common ? require("./leading_edge_gaps.js") : root.WingLeadingEdgeGaps,
    common ? require("./rib_layout.js") : root.WingRibLayout,
    common ? require("./svg_viewport.js") : root.WingSVGViewport);
  if (common) module.exports = api; else root.WingDimensionedPlanView = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (root, Planform, Spar, Gaps, Ribs, Viewport) {
  "use strict";
  const PARAM_KEYS = [...new Set([...Spar.PARAM_KEYS, ...Gaps.PARAM_KEYS, "box.stringer_pitch", "fuel.enabled", "fuel.start_rib", "fuel.end_rib", "fuel.disabled_bays"])];
  const MAX_IMAGE_BYTES = 8 * 1024 * 1024, NS = "http://www.w3.org/2000/svg";
  const defaults = () => ({ version: 1, mirror: false, theme: "dark", showSpars: true, showRibs: true, showRibLabels: true,
    opacity: .55, image: null, transform: { x: 0, y: 0, scale: 1 }, viewport: { x: 0, y: 0, scale: 1 }, ...Viewport.defaultsTools() });
  const finite = (value, low, high) => typeof value === "number" && Number.isFinite(value) && value >= low && value <= high;
  const object = value => !!value && typeof value === "object" && !Array.isArray(value);
  const allowedKeys = (value, names, label) => { if (Object.keys(value).some(key => !names.includes(key))) throw new Error("Unsupported " + label + " setting."); };
  function validateState(value) {
    const result = defaults(); if (value == null) return result;
    if (!object(value)) throw new Error("Plan view settings must be an object.");
    allowedKeys(value, ["version", "mirror", "theme", "showSpars", "showRibs", "showRibLabels", "opacity", "image", "transform", "viewport", "grid", "snap", "measurements"], "plan view");
    Object.assign(result,Viewport.validateToolsState({grid:value.grid,snap:value.snap,measurements:value.measurements}));
    if (value.version !== undefined && value.version !== 1) throw new Error("Unsupported plan view settings version.");
    if (value.theme !== undefined) {
      if (!["dark", "white"].includes(value.theme)) throw new Error("Plan view background must be dark or white.");
      result.theme = value.theme;
    }
    for (const key of ["mirror", "showSpars", "showRibs", "showRibLabels"]) {
      if (value[key] === undefined) continue;
      if (typeof value[key] !== "boolean") throw new Error("Plan view " + key + " must be true or false.");
      result[key] = value[key];
    }
    if (value.opacity !== undefined) {
      if (!finite(value.opacity, 0, 1)) throw new Error("Plan view image opacity must be between 0 and 1.");
      result.opacity = value.opacity;
    }
    for (const property of ["transform", "viewport"]) if (value[property] !== undefined) {
      const label = property === "viewport" ? "viewport" : "image transform";
      if (!object(value[property])) throw new Error("Plan view " + label + " must be an object.");
      allowedKeys(value[property], ["x", "y", "scale"], "plan view " + label);
      for (const key of ["x", "y", "scale"]) {
        const v = value[property][key] === undefined ? result[property][key] : value[property][key];
        if (!finite(v, key === "scale" ? 1e-6 : -1e7, key === "scale" ? 1e4 : 1e7)) throw new Error("Plan view " + label + " " + key + " is outside the supported range.");
        result[property][key] = v;
      }
    }
    if (value.image != null) {
      const im = value.image;
      if (!object(im) || typeof im.name !== "string" || im.name.length > 512 || typeof im.dataUrl !== "string") throw new Error("Plan view image metadata is invalid.");
      allowedKeys(im, ["name", "dataUrl", "width", "height"], "plan view image");
      if (!Number.isInteger(im.width) || !Number.isInteger(im.height) || im.width < 1 || im.width > 32768 || im.height < 1 || im.height > 32768 || im.width * im.height > 134217728) throw new Error("Plan view image dimensions are invalid or too large.");
      if (im.dataUrl.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 64) throw new Error("Plan view images must be no larger than 8 MiB.");
      const match = /^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$/.exec(im.dataUrl);
      if (!match || match[2].length % 4 !== 0) throw new Error("Plan view image must be an embedded PNG, JPEG or WebP image.");
      const bytes = match[2].length * 3 / 4 - (match[2].endsWith("==") ? 2 : match[2].endsWith("=") ? 1 : 0);
      if (bytes > MAX_IMAGE_BYTES) throw new Error("Plan view images must be no larger than 8 MiB.");
      const header = root.atob(match[2].slice(0, 32));
      const signature = match[1] === "png" ? header.startsWith("\x89PNG\r\n\x1a\n") : match[1] === "jpeg" ? header.startsWith("\xff\xd8\xff") : header.startsWith("RIFF") && header.slice(8, 12) === "WEBP";
      if (!signature) throw new Error("Plan view image content does not match its PNG, JPEG or WebP format.");
      result.image = { name: im.name, dataUrl: im.dataUrl, width: im.width, height: im.height };
    }
    return result;
  }
  const number = value => root.WingNumbers ? root.WingNumbers.format(value, 4) : Number(value.toPrecision(6)).toString();
  function projection(data, mirror = false) {
    const minimumY = mirror ? data.bounds.ymin : data.points.rootReference[1];
    const width = mirror ? data.span : data.semispan, height = data.bounds.xmax - data.bounds.xmin;
    const scale = Math.min(700 / width, 330 / height), left = 130 + (700 - width * scale) / 2, top = 125 + (330 - height * scale) / 2;
    return { scale, left, top, map: point => [left + (point[1] - minimumY) * scale, top + (point[0] - data.bounds.xmin) * scale] };
  }
  function edgeAt(planform, edge, eta) {
    const points = planform.edgeVertices[Planform.POINT_KEYS[edge]];
    let index = 1; while (index < points.length - 1 && points[index].eta < eta) index++;
    const a = points[index - 1], b = points[index], t = (eta - a.eta) / (b.eta - a.eta);
    return a.position.map((v, i) => v + t * (b.position[i] - v));
  }
  function derive(params) {
    const planform = Planform.derive(params), spars = Spar.derive(params);
    if (!planform.valid && !planform.drawable) return { valid: false, drawable: false, error: planform.error, planform, spars, ribs: [] };
    const physical = Gaps.derive({ "leading_edge.start_rib": 1, "leading_edge.end_rib": 0, "leading_edge.disabled_bays": "", ...params });
    const ribs = [], oriented = Ribs?.leading(params,Ribs.derive(params,{maxRibs:500})), errors = [planform.valid ? "" : planform.error, spars.valid ? "" : spars.error, physical.valid ? "" : physical.error,oriented&&!oriented.valid?oriented.error:""].filter(Boolean);
    if (physical.valid && (spars.valid || spars.drawable)) {
      const stride = Math.max(1, Math.ceil(physical.bayCount / 500)), indices = oriented?.ribs.length?oriented.ribs.map(r=>r.number-1):[];
      if(!indices.length)for (let bay = 0; bay <= physical.bayCount; bay += stride) indices.push(bay);
      if (indices.at(-1) !== physical.bayCount) indices.push(physical.bayCount);
      const disabled = new Set(physical.disabled);
      const activeBay = bay => physical.enabled && bay >= physical.start && bay < physical.end && !disabled.has(bay);
      for (const bay of indices) {
        const rib=oriented?.ribs.find(r=>r.number===bay+1),eta = rib?.eta??physical.layout?.at(bay+1).eta??params["box.end_eta"] * bay / physical.bayCount;
        ribs.push({ ...rib,number: bay + 1, eta, front: rib?.front||Spar.sample(spars, 0, eta).position,
          rear: rib?.rear||Spar.sample(spars, 1, eta).position, leading: rib?.leading||edgeAt(planform, 0, eta),
          noseActive: activeBay(bay) || activeBay(bay + 1) });
      }
    }
    return { valid: errors.length === 0, drawable: true, error: [...new Set(errors)].join(" "), planform, spars, physical, ribs,
      sampledRibs: physical.valid && ribs.length < physical.ribCount,generated:!!oriented?.generated,warning:oriented?.warning||"" };
  }
  // The refined outline is piecewise linear in physical coordinates. Its area
  // and chord-squared integrals are already evaluated exactly by Planform.
  function properties(params, data = derive(params)) {
    const p = data.planform;
    if (!p?.drawable) return { valid:false, error:data.error || "Enter valid planform dimensions.", wing:[], model:[] };
    const actual = p.valid, sweep = (leading, trailing, fraction) => Math.atan2((leading[1][0] + fraction * (trailing[1][0] - leading[1][0])) - (leading[0][0] + fraction * (trailing[0][0] - leading[0][0])), p.semispan) * 180 / Math.PI;
    const baseLE = [p.points.rootLE,p.points.tipLE], baseTE = [p.points.rootTE,p.points.tipTE], refinedLE = [edgeAt(p,0,0),edgeAt(p,0,1)], refinedTE = [edgeAt(p,1,0),edgeAt(p,1,1)];
    const wing = [], row = (key,label,unit,base,refined=base) => wing.push({key,label,unit,base,refined:actual?refined:null});
    row("area","Wing area S","m²",p.area,p.actualArea);
    row("half_area","Half-wing area","m²",p.halfArea,p.actualHalfArea);
    row("span","Full span b","m",p.span); row("semispan","Half-span s","m",p.semispan);
    row("aspect_ratio","Aspect ratio b²/S","",p.aspectRatio,p.actualAspectRatio);
    row("root_chord","Root chord","m",p.rootChord,p.actualRootChord);
    row("tip_chord","Tip chord","m",p.tipChord,p.actualTipChord);
    row("taper","Taper c tip / c root","",p.taper,p.actualTaper);
    row("mac","Mean aerodynamic chord","m",p.mac,p.actualMAC);
    for(const [fraction,key,label] of [[0,"leading_sweep","Leading-edge sweep"],[.25,"quarter_sweep","Quarter-chord sweep"],[.5,"half_sweep","Half-chord sweep"],[1,"trailing_sweep","Trailing-edge sweep"]]) row(key,label,"°",sweep(baseLE,baseTE,fraction),sweep(refinedLE,refinedTE,fraction));
    const model = [], info = (key,label,value,unit="") => model.push({key,label,value,unit});
    info("sweep","Reference sweep",p.sweepDeg,"°");info("sweep_reference","Sweep reference x/c",p.sweepRef);
    info("dihedral","Dihedral",p.dihedralDeg,"°");info("twist","Tip twist / root",p.twistTipDeg,"°");info("twist_axis","Twist axis x/c",p.twistAxis);
    ["X","Y","Z"].forEach((axis,i)=>info("root_"+axis.toLowerCase(),"Root reference "+axis,p.points.rootReference[i],"m"));
    if(p.boxEnd){info("box_end","Box end η",p.boxEnd.eta);info("box_span","Box projected half-span",p.boxEnd.eta*p.semispan,"m");}
    if(data.physical?.valid){info("ribs","Physical ribs",data.physical.ribCount);info("bays","Physical rib bays",data.physical.bayCount);}
    if(Number.isFinite(params["box.rib_pitch"]))info("rib_pitch","Root outgoing rib pitch",params["box.rib_pitch"],"m");
    if(Number.isFinite(params["box.stringer_pitch"]))info("stringer_pitch","Root stringer pitch",params["box.stringer_pitch"],"m");
    for(const [name,label] of [["front","Front"],["rear","Rear"]]){if(Number.isFinite(params["box."+name+"_spar_xc"]))info(name+"_spar",label+" nominal spar x/c",params["box."+name+"_spar_xc"]);info(name+"_kinks",label+" spar control points",params["box."+name+"_spar_points"]?.length||0);}
    if(data.physical?.valid){const physical=data.physical;info("leading_edge","Leading-edge mesh",physical.enabled?`${physical.activeCount} active bays; ribs ${physical.start}–${physical.end}`:"Off");}
    if(params["fuel.enabled"]===true&&data.physical?.valid){const first=params["fuel.start_rib"]??1,last=params["fuel.end_rib"]===0||params["fuel.end_rib"]===undefined?data.physical.ribCount:params["fuel.end_rib"],valid=Number.isInteger(first)&&Number.isInteger(last)&&first>=1&&last>first&&last<=data.physical.ribCount;
      let disabled=[],dryError="";try{disabled=Gaps.parse(params["fuel.disabled_bays"]??"");if(disabled.some(b=>b>=data.physical.ribCount))dryError="Invalid dry / vent bay number";}catch(e){dryError=e.message;}
      const excluded=disabled.filter(b=>b>=first&&b<last);info("fuel","Fuel tank",dryError?dryError:valid?`Ribs ${first}–${last} · ${last-first-excluded.length} ${excluded.length?"wet bays · "+excluded.length+" dry / vent bays":"bays"}`:"Invalid rib range");if(disabled.length)info("fuel_dry","Dry / vent bay IDs",disabled.join(", "));
      if(valid&&data.physical.layout){const a=data.physical.layout.at(first).eta,b=data.physical.layout.at(last).eta;info("fuel_eta","Fuel rear-spar η range",`${number(a)}–${number(b)}`);}}
    else info("fuel","Fuel tank",params["fuel.enabled"]===true?"Needs a valid rib layout":"Off");
    return {valid:true,refinedValid:actual,wing,model};
  }
  function overlay(data, settings, id = "dimensioned-plan") {
    if (!data.drawable) return "";
    const p = data.planform, transform = projection(p, settings.mirror), map = transform.map;
    const mirror = point => [point[0], 2 * p.points.rootReference[1] - point[1], point[2]];
    const polyline = (positions, className, extra = "") => `<polyline points="${positions.map(point => map(point).join(",")).join(" ")}" class="${className}" ${extra}/>`;
    let svg = Planform.drawing({ ...p, valid: true }, { mirror: settings.mirror, id });
    if (settings.showRibs) {
      const labelStride = Math.max(1, Math.ceil((data.physical?.ribCount || 1) / 36));
      for (const rib of data.ribs) {
        const positions = [rib.front, rib.rear];
        svg += polyline(positions, "dpv-rib", `data-rib="${rib.number}" data-eta="${rib.eta}"`);
        if(data.generated)for(const side of["upper","lower"])if(Array.isArray(rib[side])&&rib[side].length>1){svg+=polyline(rib[side],"dpv-rib dpv-surface-rib",`data-${side}-rib="${rib.number}"`);if(settings.mirror&&rib.eta>0)svg+=polyline(rib[side].map(mirror),"dpv-rib dpv-surface-rib dpv-mirrored");}
        if (settings.mirror && rib.eta > 0) svg += polyline(positions.map(mirror), "dpv-rib dpv-mirrored", `data-mirror-rib="${rib.number}"`);
        if(rib.noseActive){const nose=[rib.leading,rib.front],cls="dpv-rib dpv-leading"+(rib.leFallback?" dpv-fallback":"");svg+=polyline(nose,cls,`data-leading-rib="${rib.number}"`);if(settings.mirror&&rib.eta>0)svg+=polyline(nose.map(mirror),cls+" dpv-mirrored");}
        if (settings.showRibLabels && ((rib.number - 1) % labelStride === 0 || rib.number === data.physical?.ribCount)) {
          const xy = map(rib.rear); svg += `<text x="${xy[0]}" y="${xy[1] + 14}" class="dpv-rib-label" text-anchor="middle">R${rib.number}</text>`;
        }
      }
    }
    if (settings.showSpars && (data.spars.valid || data.spars.drawable)) {
      for (let edge = 0; edge < 2; edge++) {
        const positions = data.spars.activeVertices[Spar.POINT_KEYS[edge]].map(point => point.position), name = edge ? "rear" : "front";
        svg += polyline(positions, "dpv-spar dpv-" + name, `data-spar="${name}"`);
        if (settings.mirror) svg += polyline(positions.map(mirror), "dpv-spar dpv-" + name + " dpv-mirrored");
      }
    }
    return svg;
  }
  function install(host, options = {}) {
    const doc = host.ownerDocument, win = doc.defaultView;
    let state = defaults(), drag = null, destroyed = false, loading = false, loadToken = 0, loadError = "", wheelTimer = null, cachedData = null, cachedParams = {}, renderedImageUrl = null;
    let screenMarkers = [], screenLabels = [], screenCircles = [], drawingTools = null;
    host.classList.add("dimensioned-plan-view");
    host.innerHTML = `<div class="dpv-toolbar"><div class="dpv-title"><h2>Dimensioned plan view</h2></div><div class="dpv-image-tools">
      <button type="button" data-dpv="fit-view" title="Fit the whole drawing without changing the image alignment">Fit view</button>
      <button type="button" data-dpv="upload" title="Load a PNG, JPEG or WebP reference image">Load image&hellip;</button><input type="file" data-dpv="file" accept="image/png,image/jpeg,image/webp" hidden>
      <button type="button" data-dpv="image-tools" aria-expanded="false" aria-controls="dpv-image-settings" title="Image opacity, scale and alignment">Image tools</button>
      <button type="button" data-dpv="theme" aria-pressed="false" title="Switch drawing to a white background">White background</button>
      <button type="button" data-dpv="export" title="Export the visible drawing, annotations and embedded reference image as an SVG file">Export SVG</button>
      <button type="button" data-dpv="properties" aria-expanded="true" title="Show or hide planform properties">Properties</button>
      <button type="button" data-dpv="help" aria-expanded="false" aria-label="Plan view and image instructions">? Help</button></div></div>
      <div class="dpv-options"><label><input type="checkbox" data-dpv="mirror" autocomplete="off">Mirror opposite half</label><label><input type="checkbox" data-dpv="showSpars">Spars</label><label><input type="checkbox" data-dpv="showRibs">Physical ribs</label><label><input type="checkbox" data-dpv="showRibLabels">Rib numbers</label><span class="dpv-legend"><i class="front"></i>Front spar <i class="rear"></i>Rear spar <i class="rib"></i>Rib</span></div>
      <div class="dpv-image-settings" id="dpv-image-settings" hidden><label>Image opacity <input type="range" min="0" max="1" step="0.05" data-dpv="opacity"></label><div class="dpv-scale"><button type="button" data-dpv="smaller" aria-label="Scale image down">&minus;</button><label>Image scale <input type="number" min="0.01" max="1000000" step="1" data-dpv="scale">%</label><button type="button" data-dpv="larger" aria-label="Scale image up">+</button></div><button type="button" data-dpv="reset">Reset image alignment</button><button type="button" data-dpv="remove">Remove image</button></div>
      <div class="dpv-help" hidden><b>Plan View.</b> This separate browser tab can be dragged to another monitor. Drawing coordinates and dimensions use metres.<br><b>Live geometry.</b> Dimensions describe the base trapezoid. The outline follows the edge points; green/orange lines show the independent spar paths. Master and secondary rib positions and angles follow the Ribs editor. Rib numbers are physical ribs, so shell refinements do not add ribs. Current generated ribs use their actual surface projection; while parameters are changing, the preview uses the untwisted reference paths. Red leading-edge ribs indicate that the requested direction missed the surface and flight direction was used. Leading-edge rib extensions respect the selected rib range and pylon gaps. The opposite half is a mirrored reference only. Drawing strokes and arrowheads remain thin at every zoom; labels keep a readable screen size.<br><b>Navigation.</b> Drag with the left or middle mouse button to pan the drawing and background together. Use the wheel to zoom both under the pointer. Hold <b>Alt</b> for 10&times; finer wheel or +/&minus; zoom; Alt also works with Ctrl/Cmd for fine image-only scaling and with the image +/&minus; buttons. Numeric scale entry remains exact. <b>Fit view</b> restores the overall view without changing image alignment.<br><b>Image alignment.</b> Load a PNG, JPEG or WebP image (up to 8 MiB). Hold <b>Ctrl</b> (Windows/Linux) or <b>Cmd</b> (Mac) while dragging or using the wheel to move or scale only the image. The Image tools controls and Reset image alignment affect only the image. Arrow keys and +/&minus; navigate the whole view; hold Ctrl/Cmd to adjust the image instead. Shift makes larger arrow steps. Escape cancels a drag. Image data, image alignment, background theme and overall view placement are included in Save Study and Save TOML.<br><b>Grid and dimensions.</b> Grid spacing and distance labels use metres. Horizontal dimensions measure global y; vertical dimensions measure global x. Select Distance, Horizontal or Vertical and click two points. For Angle, click endpoint, vertex, endpoint. Then move the label and dimension lines and click to place them. Enable Snap geometry for visible endpoints and edges within 10 screen pixels; images, axes and annotations are excluded. Labels are positioned freely. Use Navigate or Escape to return to panning; the middle button can pan while measuring. Grid and snapping settings, dimension anchors and label positions are saved with the Study and TOML. Their picked locations stay in physical global coordinates when geometry changes.<br><b>Export SVG.</b> Exports the current visible view, including the background image, selected layers and background colour. Use Fit view first to export the complete drawing.<p class="dpv-image-details"></p><p class="dpv-metrics" aria-live="polite"></p></div>
      <p class="dpv-image-status" role="status" hidden></p><p class="dpv-error" role="alert" hidden></p><div class="dpv-content"><div class="dpv-stage planform-view-canvas"><svg viewBox="0 0 1000 630" tabindex="0" aria-label="Dimensioned wing plan view and optional reference image" role="img"></svg></div><aside class="dpv-properties" aria-label="Planform and model properties"><h3>Planform properties</h3><p class="dpv-property-basis">Untwisted XY projection. Full-wing values include the mirrored half; the FE model covers one half up to Box end &eta;.</p><div class="dpv-property-tables"></div><p class="dpv-property-note">Refined area and MAC integrate the piecewise straight outline exactly. MAC = &int;c&sup2; dy / &int;c dy. Sweep values are root-to-tip secants, not local angles at kinks. Drawing chord dimensions label the basic trapezoid. Rib numbers refer to physical ribs; refinement adds no physical ribs.</p></aside></div>`;
    const get = name => host.querySelector(`[data-dpv="${name}"]`), svg = host.querySelector("svg"), error = host.querySelector(".dpv-error");
    // Browser form restoration must not override validated Study/TOML state.
    get("mirror").defaultChecked = false;
    get("mirror").checked = state.mirror;
    const changed = () => { if (!destroyed) options.onChange?.(); };
    const fit = () => state.image ? Math.min(700 / state.image.width, 330 / state.image.height) : 1;
    const clamp = (value, a, b) => Math.max(a, Math.min(b, value));
    // Imports/uploads are validated once. Capturing immutable image data does
    // not need to rescan megabytes of base64 on every completed image gesture.
    function capture() { return { ...state, image: state.image ? { ...state.image } : null, transform: { ...state.transform }, viewport: { ...state.viewport }, ...Viewport.validateToolsState(drawingTools?drawingTools.capture():{grid:state.grid,snap:state.snap,measurements:state.measurements}) }; }
    function rememberScreenPresentation(geometry) {
      screenMarkers = Array.from(geometry.querySelectorAll("marker")).map(element => {
        const width = Number(element.getAttribute("markerWidth")) || 7, height = Number(element.getAttribute("markerHeight")) || 7;
        element.setAttribute("markerUnits", "userSpaceOnUse"); element.setAttribute("viewBox", `0 0 ${width} ${height}`);
        element.setAttribute("overflow", "visible"); return { element, width, height };
      });
      screenLabels = Array.from(geometry.querySelectorAll("text")).map(element => ({ element, transform: element.getAttribute("transform") || "",
        x: Number(element.getAttribute("x")) || 0, y: Number(element.getAttribute("y")) || 0, size: parseFloat(win.getComputedStyle(element).fontSize) || 15 }));
      screenCircles = Array.from(geometry.querySelectorAll("circle")).map(element => ({ element, radius: Number(element.getAttribute("r")) || 0 }));
    }
    function updateScreenPresentation() {
      if (destroyed) return;
      const matrix = svg.getScreenCTM(), baseScale = matrix ? Math.hypot(matrix.a, matrix.b) : 0, scale = baseScale * state.viewport.scale;
      if (!(scale > 0) || !Number.isFinite(scale)) return;
      for (const { element, width, height } of screenMarkers) { element.setAttribute("markerWidth", String(width / scale)); element.setAttribute("markerHeight", String(height / scale)); }
      for (const { element, radius } of screenCircles) element.setAttribute("r", String(radius / scale));
      for (const { element, transform, x, y, size } of screenLabels) {
        const factor = Math.max(11, size * baseScale) / (size * scale);
        element.setAttribute("transform", `${transform} translate(${x} ${y}) scale(${factor}) translate(${-x} ${-y})`);
      }
      drawingTools?.render();
    }
    function renderProperties() {
      const tables=host.querySelector(".dpv-property-tables"),values=properties(cachedParams,cachedData);
      tables.replaceChildren();
      const create=(tag,text)=>{const el=doc.createElement(tag);if(text!==undefined)el.textContent=text;return el;};
      if(!values.valid){tables.append(create("p",values.error));return;}
      const format=value=>typeof value==="number"?number(value):value==null?"—":String(value);
      const table=create("table"),head=create("thead"),tr=create("tr");
      for(const text of["Parameter","Trapezoid","Refined"]){const cell=create("th",text);cell.scope="col";tr.append(cell);}head.append(tr);table.append(head);
      const body=create("tbody");for(const row of values.wing){const tr=create("tr");tr.dataset.property=row.key;const label=create("th",row.label+(row.unit?" ("+row.unit+")":""));label.scope="row";tr.append(label);for(const key of["base","refined"]){const cell=create("td",format(row[key]));cell.dataset.kind=key;if(typeof row[key]==="number")cell.dataset.value=String(row[key]);tr.append(cell);}body.append(tr);}table.append(body);tables.append(table);
      if(!values.refinedValid)tables.append(create("p","Refined values are unavailable until the outline is valid."));
      tables.append(create("h3","Model definition"));const model=create("table"),modelBody=create("tbody");for(const row of values.model){const tr=create("tr");tr.dataset.modelProperty=row.key;const label=create("th",row.label);label.scope="row";const value=create("td",format(row.value)+(row.unit?" "+row.unit:""));tr.append(label,value);modelBody.append(tr);}model.append(modelBody);tables.append(model);
    }
    function render(updateGeometry = true) {
      if (destroyed) return;
      if (updateGeometry || !cachedData) try { cachedParams = options.readValues?.() || {}; cachedData = derive(cachedParams); } catch (e) { cachedData = { valid: false, drawable: false, error: e.message, ribs: [] }; }
      const data = cachedData;
      let scene = svg.querySelector(".dpv-scene");
      if (!scene) { scene = doc.createElementNS(NS, "g"); scene.setAttribute("class", "dpv-scene"); svg.appendChild(scene); }
      scene.setAttribute("transform", `translate(${state.viewport.x} ${state.viewport.y}) scale(${state.viewport.scale})`);
      let image = scene.querySelector(".dpv-background-image");
      if (state.image) {
        if (!image) { image = doc.createElementNS(NS, "image"); image.setAttribute("class", "dpv-background-image"); scene.prepend(image); }
        if (renderedImageUrl !== state.image.dataUrl) { image.setAttribute("href", state.image.dataUrl); renderedImageUrl = state.image.dataUrl; }
        image.setAttribute("width", String(state.image.width)); image.setAttribute("height", String(state.image.height));
        image.setAttribute("transform", `translate(${state.transform.x} ${state.transform.y}) scale(${state.transform.scale})`);
        image.setAttribute("opacity", String(state.opacity));
      } else { image?.remove(); renderedImageUrl = null; }
      let geometry = scene.querySelector(".dpv-geometry");
      if (!geometry) { geometry = doc.createElementNS(NS, "g"); geometry.setAttribute("class", "dpv-geometry"); scene.appendChild(geometry); }
      if (updateGeometry || !geometry.childNodes.length) { geometry.innerHTML = overlay(data, state); rememberScreenPresentation(geometry); }
      if(updateGeometry&&data.drawable&&drawingTools){const transform=projection(data.planform,state.mirror),minimumY=state.mirror?data.planform.bounds.ymin:data.planform.points.rootReference[1];drawingTools.setMetric({origin:{x:transform.left-minimumY*transform.scale,y:transform.top-data.planform.bounds.xmin*transform.scale},x:{x:transform.scale,y:0},y:{x:0,y:transform.scale},unit:"m",horizontalLabel:"Δy",verticalLabel:"Δx"});}
      updateScreenPresentation();
      if(updateGeometry)renderProperties();
      for (const name of ["mirror", "showSpars", "showRibs", "showRibLabels"]) get(name).checked = state[name];
      get("opacity").value = String(state.opacity); get("opacity").disabled = !state.image;
      get("scale").value = number(state.transform.scale / fit() * 100);
      for (const name of ["scale", "smaller", "larger", "reset"]) get(name).disabled = !state.image || loading;
      get("remove").disabled = !state.image || loading; get("upload").disabled = loading;
      svg.classList.toggle("dpv-dragging", !!drag); svg.classList.toggle("dpv-image-only", drag?.target === "transform");
      const imageStatus = host.querySelector(".dpv-image-status");
      imageStatus.hidden = !loading; imageStatus.textContent = loading ? "Reading background image..." : "";
      host.querySelector(".dpv-image-details").textContent = state.image ? `${state.image.name} | ${state.image.width} x ${state.image.height} px | View ${number(state.viewport.scale * 100)}%` : "";
      host.dataset.theme = state.theme;
      get("theme").textContent = state.theme === "white" ? "Dark background" : "White background";
      get("theme").title = `Switch drawing to a ${state.theme === "white" ? "dark" : "white"} background`;
      get("theme").setAttribute("aria-pressed", String(state.theme === "white"));
      error.textContent = loadError || data.error || data.warning || ""; error.hidden = !error.textContent;
      const p = data.planform, physical = data.physical;
      host.querySelector(".dpv-metrics").textContent = p?.drawable ? `Base area ${number(p.area)} m² · Refined area ${number(p.actualArea)} m² · Half-span ${number(p.semispan)} m${physical?.valid ? ` · ${physical.ribCount} physical ribs / ${physical.bayCount} bays` : ""}${data.sampledRibs ? ` · Showing ${data.ribs.length} evenly sampled ribs` : ""}${!data.valid ? " · Invalid geometry: correct parameters before FEM generation" : ""}` : "Enter valid base dimensions to draw the plan view. Image placement remains available.";
    }
    function stopDrag(cancel = false) {
      if (!drag) return; const current = drag; drag = null;
      if (cancel) state[current.target] = current.original;
      try { svg.releasePointerCapture(current.pointerId); } catch (_) { /* Pointer may already be released. */ }
      render(false); if (!cancel) changed();
    }
    function local(event) { const point = svg.createSVGPoint(); point.x = event.clientX; point.y = event.clientY; return point.matrixTransform(svg.getScreenCTM().inverse()); }
    const gestureTarget = event => event.ctrlKey || event.metaKey ? "transform" : "viewport";
    function zoom(target, factor, canvasAnchor = { x: 500, y: 300 }) {
      if ((target === "transform" && !state.image) || !Number.isFinite(factor) || factor <= 0) return;
      const anchor = target === "transform" ? { x: (canvasAnchor.x - state.viewport.x) / state.viewport.scale, y: (canvasAnchor.y - state.viewport.y) / state.viewport.scale } : canvasAnchor;
      const before = state[target], scale = clamp(before.scale * factor, 1e-6, 1e4), ratio = scale / before.scale;
      state[target] = { x: clamp(anchor.x - (anchor.x - before.x) * ratio, -1e7, 1e7), y: clamp(anchor.y - (anchor.y - before.y) * ratio, -1e7, 1e7), scale }; render(false);
    }
    function resetImage(notify = true) { if (!state.image) return; const scale = fit(); state.transform = { x: 130 + (700 - state.image.width * scale) / 2, y: 125 + (330 - state.image.height * scale) / 2, scale }; render(false); if (notify) changed(); }
    for (const name of ["mirror", "showSpars", "showRibs", "showRibLabels"]) get(name).onchange = () => { state[name] = get(name).checked; render(); changed(); };
    get("opacity").oninput = () => { state.opacity = Number(get("opacity").value); render(false); };
    get("opacity").onchange = changed;
    get("fit-view").onclick = () => { stopDrag(true); state.viewport = { x: 0, y: 0, scale: 1 }; render(false); changed(); };
    get("reset").onclick = () => resetImage();
    get("remove").onclick = () => { stopDrag(true); state.image = null; state.transform = { x: 0, y: 0, scale: 1 }; loadError = ""; render(false); changed(); };
    get("image-tools").onclick = () => { const settings = host.querySelector(".dpv-image-settings"); settings.hidden = !settings.hidden; get("image-tools").setAttribute("aria-expanded", String(!settings.hidden)); };
    get("theme").onclick = () => { state.theme = state.theme === "dark" ? "white" : "dark"; render(false); changed(); };
    get("export").onclick = () => {
      try { root.WingSVGViewport.downloadSVG(svg, { theme: state.theme, filename: "wing-plan-view.svg" }); }
      catch (e) { loadError = "SVG export failed: " + e.message; render(false); }
    };
    get("properties").onclick = () => { const panel=host.querySelector(".dpv-properties");panel.hidden=!panel.hidden;get("properties").setAttribute("aria-expanded",String(!panel.hidden));host.classList.toggle("dpv-properties-hidden",panel.hidden);updateScreenPresentation(); };
    get("help").onclick = () => { const help = host.querySelector(".dpv-help"); help.hidden = !help.hidden; get("help").setAttribute("aria-expanded", String(!help.hidden)); };
    for (const [name, factor] of [["smaller", 1 / 1.1], ["larger", 1.1]]) get(name).onclick = event => { zoom("transform", Math.pow(factor, event.altKey ? .1 : 1)); changed(); };
    get("scale").onchange = () => { const percent = Number(get("scale").value); if (state.image && Number.isFinite(percent) && percent > 0) { zoom("transform", percent / 100 * fit() / state.transform.scale); changed(); } else render(false); };
    get("upload").onclick = () => get("file").click();
    get("file").onchange = async () => {
      const file = get("file").files[0]; if (!file) return; const token = ++loadToken;
      loadError = ""; loading = true; stopDrag(true); render(false);
      try {
        if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) throw new Error("Choose a PNG, JPEG or WebP image.");
        if (file.size > MAX_IMAGE_BYTES) throw new Error("Plan view images must be no larger than 8 MiB.");
        const dataUrl = await new Promise((resolve, reject) => { const reader = new win.FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = () => reject(new Error("The image file could not be read.")); reader.readAsDataURL(file); });
        const size = await new Promise((resolve, reject) => { const image = new win.Image(); image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight }); image.onerror = () => reject(new Error("The image could not be decoded. Choose a valid PNG, JPEG or WebP file.")); image.src = dataUrl; });
        if (destroyed || token !== loadToken) return;
        state = validateState({ ...state, image: { name: file.name, dataUrl, ...size } }); resetImage(false); changed();
      } catch (e) { if (!destroyed && token === loadToken) loadError = e.message; }
      finally { if (!destroyed && token === loadToken) { loading = false; get("file").value = ""; render(false); } }
    };
    svg.addEventListener("pointerdown", event => { const target = gestureTarget(event); if (![0, 1].includes(event.button) || (target === "transform" && !state.image)) return; event.preventDefault(); svg.focus(); drag = { pointerId: event.pointerId, target, start: local(event), original: { ...state[target] }, divisor: target === "transform" ? state.viewport.scale : 1 }; svg.setPointerCapture(event.pointerId); render(false); });
    svg.addEventListener("pointermove", event => { if (!drag || event.pointerId !== drag.pointerId) return; const point = local(event); state[drag.target] = { ...drag.original, x: clamp(drag.original.x + (point.x - drag.start.x) / drag.divisor, -1e7, 1e7), y: clamp(drag.original.y + (point.y - drag.start.y) / drag.divisor, -1e7, 1e7) }; render(false); });
    svg.addEventListener("pointerup", () => stopDrag()); svg.addEventListener("pointercancel", () => stopDrag(true)); svg.addEventListener("lostpointercapture", () => { if (drag) stopDrag(true); });
    svg.addEventListener("wheel", event => { event.preventDefault(); const target = gestureTarget(event); if (target === "transform" && !state.image) return; zoom(target, Math.exp(-event.deltaY * .0015 * (event.altKey ? .1 : 1)), local(event)); clearTimeout(wheelTimer); wheelTimer = setTimeout(changed, 120); }, { passive: false });
    svg.addEventListener("keydown", event => {
      if (event.key === "Escape") { event.preventDefault(); stopDrag(true); return; }
      const target = gestureTarget(event); if (target === "transform" && !state.image) return;
      if (["+", "=", "-", "_"].includes(event.key)) { event.preventDefault(); zoom(target, Math.pow(event.key === "-" || event.key === "_" ? 1 / 1.1 : 1.1, event.altKey ? .1 : 1)); changed(); return; }
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
      event.preventDefault(); const step = event.shiftKey ? 10 : 1;
      const distance = target === "transform" ? step / state.viewport.scale : step;
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") state[target].x = clamp(state[target].x + (event.key === "ArrowRight" ? distance : -distance), -1e7, 1e7);
      else state[target].y = clamp(state[target].y + (event.key === "ArrowDown" ? distance : -distance), -1e7, 1e7);
      render(false); changed();
    });
    const resizeObserver = win.ResizeObserver ? new win.ResizeObserver(updateScreenPresentation) : null; resizeObserver?.observe(svg);
    render();
    drawingTools=Viewport.createTools({svg,toolbarHost:host.querySelector(".dpv-options"),layer:()=>svg.querySelector(".dpv-scene"),getSnapRoot:()=>svg.querySelector(".dpv-geometry"),snapSelector:".pf-wing,.pf-base,.pf-mirror,.pf-root,.pf-reference,.pf-origin,.pf-box-end,.dpv-rib,.dpv-spar",getTheme:()=>state.theme,getDrawingPoint:event=>{const p=local(event);return{x:(p.x-state.viewport.x)/state.viewport.scale,y:(p.y-state.viewport.y)/state.viewport.scale};},getScale:()=>{const matrix=svg.getScreenCTM();return(matrix?Math.hypot(matrix.a,matrix.b):1)*state.viewport.scale;},getVisibleBounds:()=>{const rect=svg.getBoundingClientRect(),a=local({clientX:rect.left,clientY:rect.top}),b=local({clientX:rect.right,clientY:rect.bottom});return{x:(a.x-state.viewport.x)/state.viewport.scale,y:(a.y-state.viewport.y)/state.viewport.scale,width:(b.x-a.x)/state.viewport.scale,height:(b.y-a.y)/state.viewport.scale};},onChange:()=>{Object.assign(state,drawingTools.capture());changed();}});render();
    return { refresh: render, capture, restore(value) { stopDrag(true); clearTimeout(wheelTimer); state = validateState(value);drawingTools.restore({grid:state.grid,snap:state.snap,measurements:state.measurements}); loadError = ""; loadToken++; loading = false; render(); return capture(); },
      destroy() { destroyed = true; loadToken++; clearTimeout(wheelTimer); resizeObserver?.disconnect(); stopDrag(true);drawingTools?.destroy(); host.replaceChildren(); } };
  }
  return { PARAM_KEYS, MAX_IMAGE_BYTES, validateState, projection, derive, properties, overlay, install };
});
