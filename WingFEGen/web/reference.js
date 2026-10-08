/* Local reference geometry is a separate scene branch from the generated FEM.
 * Pinned Babylon importers load an AssetContainer before replacing any UI state.
 * Source geometry never participates in FE meshing, properties, loads or deck export.
 * Geometry-only STL/GLB export can include its transformed triangle surfaces.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingReference = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const UNITS = { m: 1, mm: 0.001, cm: 0.01, inch: 0.0254 };
  const HELP = [
    "Load local STL, OBJ or self-contained GLB geometry to compare with the wing. References stay in this browser session when Create FEM rebuilds the model. They are not FE elements and are not included in loads, analysis or Nastran export.",
    "Choose the source units and axes. STL/OBJ default to metres and FE coordinates: x aft, y toward the tip, z up. GLB defaults to metres and Y up: file X maps to FE x, file Y to FE z, and file Z to negative FE y. Change these settings if the source uses another convention.",
    "Select Move, Rotate or Scale and drag the handles. Red is FE x, green FE y and blue FE z. Move/Rotate use global FE directions; Scale uses the reference's rotated directions. Numeric positions use metres, rotations use degrees (fixed x, then y, then z), and scales are dimensionless. Transforms act about the file origin; Reset restores its original placement.",
    "Lock placement protects the selected reference's position, rotation, scale, source units and source axes, including Reset and the transform handles. You can still select, fit, hide or change its appearance. Each reference has its own lock; unlock it before moving it again. Save Study or save its linked TOML settings to retain the lock. Older files load unlocked.",
    "Imports use neutral translucent geometry. OBJ material/texture sidecars are ignored. GLB must contain its buffers; Draco/meshopt compressed geometry needs an uncompressed export. After import, choose Save a portable copy to keep it with the server TOML input, or Session only. Browsers cannot disclose the original absolute file path. Saving copies the file into the input's .reference_assets folder and records its relative path and placement. Later changes are written by Save reference settings or Server input > Overwrite server input. Keep the input and its assets folder together when moving them.",
    "Save Study in the top header writes one .wingfem.json file containing every loaded reference, including session-only imports, with its source bytes and current placement. Load Study restores this portable file without changing the server's TOML input. Save TOML as creates cached copies for any unlinked references and includes every loaded reference's path and placement. These paths resolve relative to the configured server input folder; use a Study to move the complete project between computers. Neither action overwrites the server TOML. A missing reference must be restored or explicitly forgotten before a complete file can be saved."
  ];
  const toView = (p) => [p[1], p[2], p[0]];
  const toFE = (p) => [p[2], p[0], p[1]];
  function rotationQuaternion(B, angles) {
    const [x, y, z] = angles.map((v) => v * Math.PI / 180);
    const qx = B.Quaternion.RotationAxis(new B.Vector3(0, 0, 1), x);
    const qy = B.Quaternion.RotationAxis(new B.Vector3(1, 0, 0), y);
    const qz = B.Quaternion.RotationAxis(new B.Vector3(0, 1, 0), z);
    return qz.multiply(qy).multiply(qx).normalize();
  }
  function rotationAngles(q) {
    const [x, y, z, w] = [q.z, q.x, q.y, q.w];
    return [Math.atan2(2*(w*x+y*z), 1-2*(x*x+y*y)),
      Math.asin(Math.max(-1, Math.min(1, 2*(w*y-z*x)))),
      Math.atan2(2*(w*z+x*y), 1-2*(y*y+z*z))].map((v) => v * 180 / Math.PI);
  }
  function glbMetadata(buffer) {
    const view = new DataView(buffer);
    if (buffer.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67 || view.getUint32(4, true) !== 2 ||
        view.getUint32(8, true) !== buffer.byteLength || view.getUint32(16, true) !== 0x4e4f534a)
      throw new Error("GLB must be a valid glTF 2 binary file.");
    const length = view.getUint32(12, true);
    if (length > buffer.byteLength - 20) throw new Error("GLB JSON chunk is truncated.");
    const json = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 20, length)).replace(/\0+$/, ""));
    if ((json.buffers || []).some((b) => b.uri && !b.uri.startsWith("data:")))
      throw new Error("GLB has an external buffer. Export a self-contained GLB.");
    if ((json.extensionsUsed || []).some((e) => e === "KHR_draco_mesh_compression" || e === "EXT_meshopt_compression"))
      throw new Error("Compressed GLB geometry requires an uncompressed GLB export.");
    return json;
  }
  async function fileSource(file, extension) {
    const data = await file.arrayBuffer();
    if (extension === ".glb") { glbMetadata(data); return new Uint8Array(data); }
    if (extension === ".obj") return "data:" + new TextDecoder().decode(data).replace(/^\s*mtllib\b.*$/gm, "");
    // Validate binary STL count before the loader allocates its vertex arrays.
    if (data.byteLength >= 84 && new DataView(data).getUint32(80, true) * 50 + 84 === data.byteLength) return data;
    const text = new TextDecoder().decode(data);
    if (!/^\s*solid(?:\s|$)/.test(text) || !/\bfacet\s+normal\b/.test(text) || !/\bendsolid\b/.test(text))
      throw new Error("STL has no valid ASCII facets or binary triangle data.");
    return text;
  }
  function create(options) {
    const B = options.BABYLON || globalThis.BABYLON;
    const { scene, camera, engine, host } = options;
    const log = options.onLog || (() => {});
    const entries = [], controls = {}, unavailable = new Map();
    let selected = null, sequence = 0, loading = 0, disposed = false, dragging = false, ignoreUntil = 0;
    let mode = "move", gizmos = null, saving = false;
    function changed() { if (options.onChange) options.onChange(api); }
    function selectedEntry() { return entries.find((entry) => entry.id === selected) || null; }
    function notify(message, kind) {
      if (controls.status) { controls.status.textContent = message; controls.status.className = "reference-status " + (kind || ""); }
      log(message, kind);
    }
    function updateFields() {
      const entry = selectedEntry();
      if (!host) return;
      controls.list.replaceChildren();
      for (const item of entries) {
        const option = host.ownerDocument.createElement("option"); option.value = String(item.id);
        option.textContent = item.name + (item.locked ? " (locked)" : "") + (item.visible ? "" : " (hidden)"); controls.list.appendChild(option);
      }
      controls.list.value = entry ? String(entry.id) : "";
      controls.content.hidden = !entry;
      controls.empty.hidden = !!entry;
      if (!entry) return;
      const transform = getTransform(entry);
      for (const kind of ["position", "rotation", "scale"]) for (let axis = 0; axis < 3; axis++) {
        const input = controls[kind][axis];
        input.disabled = entry.locked;
        if (input !== host.ownerDocument.activeElement) input.value = Number(transform[kind][axis].toPrecision(8));
      }
      controls.units.value = entry.units; controls.axis.value = entry.axis;
      controls.units.disabled = entry.locked; controls.axis.disabled = entry.locked;
      controls.lock.checked = entry.locked;
      controls.reset.disabled = entry.locked;
      controls.lockStatus.textContent = entry.locked ? "Placement locked. Unlock to move, rotate, scale, reset or change source units/axes." : "Placement unlocked. Changes affect only this reference.";
      controls.lockStatus.classList.toggle("locked",entry.locked);
      controls.visible.checked = entry.visible; controls.opacity.value = entry.opacity;
      controls.wireframe.checked = entry.wireframe;
      for (const [key, button] of Object.entries(controls.modes)) {
        button.disabled = entry.locked && key !== "off";
        button.classList.toggle("active", key === mode); button.setAttribute("aria-pressed", String(key === mode));
      }
      const b = bounds(entry);
      controls.info.textContent = `${entry.meshes.length} meshes · ${entry.triangles.toLocaleString()} triangles` +
        (b ? " · bounds " + toFE(b.maximum.subtract(b.minimum).asArray()).map((v) => typeof WingNumbers !== "undefined" ? WingNumbers.format(v,4) : Number(v.toPrecision(4))).join(" × ") + " m" : "");
      updatePersistenceControls();
    }
    const canonical = (record) => JSON.stringify(Object.keys(record).sort().map((key) => [key, record[key]]));
    const precise = (values) => values.map((v) => Math.abs(v) < 1e-11 ? 0 : Number(v.toPrecision(11)));
    function recordFor(entry) {
      const transform = getTransform(entry);
      return { version: 1, id: entry.savedId, asset_path: entry.assetPath, source_name: entry.name,
        units: entry.units, axis: entry.axis, position_m: precise(transform.position), rotation_deg: precise(transform.rotation),
        scale: precise(transform.scale), visible: entry.visible, opacity: entry.opacity, wireframe: entry.wireframe, locked: entry.locked };
    }
    function serialize() {
      return [...Array.from(unavailable.values(), (record) => ({...record})),
        ...entries.filter((entry) => entry.assetPath).map(recordFor)];
    }
    function markSaved(records = serialize()) {
      const saved = new Map(records.map((record) => [record.id, canonical(record)]));
      for (const entry of entries) if (entry.assetPath) entry.savedSnapshot = saved.get(entry.savedId) || "";
      updatePersistenceControls();
    }
    function updatePersistenceControls() {
      if (!controls.persistence) return;
      updateMissingControls();
      const entry = selectedEntry();
      controls.persistence.hidden = !entry;
      if (!entry) return;
      const pending = entry.persistenceChoice === "pending", enrolled = !!entry.assetPath;
      controls.prompt.hidden = !pending;
      controls.enroll.hidden = pending || enrolled;
      controls.saveSettings.hidden = !enrolled;
      controls.forget.hidden = !enrolled;
      for (const key of ["saveCopy", "sessionOnly", "enroll", "saveSettings", "forget"]) controls[key].disabled = saving;
      const dirty = enrolled && canonical(recordFor(entry)) !== entry.savedSnapshot, tomlCurrent=enrolled&&canonical(recordFor(entry))===entry.tomlSnapshot;
      controls.savedStatus.textContent = enrolled ? (dirty ? tomlCurrent ? "Reference and placement linked in the last saved TOML. Server input unchanged." : "Linked reference — use Save Study, Save TOML as, or explicitly save its settings to the server input." : "Reference and placement saved with the server input.") : entry.portableSource ? "Included in the loaded Study. Save Study includes this geometry and its current placement." :
        pending ? "Keep this reference for future sessions?" : "Session only — this reference will not be restored after reopening.";
      controls.savedStatus.className = "reference-saved-status" + (dirty&&!tomlCurrent ? " unsaved" : "");
      controls.savedPath.textContent = enrolled ? "Asset: " + entry.assetPath : "";
    }
    function updateMissingControls() {
      if (!controls.missing) return;
      controls.missing.replaceChildren();
      for (const record of unavailable.values()) {
        const row = host.ownerDocument.createElement("div"); row.className = "reference-missing";
        const text = host.ownerDocument.createElement("span"); text.textContent = "Unavailable: " + record.source_name + " · " + record.asset_path;
        const button = host.ownerDocument.createElement("button"); button.className = "mini"; button.textContent = "Forget saved entry";
        button.disabled = saving;
        button.onclick = async () => {
          unavailable.delete(record.id);
          try { await saveSettings(); } catch (_) { unavailable.set(record.id, record); updatePersistenceControls(); }
        };
        row.append(text, button); controls.missing.append(row);
      }
    }
    async function responseJSON(response) {
      let value;
      try { value = await response.json(); }
      catch (_) {
        throw new Error(response.status === 404 ?
          "Reference persistence needs the updated server. Restart WingFEGen and refresh." :
          "The reference server returned an invalid response (HTTP " + response.status + ").");
      }
      if (!response.ok || value.ok === false) throw new Error(value.error || "Reference settings could not be saved");
      return value;
    }
    async function saveSettings() {
      if (saving) return false;
      saving = true; updatePersistenceControls();
      const records = serialize();
      try {
        await responseJSON(await fetch("/api/save_references", { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({items:records}) }));
        markSaved(records); notify("Reference files and placements saved with the input.", "good"); changed(); return true;
      } catch (error) { notify("Could not save references: " + error.message, "err"); throw error; }
      finally { saving = false; updatePersistenceControls(); }
    }
    async function enroll(entry = selectedEntry()) {
      if (!entry || saving) return false;
      const previous = {assetPath:entry.assetPath, savedId:entry.savedId, persistenceChoice:entry.persistenceChoice};
      saving = true; updatePersistenceControls();
      try {
        if (!entry.assetPath) {
          if (!entry.sourceFile) throw new Error("Import the original file again to save a portable copy.");
          const result = await responseJSON(await fetch("/api/reference_upload?name="+encodeURIComponent(entry.name), {
            method:"POST", headers:{"Content-Type":"application/octet-stream"}, body:await entry.sourceFile.arrayBuffer()
          }));
          entry.assetPath = result.asset_path;
          entry.savedId = entry.savedId || globalThis.crypto.randomUUID();
        }
        entry.persistenceChoice = "saved";
        const records = serialize();
        await responseJSON(await fetch("/api/save_references", {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items:records})}));
        markSaved(records); notify("Saved a portable copy and placement for " + entry.name + ".", "good"); changed(); return true;
      } catch (error) {
        Object.assign(entry,previous); notify("Could not save reference: " + error.message,"err"); throw error;
      } finally { saving = false; updatePersistenceControls(); }
    }
    async function forget(entry = selectedEntry()) {
      if (!entry || !entry.assetPath || saving) return false;
      const previous = {assetPath:entry.assetPath,savedId:entry.savedId,persistenceChoice:entry.persistenceChoice};
      entry.assetPath = null; entry.savedId = null; entry.persistenceChoice = "session";
      try { await saveSettings(); updateFields(); return true; }
      catch (error) { Object.assign(entry,previous); updateFields(); throw error; }
    }
    async function restore(records) {
      if (disposed) return;
      const desired = new Map((records || []).map((record) => [record.id,record]));
      unavailable.clear();
      for (const entry of entries.slice()) if (entry.assetPath && !desired.has(entry.savedId)) remove(entry.id);
      for (const record of desired.values()) {
        let entry = entries.find((item) => item.savedId === record.id && item.assetPath === record.asset_path);
        try {
          if (!entry) {
            const response = await fetch("/api/reference_asset?asset="+encodeURIComponent(record.asset_path), {cache:"no-store"});
            if (!response.ok) { const message = await responseJSON(response); throw new Error(message.error || "file unavailable"); }
            const file = new File([await response.arrayBuffer()],record.source_name);
            entry = await importFile(file,{units:record.units,axis:record.axis,savedRecord:record});
          }
          selected = entry.id;
          entry.assetPath = record.asset_path; entry.savedId = record.id; entry.persistenceChoice = "saved";
          // Loading a saved record intentionally replaces its placement; apply
          // its lock only after that placement has been restored.
          entry.locked = false;
          setSource({units:record.units,axis:record.axis});
          setTransform({position:record.position_m,rotation:record.rotation_deg,scale:record.scale});
          setVisible(record.visible); setAppearance({opacity:record.opacity,wireframe:record.wireframe});
          setLocked(record.locked === true);
          entry.savedSnapshot = canonical(recordFor(entry));
        } catch (error) {
          unavailable.set(record.id,record);
          notify("Saved reference unavailable: " + record.source_name + " — " + error.message,"warn");
        }
      }
      updateFields(); updatePersistenceControls();
    }
    async function exportPortable() {
      if (loading || saving) throw new Error("Wait for the reference import or save to finish.");
      if (unavailable.size) throw new Error("Cannot save a complete model: unavailable reference " +
        Array.from(unavailable.values(), (r) => r.source_name).join(", ") + ". Restore the missing file or explicitly forget its saved entry.");
      const result = [];
      for (const entry of entries) {
        let file = entry.sourceFile;
        if (!file && entry.assetPath) {
          const response = await fetch("/api/reference_asset?asset="+encodeURIComponent(entry.assetPath), {cache:"no-store"});
          if (!response.ok) throw new Error("Cannot embed reference " + entry.name + ": source file is unavailable.");
          file = new File([await response.arrayBuffer()], entry.name);
        }
        if (!file) throw new Error("Cannot embed reference " + entry.name + ": import its source file again.");
        const {version,id,asset_path,...metadata} = recordFor(entry);
        const transform = getTransform(entry);
        metadata.position_m = transform.position; metadata.rotation_deg = transform.rotation; metadata.scale = transform.scale;
        result.push({metadata, bytes: new Uint8Array(await file.arrayBuffer())});
      }
      return result;
    }
    async function prepareTomlRecords() {
      if(loading||saving||disposed)throw new Error("Wait for the reference import or save to finish.");
      if(unavailable.size)throw new Error("Cannot save a complete TOML: unavailable reference "+Array.from(unavailable.values(),r=>r.source_name).join(", ")+". Restore the missing file or explicitly forget its saved entry.");
      saving=true;updatePersistenceControls();
      const staged=[];let committed=false;
      try{
        for(const entry of entries.slice()){
          let assetPath=entry.assetPath;
          if(!assetPath){
            if(!entry.sourceFile)throw new Error("Cannot save reference "+entry.name+": import its source file again.");
            const result=await responseJSON(await fetch("/api/reference_upload?name="+encodeURIComponent(entry.name),{method:"POST",headers:{"Content-Type":"application/octet-stream"},body:await entry.sourceFile.arrayBuffer()}));
            if(typeof result.asset_path!=="string"||!result.asset_path)throw new Error("No cached reference path was returned for "+entry.name+".");
            assetPath=result.asset_path;
          }
          const record={...recordFor(entry),id:entry.savedId||globalThis.crypto.randomUUID(),asset_path:assetPath};
          staged.push({entry,record});
        }
        return{records:staged.map(({record})=>structuredClone(record)),commit(){
          if(committed)return; if(disposed||staged.some(({entry})=>!entries.includes(entry)))throw new Error("The reference set changed while TOML was being saved.");
          for(const {entry,record}of staged){entry.assetPath=record.asset_path;entry.savedId=record.id;entry.persistenceChoice="saved";entry.tomlSnapshot=canonical(record);}
          committed=true;updateFields();updatePersistenceControls();
        }};
      }finally{saving=false;updatePersistenceControls();}
    }
    async function stagePortable(items, view = {}, options = {}) {
      if (loading || saving || disposed) throw new Error("The reference viewer is busy or closed.");
      const staged = [], previous = entries.slice(), previousMissing = new Map(unavailable);
      const previousSelection = selected, previousMode = mode;
      let committed = false, finished = false;
      const disposeEntry = (entry) => { entry.container.dispose(); entry.root.dispose(); entry.material.dispose(); };
      try {
        for (const {file, metadata} of items) {
          const entry = await importFile(file, {units:metadata.units,axis:metadata.axis,detached:true});
          staged.push(entry);
          entry.root.position.copyFromFloats(...toView(metadata.position_m));
          entry.root.rotationQuaternion = rotationQuaternion(B, metadata.rotation_deg);
          entry.root.scaling.copyFromFloats(...toView(metadata.scale));
          entry.visible = metadata.visible; entry.opacity = metadata.opacity; entry.wireframe = metadata.wireframe; entry.locked = metadata.locked === true;
          entry.material.alpha = entry.opacity; entry.material.wireframe = entry.wireframe;
          entry.material.transparencyMode = entry.opacity < 1 ? B.Material.MATERIAL_ALPHABLEND : B.Material.MATERIAL_OPAQUE;
          entry.persistenceChoice = "session"; entry.portableSource = true;
          if (options.linked && metadata.asset_path) {
            entry.assetPath=metadata.asset_path;entry.savedId=metadata.id;
            entry.persistenceChoice="saved";entry.portableSource=false;entry.savedSnapshot="";
          }
          entry.root.computeWorldMatrix(true);
          if (!bounds(entry)) throw new Error("Reference transform produces invalid bounds: " + entry.name);
        }
      } catch (error) { staged.forEach(disposeEntry); throw error; }
      return {
        commit() {
          if (finished || committed) throw new Error("Reference transaction is no longer available.");
          committed = true;
          for (const entry of previous) entry.root.setEnabled(false);
          entries.splice(0, entries.length, ...staged); unavailable.clear();
          for (const entry of staged) entry.root.setEnabled(entry.visible);
          selected = staged[view.selectedIndex]?.id || staged[staged.length-1]?.id || null;
          setMode(view.mode || "move"); changed();
        },
        rollback() {
          if (finished) return; finished = true;
          if (committed) {
            entries.splice(0, entries.length, ...previous); unavailable.clear();
            for (const [id, record] of previousMissing) unavailable.set(id, record);
            for (const entry of previous) entry.root.setEnabled(entry.visible);
            selected = previousSelection;
          }
          staged.forEach(disposeEntry); setMode(previousMode); updatePersistenceControls();
        },
        finalize() {
          if (finished || !committed) return; finished = true;
          previous.forEach(disposeEntry); updateFields(); updateMissingControls();
        },
      };
    }
    function getTransform(entry = selectedEntry()) {
      if (!entry) return null;
      return { position: toFE(entry.root.position.asArray()),
        rotation: rotationAngles(entry.root.rotationQuaternion || B.Quaternion.Identity()),
        scale: toFE(entry.root.scaling.asArray()) };
    }
    function setTransform(values) {
      const entry = selectedEntry(); if (!entry) return;
      if (entry.locked) { updateFields(); return false; }
      for (const key of ["position", "rotation", "scale"]) {
        if (!values[key]) continue;
        if (values[key].length !== 3 || !values[key].every(Number.isFinite) || key === "scale" && values[key].some((v) => v <= 0))
          throw new Error(key === "scale" ? "Scale values must be positive finite numbers." : "Transform values must be finite numbers.");
      }
      if (values.position) entry.root.position.copyFromFloats(...toView(values.position));
      if (values.rotation) entry.root.rotationQuaternion = rotationQuaternion(B, values.rotation);
      if (values.scale) entry.root.scaling.copyFromFloats(...toView(values.scale));
      entry.root.computeWorldMatrix(true); updateFields(); changed();
    }
    function ensureGizmos() {
      if (gizmos) return;
      gizmos = new B.GizmoManager(scene);
      gizmos.usePointerToAttachGizmos = false;
      gizmos.clearGizmoOnEmptyPointerEvent = false;
      gizmos.positionGizmoEnabled = true; gizmos.rotationGizmoEnabled = true; gizmos.scaleGizmoEnabled = true;
      for (const kind of ["positionGizmo", "rotationGizmo", "scaleGizmo"]) {
        const gizmo = gizmos.gizmos[kind];
        gizmo.updateGizmoRotationToMatchAttachedMesh = kind === "scaleGizmo";
        for (const [axis, color] of [["xGizmo", "#4cc38a"], ["yGizmo", "#56a8f5"], ["zGizmo", "#ef5f6b"]]) {
          const axisGizmo = gizmo[axis];
          axisGizmo.coloredMaterial.diffuseColor = B.Color3.FromHexString(color);
          axisGizmo.coloredMaterial.emissiveColor = B.Color3.FromHexString(color).scale(0.45);
        }
        gizmo.onDragStartObservable.add(() => { dragging = !selectedEntry()?.locked; });
        gizmo.onDragObservable.add(updateFields);
        gizmo.onDragEndObservable.add(() => {
          dragging = false; ignoreUntil = Date.now() + 150;
          const entry = selectedEntry();
          if (entry && !entry.locked) {
            for (const axis of ["x", "y", "z"]) entry.root.scaling[axis] = Math.max(1e-6, entry.root.scaling[axis]);
          }
          updateFields(); changed();
        });
      }
    }
    function setMode(next) {
      if (!["move", "rotate", "scale", "off"].includes(next)) throw new Error("Unknown reference transform mode");
      mode = next;
      const entry = selectedEntry(), editable = !!entry && !entry.locked;
      if (editable) ensureGizmos();
      if (gizmos) {
        gizmos.positionGizmoEnabled = editable && mode === "move";
        gizmos.rotationGizmoEnabled = editable && mode === "rotate";
        gizmos.scaleGizmoEnabled = editable && mode === "scale";
        gizmos.attachToNode(editable && entry.visible && mode !== "off" ? entry.root : null);
      }
      updateFields();
    }
    function setLocked(value) {
      const entry = selectedEntry(); if (!entry) return false;
      if (typeof value !== "boolean") throw new Error("Reference placement lock must be Boolean.");
      entry.locked = value;
      if (value) dragging = false;
      setMode(mode); changed(); return true;
    }
    function applySource(entry) {
      entry.conversion.scaling.setAll(UNITS[entry.units]);
      entry.conversion.rotationQuaternion = entry.axis === "fe" ? new B.Quaternion(-0.5, -0.5, -0.5, 0.5) :
        B.Quaternion.RotationAxis(B.Axis.Y, -Math.PI / 2);
      entry.conversion.computeWorldMatrix(true);
    }
    function setSource(values) {
      const entry = selectedEntry(); if (!entry) return;
      if (entry.locked) { updateFields(); return false; }
      const units = values.units || entry.units, axis = values.axis || entry.axis;
      if (!UNITS[units] || !["fe", "yup"].includes(axis)) throw new Error("Unsupported reference units or source axes.");
      entry.units = units; entry.axis = axis; applySource(entry); updateFields(); changed();
    }
    function select(id) {
      selected = entries.some((entry) => entry.id === Number(id)) ? Number(id) : null;
      setMode(mode); changed();
    }
    function bounds(entry = selectedEntry()) {
      if (!entry) return null;
      const minimum = new B.Vector3(Infinity, Infinity, Infinity), maximum = new B.Vector3(-Infinity, -Infinity, -Infinity);
      for (const mesh of entry.meshes) {
        mesh.computeWorldMatrix(true);
        const box = mesh.getBoundingInfo().boundingBox;
        minimum.minimizeInPlace(box.minimumWorld); maximum.maximizeInPlace(box.maximumWorld);
      }
      return [minimum, maximum].every((v) => v.asArray().every(Number.isFinite)) ? { minimum, maximum } : null;
    }
    function fit() {
      const b = bounds(); if (!b) return;
      const center = b.minimum.add(b.maximum).scale(0.5), radius = Math.max(0.01, b.maximum.subtract(b.minimum).length() / 2);
      const aspect = engine.getRenderWidth() / Math.max(1, engine.getRenderHeight());
      const half = camera.fov / 2, angle = Math.max(0.03, Math.min(half, Math.atan(Math.tan(half) * aspect)));
      camera.setTarget(center,false,true,true); camera.radius = radius * 1.25 / Math.sin(angle);
      camera.upperRadiusLimit = Math.max(camera.upperRadiusLimit || 0, camera.radius * 3);
      camera.lowerRadiusLimit = Math.min(camera.lowerRadiusLimit || 0.05, radius * 0.05);
      camera.minZ = Math.min(camera.minZ, radius * 0.001);
      camera.maxZ = Math.max(camera.maxZ, camera.radius * 4);
    }
    function setVisible(visible) {
      const entry = selectedEntry(); if (!entry) return;
      entry.visible = !!visible; entry.root.setEnabled(entry.visible); setMode(mode); changed();
    }
    function setAllVisible(visible) {
      let modified=false;
      for(const entry of entries){if(entry.visible!==!!visible)modified=true;entry.visible=!!visible;entry.root.setEnabled(entry.visible);}
      setMode(mode);updateFields();if(modified)changed();
    }
    function setAppearance(values) {
      const entry = selectedEntry(); if (!entry) return;
      if (values.opacity !== undefined) entry.opacity = Math.max(0.03, Math.min(1, Number(values.opacity)));
      if (values.wireframe !== undefined) entry.wireframe = !!values.wireframe;
      entry.material.alpha = entry.opacity; entry.material.wireframe = entry.wireframe;
      entry.material.transparencyMode = entry.opacity < 1 ? B.Material.MATERIAL_ALPHABLEND : B.Material.MATERIAL_OPAQUE;
      updateFields(); changed();
    }
    function reset() { setTransform({ position: [0,0,0], rotation: [0,0,0], scale: [1,1,1] }); }
    function remove(id = selected) {
      const index = entries.findIndex((entry) => entry.id === Number(id)); if (index < 0) return;
      const [entry] = entries.splice(index, 1);
      if (gizmos) gizmos.attachToNode(null);
      entry.container.dispose(); entry.root.dispose(); entry.material.dispose();
      select(entries.length ? entries[Math.min(index, entries.length-1)].id : null);
      notify("Removed reference " + entry.name);
    }
    async function importFile(file, settings = {}) {
      if (disposed) throw new Error("Reference viewer has been disposed.");
      const extension = "." + String(file.name || "").split(".").pop().toLowerCase();
      if (![".stl", ".obj", ".glb"].includes(extension)) throw new Error("Choose an STL, OBJ or GLB file.");
      const units = settings.units || "m", axis = settings.axis || (extension === ".glb" ? "yup" : "fe");
      if (!UNITS[units] || !["fe", "yup"].includes(axis)) throw new Error("Unsupported reference units or axes.");
      loading++; if (controls.file) controls.file.disabled = true;
      const activity = globalThis.WingActivity, token = activity?.begin("Loading 3D reference", {detail:file.name});
      notify("Loading reference " + file.name + "…");
      let container = null, entry = null, previousSelection = selected;
      try {
        await activity?.yieldFrame();
        const source = await fileSource(file, extension);
        if (B.STLFileLoader) B.STLFileLoader.DO_NOT_ALTER_FILE_COORDINATES = true;
        // STL's synchronous plugin accepts ArrayBuffer directly; the generic
        // loader only accepts binary views for plugins implementing loadFile.
        container = extension === ".stl" ? new B.STLFileLoader().loadAssetContainer(scene, source, "") : await B.LoadAssetContainerAsync(source, scene, {
          pluginExtension: extension, name: file.name,
          pluginOptions: { obj: { skipMaterials: true }, gltf: { skipMaterials: true, animationStartMode: 0 } }
        });
        const meshes = container.meshes.filter((mesh) => mesh.getTotalVertices() > 0);
        if (!meshes.length) throw new Error("The reference has no triangle geometry.");
        for (const mesh of meshes) {
          const xyz = mesh.getVerticesData(B.VertexBuffer.PositionKind);
          if (!xyz || !xyz.every(Number.isFinite) || mesh.getTotalIndices() < 3)
            throw new Error("The reference contains invalid or empty geometry.");
        }
        if (disposed) throw new Error("Reference viewer was closed during import.");
        const root = new B.TransformNode("reference-" + (++sequence), scene);
        if (settings.detached) root.setEnabled(false);
        root.rotationQuaternion = B.Quaternion.Identity();
        const conversion = new B.TransformNode(root.name + "-source", scene); conversion.parent = root;
        const material = new B.StandardMaterial(root.name + "-material", scene);
        material.diffuseColor = B.Color3.FromHexString("#c5b2df"); material.emissiveColor = material.diffuseColor.scale(0.18);
        material.specularColor.set(0.1, 0.1, 0.1); material.backFaceCulling = false; material.twoSidedLighting = true;
        entry = { id: sequence, name: file.name, root, conversion, container, material, meshes, sourceFile:file,
          persistenceChoice:settings.savedRecord ? "saved" : "pending", assetPath:settings.savedRecord && settings.savedRecord.asset_path || null,
          savedId:settings.savedRecord && settings.savedRecord.id || null, savedSnapshot:"",
          triangles: meshes.reduce((n, mesh) => n + Math.floor(mesh.getTotalIndices()/3), 0),
          units, axis, opacity: 0.35, wireframe: false, visible: true, locked: false };
        const importedRoots = [...container.meshes, ...container.transformNodes].filter((node) => !node.parent);
        for (const name of ["lights", "cameras", "animationGroups", "particleSystems"]) {
          for (const item of container[name] || []) item.dispose();
          container[name] = [];
        }
        for (const mesh of container.meshes) {
          // Imported names can collide with the FEM's disposable axis-* helpers.
          mesh.name = root.name + "-" + mesh.name;
          mesh.isPickable = false; mesh.renderingGroupId = 0;
          mesh.metadata = { ...(mesh.metadata || {}), wingReferenceId: entry.id };
          if (mesh.getTotalVertices() > 0) mesh.material = material;
        }
        applySource(entry); container.addAllToScene();
        for (const node of importedRoots) node.parent = conversion;
        if (!bounds(entry)) throw new Error("The reference bounds are not finite.");
        if (settings.detached) return entry;
        previousSelection = selected;
        entries.push(entry); selected = entry.id;
        setAppearance({}); setMode(mode);
        notify("Loaded " + file.name + ": " + entry.triangles.toLocaleString() + " triangles", "good");
        changed(); return entry;
      } catch (error) {
        if (entry) {
          const index = entries.indexOf(entry); if (index >= 0) entries.splice(index, 1);
          if (selected === entry.id) selected = previousSelection;
          if (gizmos) gizmos.attachToNode(null);
        }
        if (container) container.dispose();
        if (entry) { entry.root.dispose(); entry.material.dispose(); }
        try { setMode(mode); } catch (_) { updateFields(); }
        notify("Reference import failed: " + error.message, "err");
        throw error;
      } finally {
        activity?.end(token);
        loading--; if (controls.file) controls.file.disabled = loading > 0;
      }
    }
    function renderControls() {
      if (!host) return;
      const doc = host.ownerDocument;
      const node = (tag, text, className) => { const el = doc.createElement(tag); if (text) el.textContent = text; if (className) el.className = className; return el; };
      const button = (text, id, action) => { const el = node("button", text, "mini"); el.id = id; el.type = "button"; el.onclick = action; return el; };
      host.replaceChildren(); host.classList.add("reference-panel");
      const intro = node("div", null, "reference-intro");
      intro.append(node("p", "Overlay local geometry and align it with the FEM."));
      intro.append(button("?", "reference-help", () => {
        if (options.onHelp) options.onHelp("Reference geometry", HELP);
        else { controls.help.hidden = !controls.help.hidden; }
      })); host.append(intro);
      controls.help = node("div", null, "reference-help"); controls.help.hidden = true;
      HELP.forEach((text) => controls.help.append(node("p", text))); host.append(controls.help);
      const upload = node("label", "Import STL, OBJ or GLB", "reference-upload");
      controls.file = node("input"); controls.file.type = "file"; controls.file.id = "reference-file";
      controls.file.accept = ".stl,.obj,.glb"; controls.file.multiple = true;
      controls.file.onchange = async () => {
        for (const file of Array.from(controls.file.files || [])) { try { await importFile(file); } catch (_) {} }
        controls.file.value = "";
      }; upload.append(controls.file); host.append(upload);
      controls.status = node("p", "Choose whether each import stays in this session or is saved with the input.", "reference-status"); controls.status.id = "reference-status"; controls.status.setAttribute("role", "status"); host.append(controls.status);
      controls.persistence = node("div", null, "reference-persistence"); controls.persistence.hidden = true; host.append(controls.persistence);
      controls.savedStatus = node("p", "", "reference-saved-status"); controls.savedStatus.id = "reference-saved-status"; controls.persistence.append(controls.savedStatus);
      controls.prompt = node("div", null, "reference-persist-prompt"); controls.prompt.id = "reference-persist-prompt";
      controls.prompt.append(node("p", "Save a copy beside this input and restore its units, axes and placement in future sessions? The browser cannot provide the original absolute path."));
      controls.saveCopy = button("Save a portable copy", "reference-save-copy", () => enroll().catch(()=>{}));
      controls.sessionOnly = button("Session only", "reference-session-only", () => { const entry=selectedEntry(); if(entry)entry.persistenceChoice="session"; updatePersistenceControls(); });
      controls.prompt.append(controls.saveCopy,controls.sessionOnly); controls.persistence.append(controls.prompt);
      controls.enroll = button("Save with input…", "reference-enroll", () => {const entry=selectedEntry();if(entry)entry.persistenceChoice="pending";updatePersistenceControls();});
      controls.saveSettings = button("Save reference settings", "reference-save-settings", () => saveSettings().catch(()=>{}));
      controls.forget = button("Forget saved entry", "reference-forget", () => forget().catch(()=>{}));
      controls.persistence.append(controls.enroll,controls.saveSettings,controls.forget);
      controls.savedPath = node("p", "", "reference-saved-path");controls.savedPath.id="reference-saved-path";controls.persistence.append(controls.savedPath);
      controls.missing = node("div",null,"reference-missing-list");controls.missing.id="reference-missing-list";host.append(controls.missing);
      controls.empty = node("p", "No reference loaded.", "reference-empty"); host.append(controls.empty);
      controls.content = node("div", null, "reference-content"); controls.content.hidden = true; host.append(controls.content);
      const content = controls.content;
      const labelSelect = (label, id, choices, action) => {
        const row = node("label", label, "reference-field"), select = node("select"); select.id = id;
        for (const [value, text] of choices) { const option = node("option", text); option.value = value; select.append(option); }
        select.onchange = action; row.append(select); content.append(row); return select;
      };
      controls.list = labelSelect("Selected reference", "reference-select", [], (event) => select(event.target.value));
      const lockRow=node("label",null,"reference-check reference-lock");
      controls.lock=node("input");controls.lock.type="checkbox";controls.lock.id="reference-lock";
      controls.lock.setAttribute("aria-describedby","reference-lock-status");controls.lock.onchange=event=>setLocked(event.target.checked);
      lockRow.append(controls.lock,node("span","Lock placement"));content.append(lockRow);
      controls.lockStatus=node("p","","reference-lock-status");controls.lockStatus.id="reference-lock-status";controls.lockStatus.setAttribute("role","status");content.append(controls.lockStatus);
      controls.units = labelSelect("Source units", "reference-units", [["m","Metres"],["mm","Millimetres"],["cm","Centimetres"],["inch","Inches"]], (event) => setSource({units:event.target.value}));
      controls.axis = labelSelect("Source axes", "reference-axis", [["fe","FE x/y/z · Z up"],["yup","X right · Y up (GLB)"]], (event) => setSource({axis:event.target.value}));
      controls.info = node("p", "", "reference-info"); content.append(controls.info);
      const modes = node("div", null, "reference-modes"); controls.modes = {};
      for (const [key, label] of [["move","Move"],["rotate","Rotate"],["scale","Scale"],["off","Off"]]) {
        controls.modes[key] = button(label, "reference-mode-" + key, () => setMode(key)); modes.append(controls.modes[key]);
      } content.append(modes);
      content.append(node("p", "Handles: x red · y green · z blue", "reference-info"));
      for (const [key, label] of [["position","Position (m)"],["rotation","Rotation (°)"],["scale","Scale"]]) {
        const group = node("fieldset", null, "reference-transform"); group.append(node("legend", label)); controls[key] = [];
        for (let a = 0; a < 3; a++) {
          const axis = "xyz"[a], row = node("label", axis), input = node("input"); input.type = "number"; input.step = "any";
          input.id = "reference-" + key + "-" + axis; input.setAttribute("aria-label", "Reference " + key + " " + axis);
          if (key === "scale") input.min = "0.000001";
          input.onchange = () => {
            try { const values = controls[key].map((el) => el.value.trim() === "" ? NaN : Number(el.value)); setTransform({[key]:values}); input.setCustomValidity(""); }
            catch (error) { input.setCustomValidity(error.message); input.reportValidity(); }
          };
          row.append(input); group.append(row); controls[key].push(input);
        } content.append(group);
      }
      const check = (label, id, action) => { const row = node("label", null, "reference-check"), input = node("input"); input.type = "checkbox"; input.id = id; input.onchange = action; row.append(input,node("span",label)); content.append(row); return input; };
      controls.visible = check("Show reference", "reference-visible", (event) => setVisible(event.target.checked));
      controls.wireframe = check("Wireframe", "reference-wireframe", (event) => setAppearance({wireframe:event.target.checked}));
      const opacity = node("label", "Opacity", "reference-field"); controls.opacity = node("input"); controls.opacity.type = "range"; controls.opacity.min = "0.03"; controls.opacity.max = "1"; controls.opacity.step = "0.01"; controls.opacity.id = "reference-opacity";
      controls.opacity.oninput = (event) => setAppearance({opacity:Number(event.target.value)}); opacity.append(controls.opacity); content.append(opacity);
      const actions = node("div", null, "reference-actions");
      controls.reset=button("Reset transform", "reference-reset", reset);
      actions.append(button("Fit reference", "reference-fit", fit), controls.reset, button("Remove", "reference-remove", async () => {
        const entry=selectedEntry(); if(!entry||saving)return;
        try { if(entry.assetPath)await forget(entry); remove(entry.id); } catch (_) {}
      })); content.append(actions);
    }
    function dispose() {
      disposed = true;
      if (gizmos) { gizmos.dispose(); gizmos = null; }
      for (const entry of entries.splice(0)) { entry.container.dispose(); entry.root.dispose(); entry.material.dispose(); }
      unavailable.clear(); selected = null; if (host) host.replaceChildren();
    }
    const api = { entries, get active() { return selectedEntry(); }, get gizmos() { return gizmos; },
      get mode() { return mode; }, get loading() { return loading; }, get saving() { return saving; }, importFile, select, setTransform, getTransform,
      setSource, setMode, setLocked, setVisible, setAllVisible, setAppearance, reset, remove, fit, bounds, dispose,
      serialize, restore, markSaved, enroll, forget, saveSettings, exportPortable, prepareTomlRecords, stagePortable,
      isInteracting: () => dragging || Date.now() < ignoreUntil };
    renderControls(); return api;
  }
  return { create, toView, toFE, rotationQuaternion, rotationAngles, glbMetadata, HELP };
});
