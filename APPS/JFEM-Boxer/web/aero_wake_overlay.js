/* Completed independent VLM wakes in the structural construction frame. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAeroWakeOverlay=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const point=p=>Array.isArray(p)&&p.length===3&&p.every(Number.isFinite);
 function available(c,meshOnly=false){
  if(meshOnly||!c?.coefficients||c.difference)return false;
  const curves=c.wake?.sheets?.flatMap(s=>s.lines||[]);
  if(c.wake||c.wake_model==='relaxed')return c.wake?.converged===true&&!!curves?.some(l=>l.length>1&&l.every(point));
  return point(c.wake_direction)&&Math.hypot(...c.wake_direction)>0&&!!c.wake_origins?.some(point);
 }
 function create({document:doc=globalThis.document,BABYLON:B=globalThis.BABYLON,state,linesForCase,onChange=()=>{}}){
  const toggle=doc.getElementById('show-aero-wakes'),length=doc.getElementById('aero-wake-length'),note=doc.getElementById('aero-wake-note'),label=doc.getElementById('aero-wake-control');
  let selected=null,metadata={meshOnly:true},mesh=null,drawnCase=null,drawnLength=null;
  function clear(){mesh?.dispose();mesh=null;drawnCase=null;drawnLength=null;}
  function sync(){
   const ready=available(selected,metadata.meshOnly);toggle.disabled=!ready;length.disabled=!ready;
   label.style.opacity=ready?'':'0.5';
   note.textContent=ready?`Case ${selected.id}: ${selected.wake?'relaxed':'straight'} wake in the undeformed aerodynamic frame. Select another condition in Aerodynamics.${metadata.stale?' Retained solution: aerodynamic inputs have changed.':''}`:'Run Aerodynamics to compute wake filaments. Mesh previews do not contain a solved wake.';
   if(!ready){clear();return;}
   const spans=Number(length.value);
   if(!Number.isFinite(spans)||spans<.1){length.setCustomValidity('Use a finite wake length of at least 0.1 spans.');return;}
   length.setCustomValidity('');
   if(!toggle.checked){mesh?.setEnabled(false);return;}
   if(drawnCase!==selected||drawnLength!==spans||!mesh||mesh.isDisposed()){
    clear();const lines=linesForCase(selected,spans).filter(l=>l.length>1&&l.every(point)).map(l=>l.map(p=>new B.Vector3(p[1],p[2],p[0])));
    if(!lines.length)return;
    mesh=B.MeshBuilder.CreateLineSystem('independent-aero-wake-overlay',{lines},state.scene);
    mesh.color=B.Color3.FromHexString('#b79aef');mesh.isPickable=false;mesh.renderingGroupId=1;
    mesh.metadata={aerodynamicWakeOverlay:true,caseId:selected.id};drawnCase=selected;drawnLength=spans;
   }
   mesh.setEnabled(true);
  }
  toggle.onchange=()=>{sync();onChange();};length.oninput=length.onchange=()=>{sync();if(length.checkValidity())onChange();};
  sync();
  return{update(c,meta={}){selected=c;metadata=meta;sync();},sync,destroy(){clear();toggle.onchange=null;length.oninput=length.onchange=null;},get mesh(){return mesh;}};
 }
 return{available,create};
});
