/* Display-only measurements and the selected element's local frame. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingGeometryTools=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const sub=(a,b)=>a.map((v,i)=>v-b[i]),add=(a,b)=>a.map((v,i)=>v+b[i]),scale=(a,s)=>a.map(v=>v*s);
 const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const unit=a=>{const n=Math.hypot(...a);if(!(n>1e-12))throw Error("The displayed element has a degenerate frame.");return scale(a,1/n);};
 const point=(p,n)=>Array.from(p.slice(3*n,3*n+3)),center=points=>points.reduce((a,p)=>add(a,scale(p,1/points.length)),[0,0,0]);
 const toFE=p=>[p[2],p[0],p[1]],toView=p=>[p[1],p[2],p[0]];
 function distance(a,b){const delta=toFE(sub(b,a));return{a:toFE(a),b:toFE(b),delta,length:Math.hypot(...delta)};}
 function closestSegment(p,a,b){const ab=sub(b,a),n=dot(ab,ab),t=n?Math.max(0,Math.min(1,dot(sub(p,a),ab)/n)):0;return add(a,scale(ab,t));}

 /** Transport the reference MCID frame by the shell's displayed in-plane map.
  * This is a geometric display frame, not a transformation of stress results.
  */
 function shellFrame(reference,current,x,y){
  const origin=center(current),base=center(reference),xx=unit(x),yy=unit(y);
  let uu=0,uv=0,vv=0,pu=[0,0,0],pv=[0,0,0],normal=[0,0,0];
  for(let i=0;i<reference.length;i++){
   const r=sub(reference[i],base),p=sub(current[i],origin),u=dot(r,xx),v=dot(r,yy);
   uu+=u*u;uv+=u*v;vv+=v*v;pu=add(pu,scale(p,u));pv=add(pv,scale(p,v));
   normal=add(normal,cross(p,sub(current[(i+1)%current.length],origin)));
  }
  const determinant=uu*vv-uv*uv;
  if(!(determinant>1e-20*Math.max(1,uu*vv)))throw Error("The displayed shell has a degenerate frame.");
  const z=unit(normal),mapped=scale(sub(scale(pu,vv),scale(pv,uv)),1/determinant);
  const displayedX=unit(sub(mapped,scale(z,dot(mapped,z))));
  return {origin,x:displayedX,y:unit(cross(z,displayedX)),z};
 }
 function barFrame(reference,current,orientation,section,rotations,rotationScale,sections){
  const baseline=sections.frame(reference[0],reference[1],orientation),end=[0,1].map(i=>sections.frame(current[0],current[1],rotations?sections.rotate(baseline.y,rotations[i],rotationScale):orientation));
  const avgY=scale(add(end[0].y,end[1].y),.5),avgZ=scale(add(end[0].z,end[1].z),.5);
  const frame=sections.frame(current[0],current[1],avgY);
  frame.origin=add(center(current),add(scale(avgY,section?.offset_y_m||0),scale(avgZ,section?.offset_z_m||0)));
  return frame;
 }
 const HELP=["Start measurement, then click two visible points. Distance and signed dx, dy, dz are in FE global x/y/z axes and metres. The first point is A and the second is B; deltas are B minus A.",
  "Surfaces and bar geometry of the displayed FE model, the visible aerodynamic surface, and imported reference geometry can be measured. Force arrows, axes, supports, RBE3 spiders, selection highlights and other helpers are excluded. Optional node snapping uses visible structural GRID positions near the click and rejects points behind geometry.",
  "A measurement is a snapshot of the currently displayed shape, including its deformation magnification and reference placement. It does not follow later deformation or reference movement. Restart to measure the new state. Rebuilding the FE model clears it. Markers use the Display panel's marker radius; measurements never enter the FE model, loads or geometry exports.",
  "Two clicks finish measurement mode; ordinary inspection then resumes. Dragging still orbits/pans, the middle mouse button still centers on a node, and Escape leaves measurement mode. Clear removes the snapshot.",
  "A selected shell or bar shows its own local x/y/z frame, independently of the all-element axis switches. Selected axes are an inspection overlay and remain visible through surfaces, like the selection highlight; hiding the selected element's layer hides its frame. Shell axes start from the actual exported MCID/material frame and are transported with displayed shell geometry. Bar axes follow its displayed end points and nodal section rotations, including the section centroid offset. Contour components remain in their reported reference local axes. A highly magnified shape is a visualization, not a new analysis. RBE3 constraints have no shell/bar local frame."];

 function create(B,options){
  const {scene,camera,engine,canvas,getState,getPositions}=options,doc=canvas.ownerDocument;
  const controls=Object.fromEntries(["btn-measure","btn-measure-clear","measure-snap-nodes","measure-status","measure-values","show-picked-axes","picked-axes-note","btn-measure-help","btn-clear-pick"].map(id=>[id,doc.getElementById(id)]));
  const overlay=doc.createElement("div");overlay.className="geometry-tools-overlay";canvas.parentElement.appendChild(overlay);
  let active=false,points=[],labels=[],measurementMeshes=[],axisMeshes=[],frameLabels=[],selectedFrame=null,pose=null,disposed=false;
  const fmt=n=>options.format?options.format(n,7):Number(n.toPrecision(7)).toString();
  function label(text,color,position){const el=doc.createElement("span");el.className="geometry-tool-label";el.textContent=text;el.style.color=color;overlay.appendChild(el);return{element:el,position};}
  function disposeMeshes(meshes){for(const mesh of meshes)mesh.dispose(false,true);meshes.length=0;}
  function removeLabels(items){for(const item of items)item.element.remove();items.length=0;}
  function helper(mesh){mesh.isPickable=false;mesh.renderingGroupId=2;mesh.metadata={geometryTool:true};if(mesh.material){mesh.material.disableDepthWrite=true;mesh.material.depthFunction=B.Engine.ALWAYS;}return mesh;}
  function status(text){if(controls["measure-status"])controls["measure-status"].textContent=text;}
  function updateUI(){
   if(controls["btn-measure"]){controls["btn-measure"].textContent=active?"Restart measurement":points.length?"New measurement":"Start measurement";controls["btn-measure"].setAttribute("aria-pressed",String(active));}
   if(controls["btn-measure-clear"])controls["btn-measure-clear"].disabled=!points.length&&!active;
   canvas.classList.toggle("measuring",active);
   const host=controls["measure-values"];if(!host)return;host.replaceChildren();
   if(points.length===2){const d=distance(points[0].position,points[1].position);const rows=[["Distance",fmt(d.length)+" m"],["dx, dy, dz",d.delta.map(fmt).join(", ")+" m"],["A (x, y, z)",d.a.map(fmt).join(", ")+" m"],["B (x, y, z)",d.b.map(fmt).join(", ")+" m"]];
    const table=doc.createElement("table");for(const [name,value]of rows){const row=doc.createElement("tr"),key=doc.createElement("th"),cell=doc.createElement("td");key.textContent=name;cell.textContent=value;row.append(key,cell);table.appendChild(row);}host.appendChild(table);
    const note=doc.createElement("p");note.className="pick-note";note.textContent="Snapshot of displayed geometry. A: "+points[0].source+"; B: "+points[1].source+". Restart after changing deformation or placement.";host.appendChild(note);
   }
  }
  function updateRadii(){const radius=Math.max(0,Number(options.markerRadius?.())||0);for(const mesh of measurementMeshes)if(mesh.metadata?.endpoint)mesh.scaling.setAll(radius);}
  function drawMeasurement(){
   disposeMeshes(measurementMeshes);removeLabels(labels);
   for(let i=0;i<points.length;i++){
    const sphere=B.MeshBuilder.CreateSphere("measure-end-"+i,{diameter:2,segments:12},scene),material=new B.StandardMaterial("measure-end-material-"+i,scene);
    material.diffuseColor=B.Color3.FromHexString("#ffdb73");material.emissiveColor=material.diffuseColor;sphere.material=material;helper(sphere);sphere.metadata.endpoint=true;sphere.position.copyFromFloats(...points[i].position);measurementMeshes.push(sphere);
    labels.push(label(i?"B":"A","#ffdb73",points[i].position));
   }
   if(points.length===2){const line=helper(B.MeshBuilder.CreateLines("measure-distance",{points:points.map(p=>new B.Vector3(...p.position))},scene));line.color=B.Color3.FromHexString("#ffdb73");measurementMeshes.push(line);labels.push(label(fmt(distance(points[0].position,points[1].position).length)+" m","#ffdb73",center(points.map(p=>p.position))));}
   updateRadii();updateUI();
  }
  function clear(){active=false;points=[];drawMeasurement();status("Measure two points on the displayed geometry.");}
  function restart(){clear();active=true;updateUI();status("Click point A on visible geometry. Escape exits measurement mode.");}
  function cancel(){active=false;updateUI();status(points.length===2?"Measurement snapshot retained.":"Measurement paused. Restart or clear to begin again.");}
  function eligible(mesh){
   if(!mesh||mesh.isDisposed()||!mesh.isEnabled()||!mesh.isVisible||mesh.visibility<=0||mesh.material?.alpha===0)return false;
   const kind=mesh.metadata?.feGroup?.kind;
   return kind==="quad"||kind==="tria"||kind==="bar"||mesh.metadata?.wingReferenceId!==undefined||mesh.name==="AERO_SURFACE";
  }
  function surface(x,y){return scene.pick(x,y,eligible,false,camera);}
  function linePoint(hit){
   const mesh=hit.pickedMesh,positions=mesh.getVerticesData(B.VertexBuffer.PositionKind),indices=mesh.getIndices(),matrix=mesh.computeWorldMatrix(true);let best=null;
   // LinesMesh hit points lie on the picking ray inside a tolerance tube, not
   // necessarily on a bar. Search actual drawn segments; do not assume its
   // faceId uses triangle semantics or identify a neighboring bar by accident.
   for(let i=0;i<indices.length;i+=2){const a=B.Vector3.TransformCoordinates(B.Vector3.FromArray(positions,3*indices[i]),matrix).asArray(),b=B.Vector3.TransformCoordinates(B.Vector3.FromArray(positions,3*indices[i+1]),matrix).asArray(),p=closestSegment(hit.pickedPoint.asArray(),a,b),error=Math.hypot(...sub(p,hit.pickedPoint.asArray()));if(!best||error<best.error)best={position:p,error,index:i/2};}
   return best;
  }
  function snapNode(x,y){
   const state=getState(),positions=getPositions();if(!positions||!state.nodeIds)return null;
   const viewport=camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight()),matrix=scene.getTransformMatrix(),hardware=engine.getHardwareScalingLevel(),candidates=[];
   for(const node of options.visibleNodes?.()||[]){if(node>=state.data.nodes.n_structural)continue;const p=point(positions,node),projected=B.Vector3.Project(new B.Vector3(...p),B.Matrix.IdentityReadOnly,matrix,viewport),sx=projected.x*hardware,sy=projected.y*hardware;
    const error=Math.hypot(sx-x,sy-y);if(projected.z>=0&&projected.z<=1&&error<=14)candidates.push({node,position:p,error,sx,sy,depth:projected.z});}
   candidates.sort((a,b)=>a.error-b.error||a.depth-b.depth);
   for(const candidate of candidates){const hit=surface(candidate.sx,candidate.sy);if(hit?.hit&&hit.pickedPoint){const ray=scene.createPickingRay(candidate.sx,candidate.sy,B.Matrix.IdentityReadOnly,camera),along=dot(sub(candidate.position,ray.origin.asArray()),ray.direction.asArray());if(hit.distance<along-Math.max(1e-5,state.diag*2e-5))continue;}
    return{position:candidate.position,source:"GRID "+state.nodeIds[candidate.node]};}
   return null;
  }
  function pick(x,y){
   if(!active)return false;
   let chosen=controls["measure-snap-nodes"]?.checked?snapNode(x,y):null;
   if(!chosen){let hit=surface(x,y),lineHit=hit?.hit&&hit.pickedMesh instanceof B.LinesMesh&&hit.pickedMesh.metadata?.feGroup?.kind==="bar"?linePoint(hit):null;
    if(lineHit){const viewport=camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight()),p=B.Vector3.Project(new B.Vector3(...lineHit.position),B.Matrix.IdentityReadOnly,scene.getTransformMatrix(),viewport),hardware=engine.getHardwareScalingLevel(),ray=scene.createPickingRay(p.x*hardware,p.y*hardware,B.Matrix.IdentityReadOnly,camera),front=scene.pick(p.x*hardware,p.y*hardware,m=>eligible(m)&&!(m instanceof B.LinesMesh),false,camera),along=dot(sub(lineHit.position,ray.origin.asArray()),ray.direction.asArray());
     if(front?.hit&&front.distance<along-Math.max(1e-5,getState().diag*2e-5)){hit=scene.pick(x,y,m=>eligible(m)&&!(m instanceof B.LinesMesh),false,camera);lineHit=null;}}
    if(hit?.hit&&hit.pickedPoint){const mesh=hit.pickedMesh,meta=mesh.metadata;let source=mesh.name;
     if(meta?.wingReferenceId!==undefined)source="reference geometry";
     else if(meta?.feGroup){const index=lineHit?lineHit.index:meta.faceElements?meta.faceElements[hit.faceId]:Math.floor(hit.faceId/meta.facesPerElement);source=meta.feGroup.name+(mesh.elementIds?.[index]!==undefined?" / EID "+mesh.elementIds[index]:"");}
     chosen={position:lineHit?lineHit.position:hit.pickedPoint.asArray(),source};}}
   if(!chosen){status("No visible geometry at this point. Choose a surface or enable visible-node snapping.");return true;}
   points.push(chosen);if(points.length===2)active=false;drawMeasurement();status(points.length===1?"Point A set. Click point B; Escape exits measurement mode.":"Measurement complete. Ordinary inspection is active again.");return true;
  }
  function clearFrame(){disposeMeshes(axisMeshes);removeLabels(frameLabels);selectedFrame=null;}
  function refreshSelection(positions){
   if(disposed)return;const state=getState(),element=state.elements.get(state.selectedElement),note=controls["picked-axes-note"];
   if(!element){clearFrame();if(note)note.textContent="Pick a shell or bar to show its local x, y and z axes.";return;}
   if(element.group.kind==="rbe3"){clearFrame();if(note)note.textContent="RBE3 is a constraint, with no shell or bar local frame. Its applied forces and moments use global FE axes.";return;}
   if(!state.layers.get(element.group.name)?.visible){clearFrame();if(note)note.textContent="Selected element is hidden; its local axes are hidden too.";return;}
   const g=element.group;if(!g.axes||!state.baseline){clearFrame();if(note)note.textContent="No exported local frame is available for this element.";return;}
   if(controls["show-picked-axes"]?.checked===false){clearFrame();if(note)note.textContent="Selected-element axes are switched off.";return;}
   const current=positions||pose?.positions||getPositions(),nodes=Array.from(element.nodes),baseline=nodes.map(n=>point(state.baseline,n)),displayed=nodes.map(n=>point(current,n));
   const ids=options.groupIds(g),index=Array.from(ids).indexOf(state.selectedElement);if(index<0){clearFrame();return;}
   const axis=name=>toView(point(options.decodeFloat(g.axes[name]),index));
   try{
    const changed=current!==state.baseline;
    if(selectedFrame?.eid!==state.selectedElement||axisMeshes.length!==3)clearFrame();
    selectedFrame=g.kind==="bar"?barFrame(baseline,displayed,g.orient?toView(point(options.decodeFloat(g.orient),index)):axis("y"),g.properties?.section,pose?.rotations?nodes.map(n=>point(pose.rotations,n)):null,pose?.rotationScale??1,options.sections):shellFrame(baseline,displayed,axis("x"),axis("y"));
    selectedFrame.origin=state.panelExplosion?.point(state.selectedElement,selectedFrame.origin)||selectedFrame.origin;
    selectedFrame.eid=state.selectedElement;selectedFrame.kind=g.kind;
    const edges=displayed.map((p,i)=>Math.hypot(...sub(p,displayed[(i+1)%displayed.length]))).filter(n=>n>0),size=Math.max(state.diag*.008,Math.min(Math.min(...edges)*.3,state.diag*.05));
    for(const [i,name]of ["x","y","z"].entries()){const color={x:"#ef5f6b",y:"#4cc38a",z:"#56a8f5"}[name],origin=new B.Vector3(...selectedFrame.origin),vector=new B.Vector3(...selectedFrame[name]).scale(size),tip=origin.add(vector),direction=vector.normalizeToNew(),side=B.Vector3.Cross(direction,Math.abs(direction.y)<.9?B.Axis.Y:B.Axis.X).normalize().scale(size*.08),back=tip.subtract(direction.scale(size*.22)),lines=[[origin,tip],[tip,back.add(side)],[tip,back.subtract(side)]];
     if(axisMeshes[i]){B.MeshBuilder.CreateLineSystem("picked-local-"+name,{lines,instance:axisMeshes[i]},scene);frameLabels[i].position=tip.asArray();}
     else{const mesh=helper(B.MeshBuilder.CreateLineSystem("picked-local-"+name,{lines,updatable:true},scene));mesh.color=B.Color3.FromHexString(color);axisMeshes.push(mesh);frameLabels.push(label(name,color,tip.asArray()));}}
    if(note){const text=(changed?"Displayed ":"Reference ")+(g.kind==="bar"?"bar section frame at its centroid; x along the bar, y/z follow section rotation.":"shell material frame: x/y follow the exported MCID axes, transported with the displayed surface; z is its normal.")+(changed?" Result components remain in their reported reference local axes.":"")+" Inspection overlay: x red, y green, z blue.";if(note.textContent!==text)note.textContent=text;}
   }catch(error){clearFrame();if(note)note.textContent=error.message;}
  }
  function setPose(positions,rotations,rotationScale=1){pose={positions,rotations,rotationScale};}
  function resetModel(){clear();pose=null;clearFrame();if(controls["picked-axes-note"])controls["picked-axes-note"].textContent="Pick a shell or bar to show its local x, y and z axes.";}
  function renderLabels(){const viewport=camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight()),matrix=scene.getTransformMatrix(),hardware=engine.getHardwareScalingLevel();for(const item of [...labels,...frameLabels]){const p=B.Vector3.Project(new B.Vector3(...item.position),B.Matrix.IdentityReadOnly,matrix,viewport),x=p.x*hardware,y=p.y*hardware;item.element.hidden=p.z<0||p.z>1||x<0||y<0||x>canvas.clientWidth||y>canvas.clientHeight;item.element.style.transform="translate("+x+"px,"+y+"px)";}}
  const observer=scene.onBeforeRenderObservable.add(renderLabels),escape=event=>{if(event.key==="Escape"&&active){event.preventDefault();cancel();}};doc.addEventListener("keydown",escape);
  if(controls["btn-measure"])controls["btn-measure"].onclick=restart;
  if(controls["btn-measure-clear"])controls["btn-measure-clear"].onclick=clear;
  if(controls["show-picked-axes"])controls["show-picked-axes"].onchange=()=>refreshSelection();
  if(controls["btn-measure-help"])controls["btn-measure-help"].onclick=()=>options.onHelp?.({title:"Measure and inspect local axes",paragraphs:HELP});
  if(controls["btn-clear-pick"])controls["btn-clear-pick"].onclick=()=>{options.clearSelection?.();refreshSelection();};
  updateUI();
  return{get active(){return active;},get points(){return points.map(p=>({position:p.position.slice(),source:p.source}));},get selectedFrame(){return selectedFrame;},get measurementMeshes(){return measurementMeshes;},get axisMeshes(){return axisMeshes;},restart,clear,cancel,pick,eligible,setPose,resetModel,refreshSelection,updateRadii,
   dispose(){if(disposed)return;resetModel();disposed=true;scene.onBeforeRenderObservable.remove(observer);doc.removeEventListener("keydown",escape);overlay.remove();}};
 }
 return{create,distance,closestSegment,shellFrame,barFrame,toFE,toView,HELP};
});
