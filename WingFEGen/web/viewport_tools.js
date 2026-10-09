(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingViewportTools=api;})(globalThis,function(){
 "use strict";
 // With the right-handed FE -> Babylon [y,z,x] mapping, +PI/2 puts FE +X
 // downwards on screen and FE +Y to the right.
 const VIEWS={top:[Math.PI/2,.001],iso:[-Math.PI/4,Math.acos(1/Math.sqrt(3))],side:[Math.PI,Math.PI/2],front:[-Math.PI/2,Math.PI/2]};
 function stopMotion(camera){for(const key of["inertialAlphaOffset","inertialBetaOffset","inertialRadiusOffset","inertialPanningX","inertialPanningY"])camera[key]=0;}
 function center(camera,target){
  // ArcRotateCamera.setTarget normally rebuilds angles from the old eye.
  // Translate both eye and target instead, retaining orientation and scale.
  const {alpha,beta,radius}=camera;stopMotion(camera);
  camera.setTarget(target,false,true,true);camera.alpha=alpha;camera.beta=beta;camera.radius=radius;
  camera.targetScreenOffset?.set(0,0);camera.getViewMatrix(true);
 }
 function validateState(value){
  if(value==null)return{collapsed:false};
  if(typeof value!=="object"||Array.isArray(value)||Object.keys(value).some(key=>key!=="collapsed")||(value.collapsed!==undefined&&typeof value.collapsed!=="boolean"))throw new Error("Camera toolbar settings require a boolean collapsed value.");
  return{collapsed:value.collapsed===true};
 }
 const ICONS={top:'<path d="M3 15 10 4h4l7 11-9-2zM12 4v15"/>',iso:'<path d="m12 2 9 5v10l-9 5-9-5V7zm-9 5 9 5 9-5M12 12v10"/>',side:'<path d="m3 15 17-5-5 7H3zm5-2V8l4 4"/>',front:'<path d="M2 14h20M12 6v14M9 14a3 3 0 1 1 6 0"/>',projection:'<path d="M3 5h7v14H3zm11 2 7-3v16l-7-3zM10 5l11-1M10 19l11 1"/>'};
 function create({BABYLON:B=globalThis.BABYLON,scene,camera,engine,host,onView,onChange=()=>{},displayActions=[],ground=null,translucency=null,inspection=null,onSaveSVG=null,onExportError=null}){
  const labels={top:["Top","Top: look down global -Z, with global +X downwards"],iso:["Isometric","Isometric view"],side:["Side","Side: look along global +Y (span)"],front:["Front","Front: look aft along global +X"]};
  host.innerHTML="";host.setAttribute("role","toolbar");host.setAttribute("aria-label","Model views and display controls");
  const buttons={};let disposed=false,collapsed=false;
  for(const name of [...Object.keys(VIEWS),"projection"]){
   const button=host.ownerDocument.createElement("button");button.type="button";button.id="view-"+name;button.className="viewport-tool";
   button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true">'+ICONS[name]+'</svg><span></span>';host.appendChild(button);buttons[name]=button;
   if(name!=="projection"){button.title=labels[name][1];button.setAttribute("aria-label",labels[name][0]+" view");button.querySelector("span").textContent=labels[name][0];button.onclick=()=>{onView(name,...VIEWS[name]);onChange();};}
  }
  const actionButtons=[];
  let inspectionFilter=null,inspectionSelect=null,inspectionOptions="",groundControl=null,groundInput=null,groundCaption=null,translucencyControl=null,translucencyInput=null,translucencyCaption=null;
  for(const action of displayActions){
   const button=host.ownerDocument.createElement("button");button.type="button";button.id="view-"+action.id;button.className="viewport-tool viewport-display-tool";
   button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true">'+action.icon+'</svg><span></span>';host.appendChild(button);buttons[action.id]=button;actionButtons.push({action,button});
   button.onclick=()=>{action.toggle();syncDisplay();};
   if(action.id==='surfaces'&&translucency){
    translucencyControl=host.ownerDocument.createElement('label');translucencyControl.className='viewport-translucency';translucencyControl.id='viewport-translucency';
    translucencyCaption=host.ownerDocument.createElement('span');
    translucencyInput=host.ownerDocument.createElement('input');translucencyInput.type='range';translucencyInput.min='0';translucencyInput.max='100';translucencyInput.step='1';translucencyInput.id='view-translucency';translucencyInput.setAttribute('aria-label','Structural surface translucency percentage');translucencyInput.title='0% opaque, 100% transparent. Changes appearance only.';
    translucencyInput.oninput=()=>{translucency.change(Number(translucencyInput.value));syncDisplay();};
    translucencyControl.append(translucencyCaption,translucencyInput);host.appendChild(translucencyControl);
   }
   if(action.id==='ground'&&ground){
    groundControl=host.ownerDocument.createElement('label');groundControl.className='viewport-ground-height';groundControl.id='viewport-ground-height';
    const caption=host.ownerDocument.createElement('span');caption.textContent='Ground Z (m)';groundCaption=caption;
    groundInput=host.ownerDocument.createElement('input');groundInput.type='number';groundInput.step='any';groundInput.id='view-ground-z';groundInput.setAttribute('aria-label','Ground plane global Z in metres');groundInput.title='Ground plane elevation in global Z (metres). This display setting is saved with the Study and does not change the model.';
    groundInput.oninput=()=>ground.change(groundInput.value,false);groundInput.onchange=()=>ground.change(groundInput.value,true);
    groundControl.append(caption,groundInput);host.appendChild(groundControl);
   }
  }
  if(inspection){
   const button=host.ownerDocument.createElement("button");button.type="button";button.id="view-inspect";button.className="viewport-tool viewport-inspect-tool";
   button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10" cy="10" r="6"/><path d="m14.5 14.5 6 6M10 7v6M7 10h6"/></svg><span>Inspect</span>';host.appendChild(button);buttons.inspect=button;
   button.onclick=()=>{inspection.activate();syncInspection();};
   inspectionFilter=host.ownerDocument.createElement("label");inspectionFilter.id="viewport-inspection-filter";inspectionFilter.className="viewport-inspection-filter";
   const caption=host.ownerDocument.createElement("span");caption.textContent="Inspect entity";
   inspectionSelect=host.ownerDocument.createElement("select");inspectionSelect.id="view-inspect-entity";inspectionSelect.setAttribute("aria-label","Entity to inspect in viewport");inspectionSelect.title="Choose an entity type and open Inspect. Left-click a matching visible entity in the model.";
   inspectionFilter.append(caption,inspectionSelect);host.appendChild(inspectionFilter);
   inspectionSelect.onchange=()=>{const value=inspectionSelect.value;inspection.activate();inspection.select(value);syncInspection();};
  }
  if(onSaveSVG){
   const exportTitle="Save visible geometry and color scales as flat-color SVG vectors. Textures, reflections and screen labels are omitted; intersecting surfaces use approximate depth ordering.";
   const button=host.ownerDocument.createElement("button");button.type="button";button.id="view-save-svg";button.className="viewport-tool viewport-export-tool";
   button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 3h10l4 4v14H5zM14 3v5h5M8 12l-2 3 2 3M16 12l2 3-2 3M13 11l-2 8"/></svg><span>Save SVG</span>';button.title=exportTitle;button.setAttribute("aria-label","Save viewport SVG");host.appendChild(button);buttons.saveSVG=button;
   button.onclick=async()=>{if(button.disabled||disposed)return;button.disabled=true;button.title=exportTitle;button.setAttribute("aria-busy","true");button.querySelector("span").textContent="Saving…";try{await onSaveSVG();}catch(error){if(!disposed){button.title="SVG export failed: "+(error?.message||String(error));onExportError?.(error);}}finally{if(!disposed){button.disabled=false;button.removeAttribute("aria-busy");button.querySelector("span").textContent="Save SVG";}}};
  }
  function syncInspection(){
   if(!inspection)return;
   const value=inspection.read(),options=value.options||[],signature=JSON.stringify(options.map(option=>[option.value,option.label,option.disabled===true]));
   if(signature!==inspectionOptions){inspectionOptions=signature;inspectionSelect.replaceChildren();for(const item of options){const option=host.ownerDocument.createElement("option");option.value=item.value;option.textContent=item.label;option.disabled=item.disabled===true;inspectionSelect.appendChild(option);}}
   if(options.some(option=>option.value===value.value))inspectionSelect.value=value.value;
   inspectionSelect.disabled=value.disabled===true||!options.length;
   const active=value.active===true,button=buttons.inspect;button.disabled=value.disabled===true;button.setAttribute("aria-pressed",String(active));button.setAttribute("aria-label","Inspect entities");button.title=active?"Inspect is active. Left-click a visible entity matching the selected type.":"Open Inspect to pick visible entities and see their properties and results.";
  }
  function syncDisplay(){for(const {action,button} of actionButtons){const value=action.read();button.disabled=value.disabled===true;button.querySelector("span").textContent=value.label;button.title=value.title;button.setAttribute("aria-label",value.title);button.setAttribute("aria-pressed",String(!!value.active));}if(groundInput){const value=ground.read();groundControl.hidden=collapsed||value.visible===false;if(groundInput.value!==String(value.value))groundInput.value=String(value.value??'');groundInput.disabled=value.disabled===true;groundInput.setCustomValidity(value.error||'');groundCaption.textContent=value.units==='source'?'Ground Z (source)':'Ground Z (m)';groundInput.title='Ground plane elevation in global Z ('+(value.units==='source'?'source deck units, no conversion':'metres')+'). This display setting does not change the model.';groundInput.setAttribute('aria-label',groundInput.title);}if(translucencyInput){const value=translucency.read();translucencyControl.hidden=collapsed||value.visible===false;translucencyInput.value=String(value.value??45);translucencyCaption.textContent='Translucency '+translucencyInput.value+'%';translucencyInput.setAttribute('aria-valuetext',translucencyInput.value+' percent');}syncInspection();}
  syncDisplay();
  const hide=host.ownerDocument.createElement("button"),show=host.ownerDocument.createElement("button");
  hide.type=show.type="button";hide.id="viewport-tools-hide";show.id="viewport-tools-show";
  hide.className="viewport-tool viewport-tools-hide";show.className="viewport-tools-show";
  hide.title="Hide camera toolbar";show.title="Show camera toolbar";
  hide.setAttribute("aria-label",hide.title);show.setAttribute("aria-label",show.title);
  hide.setAttribute("aria-controls",host.id||"viewport-tools");show.setAttribute("aria-controls",host.id||"viewport-tools");
  hide.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m8 5 7 7-7 7"/></svg><span>Hide</span>';
  show.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h5v5H5zm9 0h5v5h-5zM5 14h5v5H5zm9 0h5v5h-5z"/></svg>';
  host.appendChild(hide);host.appendChild(show);
  function collapse(value,notify=false,focus=false){
   const changed=collapsed!==value;collapsed=value;host.classList.toggle("is-collapsed",collapsed);
   for(const button of Object.values(buttons))button.hidden=collapsed;
   if(inspectionFilter)inspectionFilter.hidden=collapsed;
   if(groundControl)groundControl.hidden=collapsed||ground.read().visible===false;
   if(translucencyControl)translucencyControl.hidden=collapsed||translucency.read().visible===false;
   hide.hidden=collapsed;show.hidden=!collapsed;
   hide.setAttribute("aria-expanded",String(!collapsed));show.setAttribute("aria-expanded",String(!collapsed));
   if(focus)(collapsed?show:hide).focus();
   if(changed&&notify)onChange();
  }
  hide.onclick=()=>collapse(true,true,true);show.onclick=()=>collapse(false,true,true);collapse(false);
  let ratio=Math.tan(camera.fov/2),mode=camera.mode,lastRadius=-1,lastAspect=-1;
  const aspect=()=>Math.max(.01,engine.getRenderWidth()/Math.max(1,engine.getRenderHeight()));
  const verticalRatio=()=>camera.fovMode===B.Camera.FOVMODE_HORIZONTAL_FIXED?Math.tan(camera.fov/2)/aspect():Math.tan(camera.fov/2);
  function controls(){const parallel=camera.mode===B.Camera.ORTHOGRAPHIC_CAMERA;buttons.projection.setAttribute("aria-pressed",String(parallel));buttons.projection.setAttribute("aria-label",parallel?"Parallel projection: switch to perspective":"Perspective projection: switch to parallel");buttons.projection.title=parallel?"Parallel (orthographic) projection. Click for perspective.":"Perspective projection. Click for parallel (orthographic).";buttons.projection.querySelector("span").textContent=parallel?"Parallel":"Perspective";}
  function refresh(adopt=false){
   const parallel=camera.mode===B.Camera.ORTHOGRAPHIC_CAMERA,a=aspect();
   if(adopt||camera.mode!==mode){mode=camera.mode;ratio=parallel&&Number.isFinite(camera.orthoTop)&&Number.isFinite(camera.orthoBottom)&&camera.orthoTop>camera.orthoBottom?(camera.orthoTop-camera.orthoBottom)/(2*camera.radius):verticalRatio();lastRadius=-1;controls();}
   if(parallel&&(camera.radius!==lastRadius||a!==lastAspect)){const h=Math.max(1e-7,camera.radius*ratio);camera.orthoTop=h;camera.orthoBottom=-h;camera.orthoLeft=-h*a;camera.orthoRight=h*a;}
   lastRadius=camera.radius;lastAspect=a;
  }
  function projection(parallel){
   if(parallel===(camera.mode===B.Camera.ORTHOGRAPHIC_CAMERA))return;
   if(parallel){ratio=verticalRatio();camera.mode=B.Camera.ORTHOGRAPHIC_CAMERA;}
   else{const half=(camera.orthoTop-camera.orthoBottom)/2;if(Number.isFinite(half)&&half>0)camera.radius=half/verticalRatio();camera.mode=B.Camera.PERSPECTIVE_CAMERA;}
   mode=camera.mode;lastRadius=-1;refresh();controls();onChange();
  }
  function fit(){ratio=verticalRatio();lastRadius=-1;refresh();}
  buttons.projection.onclick=()=>projection(camera.mode!==B.Camera.ORTHOGRAPHIC_CAMERA);
  const observer=scene.onBeforeRenderObservable.add(()=>refresh());refresh(true);
  return{refresh,fit,projection,syncDisplay,syncInspection,capture:()=>({collapsed}),restore(value){collapse(validateState(value).collapsed);syncDisplay();},setCollapsed(value){collapse(validateState({collapsed:value}).collapsed,true);},destroy(){disposed=true;scene.onBeforeRenderObservable.remove(observer);host.replaceChildren();host.classList.remove("is-collapsed");}};
 }
 return{VIEWS,validateState,create,center,stopMotion};
});
