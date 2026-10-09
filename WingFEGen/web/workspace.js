/* Portable Studies. Solver results remain in their analysis folders;
 * every reference source file and its current placement travel with the model.
 */
(function (root, factory) {
  const api = factory(typeof module === 'object' && module.exports ? require('./nastran_import.js') : root.WingNastranImport);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingWorkspace = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (nastran) {
  "use strict";
  const FORMAT = "wingfegen-workspace", VERSION = 1, MAX_BYTES = 256 * 1024 * 1024;
  const MAX_NOTE_LENGTH=20000,MAX_NOTE_ENTRIES=2000;
  const PANEL_IDS = ["sidebar","hud-left","model-card","results-card","pick-card","log-wrap","deck-panel"];
  const DRAWING_KEYS = new Set(["planform","spars","master-ribs","leading-edge-ribs","fuel-tank","stringer-section","spar-cap-section","rib-stiffener-section","rib-override-section","airfoil-root","airfoil-tip",...(["upper_skin","lower_skin","spar_web","rib_web","leading_edge_skin","leading_edge_rib"].map(name=>"material-"+name))]);
  const CONTROL_IDS = ["surface-mode","surface-translucency","beam-style","show-bars-through","show-aero-overlay","aero-deformed-style","background-color","inspect-entity",
    "show-fuel-inertia","show-fuel-cg","show-fuel-mass-labels","fuel-inertia-scale",
    "node-radius","marker-radius","show-ground-plane","show-symmetry-plane","ground-plane-z","ground-grid-spacing","show-shell-axes","show-bar-axes","show-node-ids","show-element-ids","id-label-size",
    "mesh-labels-none","mesh-labels-ribs","mesh-labels-stringers","mesh-labels-both","show-rib-datums","rib-datum-size","vlm-field",
    "vlm-force-scale","show-vlm-panel-forces","show-fuel-tank","show-panels","result-palette","show-support-forces","show-support-force-values","support-force-scale",
    "deform-scale","animate","show-undeformed","show-reference-aero","show-deformed-aero","contour-select","compare-results","auto-mesh","show-picked-axes","measure-snap-nodes"];
  const CHECK_IDS = new Set(CONTROL_IDS.filter((id) => id.startsWith("show-") || id.startsWith("mesh-labels-") || ["animate","auto-mesh","compare-results","measure-snap-nodes"].includes(id)));
  const SELECTS = {"surface-mode":["solid","translucent"],"beam-style":["lines","sections"],"aero-deformed-style":["auto","wireframe","steel","metallic","translucent"],
    "inspect-entity":["all","nodes","shells","quad","tria","bar","stringer","cap","rbe3"],"vlm-field":["none","pressure","cp"],
    "result-palette":["spectrum","viridis","inferno","coolwarm","grayscale"]};
  const object = (value) => value && typeof value === "object" && !Array.isArray(value);
  function isoTime(value,label="save timestamp") {
    if(typeof value!=="string"||!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(value)||!Number.isFinite(Date.parse(value))||new Date(value).toISOString()!==value)
      throw new Error("Invalid "+label+": expected a UTC ISO timestamp.");
    return value;
  }
  function normalizeNotes(value) {
    if(value==null)return{text:"",history:[]};
    if(!object(value)||Object.keys(value).some(key=>!["text","history"].includes(key))||typeof value.text!=="string"||value.text.length>MAX_NOTE_LENGTH||!Array.isArray(value.history)||value.history.length>MAX_NOTE_ENTRIES)
      throw new Error("Invalid Study notes: use text up to "+MAX_NOTE_LENGTH+" characters and a valid saved history.");
    const history=value.history.map(entry=>{
      if(!object(entry)||Object.keys(entry).some(key=>!["text","saved_at"].includes(key))||typeof entry.text!=="string"||!entry.text.trim()||entry.text.length>MAX_NOTE_LENGTH)
        throw new Error("Invalid saved Study note.");
      return{text:entry.text,saved_at:isoTime(entry.saved_at,"note save timestamp")};
    });
    return{text:value.text,history};
  }
  function notesForSave(previous,text,savedAt=new Date().toISOString()) {
    const notes=normalizeNotes(previous);isoTime(savedAt);
    if(typeof text!=="string"||text.length>MAX_NOTE_LENGTH)throw new Error("Study notes must be text up to "+MAX_NOTE_LENGTH+" characters.");
    notes.text=text;
    if(text.trim()&&notes.history.at(-1)?.text!==text){if(notes.history.length>=MAX_NOTE_ENTRIES)throw new Error("Study note history exceeds "+MAX_NOTE_ENTRIES+" entries.");notes.history.push({text,saved_at:savedAt});}
    return notes;
  }
  function triple(value, name, positive = false) {
    if (!Array.isArray(value) || value.length !== 3 || !value.every(Number.isFinite) || positive && value.some((v)=>v<=0))
      throw new Error("Invalid " + name + ": expected three " + (positive ? "positive " : "") + "finite values.");
    return value.slice();
  }
  function bytesToBase64(bytes) {
    let text = "";
    for (let i=0;i<bytes.length;i+=32768) text += String.fromCharCode(...bytes.subarray(i,i+32768));
    return btoa(text);
  }
  function base64ToBytes(text) {
    const padding = typeof text === "string" ? text.indexOf("=") : -1;
    if (typeof text !== "string" || text.length > Math.ceil(MAX_BYTES/3)*4 || text.length%4 || /[^A-Za-z0-9+/=]/.test(text) ||
        padding >= 0 && !["=","=="].includes(text.slice(padding)))
      throw new Error("Invalid or oversized embedded reference data.");
    const binary = atob(text), bytes = new Uint8Array(binary.length);
    for (let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i);
    if (!bytes.length) throw new Error("An embedded reference file is empty.");
    return bytes;
  }
  function validateView(view) {
    if (!object(view) || !object(view.controls) || !object(view.layers) || !object(view.camera) || !object(view.workspace))
      throw new Error("The model file has incomplete display settings.");
    for (const [id,value] of Object.entries(view.controls)) {
      if (!CONTROL_IDS.includes(id)) throw new Error("Unsupported display setting: " + id);
      if (CHECK_IDS.has(id)) { if (typeof value !== "boolean") throw new Error("Invalid checkbox setting: "+id); }
      else if (typeof value !== "string" || value.length>100) throw new Error("Invalid display setting: "+id);
      if (SELECTS[id] && !SELECTS[id].includes(value)) throw new Error("Invalid display option: "+id);
      if (id === "background-color" && !/^#[0-9a-f]{6}$/i.test(value)) throw new Error("Invalid background colour.");
      if (id === "ground-plane-z" && (value.trim()==="" || !Number.isFinite(Number(value)))) throw new Error("Ground z must be a finite number of metres.");
      if (id === "ground-grid-spacing" && (value.trim()==="" || !Number.isFinite(Number(value)) || Number(value)<=0)) throw new Error("Ground grid spacing must be a finite number greater than zero.");
      if (id === "rib-datum-size" && (value.trim()==="" || !Number.isFinite(Number(value)) || Number(value)<=0)) throw new Error("Rib datum square size must be a finite number greater than zero.");
      if (["node-radius","marker-radius","id-label-size","deform-scale"].includes(id) &&
          (value.trim()==="" || !Number.isFinite(Number(value)) || id !== "deform-scale" && Number(value)<0))
        throw new Error("Invalid display number: "+id);
      if (id === "vlm-force-scale" && (!Number.isFinite(Number(value)) || Number(value)<0.01 || Number(value)>100)) throw new Error("VLM force scale must be between 0.01 and 100.");
      if (id === "fuel-inertia-scale" && (!Number.isFinite(Number(value)) || Number(value)<0.01 || Number(value)>100)) throw new Error("Fuel inertia scale must be between 0.01 and 100.");
      if (id === "support-force-scale" && (!Number.isFinite(Number(value)) || Number(value)<0.01 || Number(value)>100)) throw new Error("Support-force scale must be between 0.01 and 100.");
      if(id==="surface-translucency"&&(value.trim()===""||!Number.isFinite(Number(value))||Number(value)<0||Number(value)>100))throw new Error("Surface translucency must be between 0 and 100 percent.");
    }
    for (const [name,value] of Object.entries(view.layers)) if (!/^[A-Z_0-9]+$/.test(name) || typeof value!=="boolean") throw new Error("Invalid layer visibility.");
    if(view.layerGroups!==undefined&&(!object(view.layerGroups)||Object.entries(view.layerGroups).some(([key,value])=>!["shells","beams","connections","aerodynamics","loads","masses","overlays","aids","other"].includes(key)||typeof value!=="boolean")))throw new Error("Invalid entity-list collapse settings.");
    if (view.loadLayers !== undefined && (!object(view.loadLayers) || Object.entries(view.loadLayers).some(([name,value])=>!["AERO_LOADS","AERO_MOMENTS","VLM_MESH","VLM_FORCES"].includes(name)||typeof value!=="boolean"))) throw new Error("Invalid load-layer display preferences.");
    const camera=view.camera;
    triple(camera.target,"camera target");
    for (const key of ["alpha","beta","radius"]) if (!Number.isFinite(camera[key])) throw new Error("Invalid camera "+key);
    if (camera.radius<=0) throw new Error("Camera radius must be positive.");
    for (const key of ["fov","minZ","maxZ","orthoLeft","orthoRight","orthoTop","orthoBottom","lowerRadiusLimit","upperRadiusLimit"])
      if (camera[key] !== undefined && !(camera[key] === null && !["fov","minZ","maxZ"].includes(key)) && !Number.isFinite(camera[key])) throw new Error("Invalid camera "+key);
    if (camera.fov !== undefined && !(camera.fov > 0 && camera.fov < Math.PI)) throw new Error("Camera field of view must be between 0 and pi radians.");
    if ((camera.minZ !== undefined || camera.maxZ !== undefined) && !(camera.minZ > 0 && camera.maxZ > camera.minZ)) throw new Error("Camera clip planes must satisfy 0 < near < far.");
    if (camera.lowerRadiusLimit != null && camera.lowerRadiusLimit < 0 || camera.upperRadiusLimit != null && camera.upperRadiusLimit <= 0 ||
        camera.lowerRadiusLimit != null && camera.upperRadiusLimit != null && camera.upperRadiusLimit < camera.lowerRadiusLimit) throw new Error("Invalid camera distance limits.");
    const ortho=[camera.orthoLeft,camera.orthoRight,camera.orthoBottom,camera.orthoTop];
    if (ortho.some(v=>v!=null) && !(ortho.every(Number.isFinite) && camera.orthoLeft < camera.orthoRight && camera.orthoBottom < camera.orthoTop)) throw new Error("Invalid orthographic camera bounds.");
    if (camera.mode !== undefined && ![0,1].includes(camera.mode)) throw new Error("Invalid camera projection mode.");
    const workspace=view.workspace;
    if (typeof workspace.activeTab!=="string" || workspace.activeTab.length>40 || !Number.isFinite(workspace.width) || workspace.width<=0 ||
        typeof workspace.collapsed!=="boolean" || workspace.maximizedTab!==undefined && workspace.maximizedTab!==null && typeof workspace.maximizedTab!=="string") throw new Error("Invalid workspace panel settings.");
    if (workspace.panels !== undefined && (!object(workspace.panels) || Object.entries(workspace.panels).some(([id,value])=>!PANEL_IDS.includes(id)||typeof value!=="boolean"))) throw new Error("Invalid panel visibility settings.");
    if (!Number.isInteger(view.activeCase) || view.activeCase<1) throw new Error("Invalid displayed load case.");
    if (view.editingCase!==undefined&&(!Number.isInteger(view.editingCase)||view.editingCase<1))throw new Error("Invalid edited load case.");
    if (view.resultVariant !== undefined && !["","sol101","sol103","sol105","sol106"].includes(view.resultVariant) &&
        !(typeof view.resultVariant==="string" && /^sensitivity_[A-Za-z0-9_-]{1,180}_sol(?:101|103|105)$/.test(view.resultVariant))) throw new Error("Invalid selected result analysis.");
    if (view.contourPreference != null && (!object(view.contourPreference) || Object.keys(view.contourPreference).some(key=>!["kind","name"].includes(key)) || !["none","disp","data"].includes(view.contourPreference.kind) || typeof view.contourPreference.name!=="string" || view.contourPreference.name.length>200)) throw new Error("Invalid selected result quantity.");
    if (view.realScale !== undefined && typeof view.realScale !== "boolean") throw new Error("Invalid deformation scale mode.");
    if (view.parameterLocks !== undefined && (!object(view.parameterLocks) || Object.entries(view.parameterLocks).some(([key,value])=>!["planform","mesh"].includes(key)||typeof value!=="boolean"))) throw new Error("Invalid parameter lock settings.");
    if (view.reference && (!Number.isInteger(view.reference.selectedIndex) || view.reference.selectedIndex < -1 || !["move","rotate","scale","off"].includes(view.reference.mode))) throw new Error("Invalid reference selection settings.");
    if (view.planView !== undefined) {
      const api = typeof WingDimensionedPlanView !== "undefined" ? WingDimensionedPlanView :
        typeof require === "function" ? require("./dimensioned_plan_view.js") : null;
      if (!api) throw new Error("Plan-view images require the updated viewer. Refresh WingFEGen.");
      view.planView = api.validateState(view.planView);
    }
    if (view.planformInputs !== undefined) {
      const settings=view.planformInputs;
      if(!object(settings)||Object.keys(settings).some(key=>key!=="method")||!["area","dimensions"].includes(settings.method)) throw new Error("Invalid planform input method.");
    }
    if (view.drawings !== undefined) {
      if (!object(view.drawings) || Object.keys(view.drawings).some(key => !DRAWING_KEYS.has(key) && !/^airfoil-station-([1-9]|[1-9][0-9]|100)$/.test(key))) throw new Error("Invalid 2D drawing settings.");
      const api = typeof WingSVGViewport !== "undefined" ? WingSVGViewport : typeof require === "function" ? require("./svg_viewport.js") : null;
      if (!api) throw new Error("2D drawing images require the updated viewer. Refresh WingFEGen.");
      view.drawings = Object.fromEntries(Object.entries(view.drawings).map(([key,value]) => [key,api.validateState(value)]));
    }
    if (view.viewportTools !== undefined && (!object(view.viewportTools) || Object.keys(view.viewportTools).some(key=>key!=="collapsed") || typeof view.viewportTools.collapsed!=="boolean")) throw new Error("Invalid viewport toolbar settings.");
    if (view.panelExplosion !== undefined) {
      const api=typeof WingPanelExplode!=="undefined" ? WingPanelExplode : typeof require==="function" ? require("./panel_explode.js") : null;
      if(!api)throw new Error("Panel explosion settings cannot be validated.");
      view.panelExplosion=api.normalize(view.panelExplosion);
    }
    if (view.lighting !== undefined) {
      const api=typeof WingSceneLighting!=="undefined" ? WingSceneLighting : typeof require==="function" ? require("./scene_lighting.js") : null;
      if(!api)throw new Error("Lighting settings need the updated viewer.");
      view.lighting=api.normalize(view.lighting);
    }
    if(view.propertyDisplay!==undefined){const api=typeof WingPropertyDisplay!=="undefined"?WingPropertyDisplay:typeof require==="function"?require("./property_display.js"):null;
      if(!api)throw new Error("Property colors require the updated viewer.");view.propertyDisplay=api.validateState(view.propertyDisplay);}
    if(view.legends!==undefined){const api=typeof WingLegends!=="undefined"?WingLegends:typeof require==="function"?require("./viewport-legends.js"):null;
      if(!api)throw new Error("Color-scale settings require the updated viewer.");view.legends=api.validateState(view.legends);}
    if(view.loadPlots!==undefined){const api=typeof WingLoadPlots!=="undefined"?WingLoadPlots:typeof require==="function"?require("./load_plots.js"):null;
      if(!api)throw new Error("Load-plot settings require the updated viewer.");view.loadPlots=api.validateState(view.loadPlots);}
    return view;
  }
  // Sparse older Studies must use current markup defaults for new controls,
  // never whatever happened to be selected in the previously open Study.
  function completeView(value,document) {
    const view=JSON.parse(JSON.stringify(value));validateView(view);
    const controls={};
    for(const id of CONTROL_IDS){const element=document?.getElementById(id);if(!element)continue;
      if(CHECK_IDS.has(id))controls[id]=element.defaultChecked===true;
      else if(element.tagName==="SELECT")controls[id]=Array.from(element.options).find(option=>option.defaultSelected)?.value||element.options[0]?.value||"";
      else controls[id]=element.defaultValue??element.getAttribute?.("value")??"";
    }
    Object.assign(controls,view.controls);
    const radios=["mesh-labels-none","mesh-labels-ribs","mesh-labels-stringers","mesh-labels-both"],selected=radios.filter(id=>view.controls[id]===true);
    if(selected.length>1)throw new Error("Choose only one rib/stringer label option.");
    if(radios.some(id=>Object.hasOwn(controls,id)))for(const id of radios)controls[id]=id===(selected[0]||"mesh-labels-none");
    view.controls=controls;
    view.editingCase??=1;view.resultVariant??="";view.contourPreference??=null;view.realScale??=false;view.loadLayers??={};view.parameterLocks??={planform:false,mesh:false};
    view.reference??={selectedIndex:-1,mode:"off"};view.drawings??={};view.viewportTools??={collapsed:false};view.planformInputs??={method:"area"};view.legends??={collapsed:{}};
    view.panelExplosion??={enabled:false,origin:"centroid",distance:1};view.layerGroups??={};
    view.loadPlots??={mode:"distributed",visible:["aerodynamic","structure","fuel","total"]};
    view.camera.mode??=0;view.camera.fov??=.8;
    for(const key of ["orthoLeft","orthoRight","orthoTop","orthoBottom"])view.camera[key]??=null;
    view.workspace.maximizedTab??=null;view.workspace.panels={...Object.fromEntries(PANEL_IDS.map(id=>[id,false])),...view.workspace.panels};
    validateView(view);return view;
  }
  function parse(text) {
    let data; try { data=JSON.parse(text); } catch (_) { throw new Error("Choose a valid .wingfem.json Study file."); }
    return parseObject(data);
  }
  // Validate in-memory definitions without serializing and parsing large native
  // deck/include strings a second time during import or Save Study.
  function parseObject(data) {
    if (!object(data) || data.format!==FORMAT || data.version!==VERSION) throw new Error("Unsupported Study file format or version. Choose a WingFEGen .wingfem.json file.");
    if (!object(data.parameters) || !Array.isArray(data.references)) throw new Error("Study parameters or embedded references are missing.");
    data.notes=normalizeNotes(data.notes);
    if(data.model_source!==undefined)data.model_source=nastran.source(data.model_source);
    if(data.saved_at!==undefined)isoTime(data.saved_at);
    validateView(data.view);
    let total=0;
    const items=data.references.map((record)=>{
      if (!object(record) || typeof record.source_name!=="string" || !/\.(stl|obj|glb)$/i.test(record.source_name) || record.source_name.length>255)
        throw new Error("Invalid embedded reference filename.");
      if (!["m","mm","cm","inch"].includes(record.units) || !["fe","yup"].includes(record.axis)) throw new Error("Invalid reference units or axes: "+record.source_name);
      triple(record.position_m,"reference position"); triple(record.rotation_deg,"reference rotation"); triple(record.scale,"reference scale",true);
      if (typeof record.visible!=="boolean" || typeof record.wireframe!=="boolean" || !Number.isFinite(record.opacity) || record.opacity<0.03 || record.opacity>1) throw new Error("Invalid reference appearance: "+record.source_name);
      if (record.locked!==undefined && typeof record.locked!=="boolean") throw new Error("Invalid reference placement lock: "+record.source_name);
      const bytes=base64ToBytes(record.data_base64); total+=bytes.length;
      if (total>MAX_BYTES) throw new Error("Embedded references exceed the 256 MiB portable-file limit.");
      const {data_base64,...metadata}=record;
      return {file:new File([bytes],record.source_name),metadata:{...metadata,locked:record.locked===true}};
    });
    // Input-relative assets are replaced by the embedded portable references.
    data.parameters["references.items"]=[];
    return {data,items};
  }
  async function snapshot(parameters, references, view, options = {}) {
    // Freeze the definition before reading potentially large reference files.
    const params=JSON.parse(JSON.stringify(parameters));params["references.items"]=[];
    const display=JSON.parse(JSON.stringify(view)),savedAt=isoTime(options.savedAt||new Date().toISOString());
    const notes=normalizeNotes(options.notes);
    const assets=references ? await references.exportPortable() : [];
    const data={format:FORMAT,version:VERSION,created_at:options.createdAt||savedAt,saved_at:savedAt,notes,parameters:params,
      references:assets.map(({metadata,bytes})=>({...metadata,data_base64:bytesToBase64(bytes)})),view:display};
    // Apply the same checks on export and import, including the total limit.
    if(options.modelSource)data.model_source=nastran.source(options.modelSource);
    parseObject(data); return data;
  }
  function captureView(document,state,workspace) {
    const controls={};
    for (const id of CONTROL_IDS) { const el=document.getElementById(id); if (el) controls[id]=CHECK_IDS.has(id) ? el.checked : el.value; }
    // Property-effect previews temporarily change ordinary overlays and
    // animation. Their independent palette is saved in the legends state.
    const preview=state.sensitivityMap?.previous;
    if(preview){controls.animate=preview.animate;}
    const c=state.camera, camera={target:c.target.asArray(),alpha:c.alpha,beta:c.beta,radius:c.radius,mode:c.mode};
    for (const key of ["fov","minZ","maxZ","orthoLeft","orthoRight","orthoTop","orthoBottom","lowerRadiusLimit","upperRadiusLimit"]) camera[key]=c[key]===undefined?null:c[key];
    return {controls,layers:Object.fromEntries(Array.from(state.layers,([name,layer])=>[name,preview?.overlays?.get(name)?.visible??state.panelView?.previous.get(name)??layer.visible])),
      loadLayers:Object.fromEntries(state.loadLayerVisibility || []),layerGroups:Object.fromEntries(state.layerGroupCollapsed||[]),camera,
      activeCase:Number(state.activeCase)||1,editingCase:Number(state.editingCase)||1,
      resultVariant:state.resultVariantPreference || state.results?.variantId || "",
      contourPreference:state.contourPreference ? {kind:state.contourPreference.kind,name:state.contourPreference.name} : null,
      realScale:state.realScale === true,
      parameterLocks:state.parameterLocks?.capture() || {planform:false,mesh:false},
      ...(state.planView ? {planView:state.planView.capture()} : {}),
      ...(typeof WingSVGViewport !== "undefined" ? {drawings:WingSVGViewport.captureAll()} : {}),
      ...(state.planformInputs ? {planformInputs:state.planformInputs.capture()} : {}),
      ...(state.viewportTools ? {viewportTools:state.viewportTools.capture()} : {}),
      ...(state.sceneLighting ? {lighting:state.sceneLighting.capture()} : {}),
      ...(state.panelExplosion ? {panelExplosion:state.panelExplosion.capture()} : {}),
      ...(state.propertyDisplay ? {propertyDisplay:state.propertyDisplay.capture()} : {}),
      ...(typeof WingLegends!=="undefined" ? {legends:WingLegends.capture()} : {}),
      loadPlots:state.loadPlots?.capture()||{mode:"distributed",visible:["aerodynamic","structure","fuel","total"]},
      workspace:{activeTab:workspace.activeTab,width:workspace.preferredWidth,collapsed:document.getElementById("sidebar").classList.contains("panel-collapsed"),maximizedTab:workspace.maximizedTab||null,
        panels:Object.fromEntries(PANEL_IDS.filter(id=>document.getElementById(id)).map(id=>[id,document.getElementById(id).classList.contains("panel-collapsed")]))},
      reference:state.reference ? {selectedIndex:state.reference.entries.indexOf(state.reference.active),mode:state.reference.mode} : {selectedIndex:-1,mode:"off"}};
  }
  function applyControls(document,controls) {
    for (const [id,value] of Object.entries(controls)) {
      const el=document.getElementById(id); if (!el) continue;
      if (CHECK_IDS.has(id)) el.checked=value;
      else if(id==="aero-deformed-style"&&value==="steel")el.value="auto";
      else if (el.tagName!=="SELECT" || Array.from(el.options).some((o)=>o.value===value)) el.value=value;
    }
  }
  function filename(title) { return (String(title||"wing").replace(/[^a-z0-9_-]+/gi,"_").replace(/^_+|_+$/g,"")||"wing")+".wingfem.json"; }
  // Call this before the first await in the click handler: Chromium requires
  // transient user activation when opening its filename/folder dialog.
  function requestSaveDestination(kind, name, host = globalThis) {
    const fallback = {method:"download",name};
    if (typeof host.showSaveFilePicker !== "function" || host.isSecureContext === false) return Promise.resolve(fallback);
    let request;
    try {
      request=host.showSaveFilePicker({id:"wingfegen-"+kind,suggestedName:name,
        types:[{description:kind==="study" ? "WingFEGen Study" : "WingFEGen TOML parameters",
          accept:kind==="study" ? {"application/json":[".wingfem.json"]} : {"text/plain":[".toml"]}}]});
    } catch(error) { request=Promise.reject(error); }
    // Resolve cancellations/errors immediately to avoid an unhandled rejection
    // while the interface yields to paint its busy state.
    return Promise.resolve(request).then(handle=>({method:"picker",handle,name:handle.name}),error=>
      error?.name==="AbortError" ? {cancelled:true} : error?.name==="SecurityError" ?
        {...fallback,guidance:"The browser blocked the save dialog; a download was requested instead."} : {error});
  }
  function downloadText(text,name,type,document) {
    const blob=new Blob([text],{type}),url=URL.createObjectURL(blob),a=document.createElement("a");
    a.href=url;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  // A normal Save keeps the linked destination. Save as always opens a new
  // chooser. Permission is requested synchronously while click activation is live.
  function requestStudyDestination(name, {handle=null,saveAs=false} = {}, host=globalThis) {
    if (saveAs || !handle || typeof handle.createWritable!=="function") return requestSaveDestination("study",name,host);
    let request;
    try { request=typeof handle.requestPermission==="function" ? handle.requestPermission({mode:"readwrite"}) : "granted"; }
    catch(error) { request=Promise.reject(error); }
    return Promise.resolve(request).then(permission=>permission==="granted" ? {method:"picker",handle,name:handle.name||name} :
      {error:new Error("Write access to the linked Study was not granted. Use Save Study as… to choose another file.")},error=>({error}));
  }
  async function writeDestination(destination,text,type,document) {
    if (destination.error) throw destination.error;
    if (destination.cancelled) return false;
    if (destination.method==="picker") {
      let writer;
      try { writer=await destination.handle.createWritable();await writer.write(text);await writer.close(); }
      catch(error) { try { await writer?.abort(); } catch(_) {} throw error; }
    } else downloadText(text,destination.name,type,document);
    return destination;
  }
  function download(data,name,document) {
    downloadText(JSON.stringify(data,null,2),name,"application/json",document);
  }
  return {FORMAT,VERSION,CONTROL_IDS,MAX_NOTE_LENGTH,MAX_NOTE_ENTRIES,normalizeNotes,notesForSave,completeView,parse,parseObject,snapshot,captureView,applyControls,validateView,bytesToBase64,base64ToBytes,filename,download,requestSaveDestination,requestStudyDestination,writeDestination,downloadText};
});
