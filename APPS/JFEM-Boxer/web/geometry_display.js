/* Geometry-only appearance. No FE/material properties or result colors change. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingGeometryDisplay=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const STYLES=['solid','wireframe','translucent','metallic'];
 function normalize(value={}){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length>1100)throw Error('Invalid geometry appearance settings.');
  const result={};
  for(const[key,item]of Object.entries(value)){
   if(!/^(FUEL_TANK|REFERENCE_AERO|SYMMETRY|GROUND|RIB_DATUMS|AIRFOIL_[0-9]+|REFERENCE_[0-9]+)$/.test(key)||!item||typeof item!=='object'||Array.isArray(item))throw Error('Invalid geometry appearance entity.');
   if(Object.keys(item).some(k=>!['color','style','opacity','visible'].includes(k))||typeof item.color!=='string'||!/^#[0-9a-f]{6}$/i.test(item.color)||!STYLES.includes(item.style)||!Number.isFinite(item.opacity)||item.opacity<.03||item.opacity>1||item.visible!==undefined&&typeof item.visible!=='boolean')throw Error('Invalid geometry color, finish or opacity.');
   result[key]={color:item.color,style:item.style,opacity:item.opacity,...(item.visible===undefined?{}:{visible:item.visible})};
  }
  return result;
 }
 function create({document:doc=globalThis.document,BABYLON:B=globalThis.BABYLON,state,onChange=()=>{},setLayerVisible,available=()=>true}){
  let originals=new Map(),environment=null,referenceStamp='';const materials=new Map(),referenceColors=new Map(),referenceControls=new Map();
  const saved=()=>state.geometryAppearance||{};
  function remember(mesh){if(originals.has(mesh))return;const m=mesh.material;originals.set(mesh,{material:m,useVertexColors:mesh.useVertexColors,color:mesh.color?.clone(),alpha:mesh.alpha,fields:m?{diffuseColor:m.diffuseColor?.clone(),emissiveColor:m.emissiveColor?.clone(),alpha:m.alpha,wireframe:m.wireframe,transparencyMode:m.transparencyMode}:null});}
  function material(mesh,metallic){
   remember(mesh);
   if(!metallic){mesh.material=originals.get(mesh).material;return mesh.material;}
   if(!materials.has(mesh)){
    if(!environment){environment=new B.RawCubeTexture(state.scene,WingAeroDisplay.studioFaces(),64,B.Engine.TEXTUREFORMAT_RGBA,B.Engine.TEXTURETYPE_UNSIGNED_BYTE,true,false,B.Texture.TRILINEAR_SAMPLINGMODE);environment.coordinatesMode=B.Texture.CUBIC_MODE;environment.gammaSpace=false;}
    const m=new B.PBRMaterial('geometry-metal-'+mesh.uniqueId,state.scene);m.metallic=1;m.roughness=.25;m.reflectionTexture=environment;m.environmentIntensity=1.5;m.maxSimultaneousLights=6;m.backFaceCulling=false;m.twoSidedLighting=true;materials.set(mesh,m);
   }
   mesh.material=materials.get(mesh);return mesh.material;
  }
  function paint(mesh,value){
   if(!mesh||mesh.isDisposed?.())return;
   remember(mesh);
   const rgb=B.Color3.FromHexString(value.color);
   if(mesh instanceof B.LinesMesh){mesh.color=rgb;mesh.alpha=value.opacity;return;}
   const m=material(mesh,value.style==='metallic');if(!m)return;
   mesh.useVertexColors=false;
   if(m instanceof B.PBRMaterial)m.albedoColor=rgb;else{m.diffuseColor=rgb;m.emissiveColor=rgb.scale(m.disableLighting?1:.025);}
   m.alpha=value.style==='translucent'?value.opacity:1;m.wireframe=value.style==='wireframe';
   m.transparencyMode=m.alpha<1?B.Material.MATERIAL_ALPHABLEND:B.Material.MATERIAL_OPAQUE;
   m.backFaceCulling=false;m.twoSidedLighting=true;
  }
  function apply(){
   for(const key of ['FUEL_TANK','REFERENCE_AERO'])if(saved()[key])for(const mesh of state.layers.get(key)?.meshes||[])paint(mesh,saved()[key]);
   if(saved().SYMMETRY)paint(state.viewPlanes?.meshes.symmetry,saved().SYMMETRY);
   if(saved().GROUND)state.viewPlanes?.setGroundAppearance(saved().GROUND);
   if(saved().RIB_DATUMS)for(const mesh of Object.values(state.ribDatums?.meshes||{}))paint(mesh,saved().RIB_DATUMS);
   const sectionLayer=state.layers.get('AIRFOIL_SECTIONS');
   for(const [i,mesh]of (state.aeroDisplay?.meshes||[]).entries()){
    const value=saved()['AIRFOIL_'+i];if(value)paint(mesh,value);
    mesh.setEnabled(!!sectionLayer?.visible&&value?.visible!==false);
   }
   for(const[i,entry]of (state.reference?.entries||[]).entries()){const value=saved()['REFERENCE_'+i];if(value){if(!referenceColors.has(entry.material))referenceColors.set(entry.material,[entry.material.diffuseColor.clone(),entry.material.emissiveColor.clone()]);const color=B.Color3.FromHexString(value.color);entry.material.diffuseColor=color;entry.material.emissiveColor=color.scale(.18);}}
  }
  function change(key,values,defaults){state.geometryAppearance={...saved(),[key]:{...defaults,...saved()[key],...values}};apply();onChange();}
  function node(tag,cls,text){const el=doc.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;}
  function card(host,key,label){
   const box=node('fieldset','geometry-appearance geometry-entity-card'),legend=node('legend','geometry-card-title',label),head=node('div','geometry-card-header'),title=node('span','geometry-card-name',label),fields=node('div','geometry-card-fields');box.dataset.geometry=key;title.title=label;head.append(title,fields);box.append(legend,head);host.append(box);box.geometryParts={head,title,fields};return box;
  }
  function rowFor(id){
   // A fresh layer list may briefly coexist with the prior compact card.
   // Prefer its new canonical checkbox, then discard only generated old rows.
   const all=Array.from(doc.querySelectorAll('[id="'+id+'"]')),input=all.find(el=>el.closest('#geometry-layers'))||all.at(-1);return input?.closest('label')||null;
  }
  function visibility(box,row){if(!box||!row)return;const {head,title}=box.geometryParts;row.classList.add('geometry-visibility');title.replaceWith(row);box.geometryParts.title=row;head.prepend(row);}
  function compactField(row,label){if(!row)return;const control=row.querySelector('input,select,textarea');row.classList.add('geometry-inline-control');if(control){const name=Array.from(row.childNodes).filter(child=>child!==control).map(child=>child.textContent).join(' ').trim().replace(/\s+/g,' ');if(!control.hasAttribute('aria-label'))control.setAttribute('aria-label',name||label);const caption=node('span','geometry-control-caption',label||name);row.replaceChildren(caption,control);if(control.type==='color')row.classList.add('geometry-color');if(control.tagName==='SELECT')row.classList.add('geometry-finish');}return row;}
  function opacityControl(box,label,value,onInput){const row=node('label','display-control geometry-card-opacity'),text=node('span','','Opacity'),slider=node('input'),output=node('output');slider.type='range';slider.min='.03';slider.max='1';slider.step='.01';slider.value=value;slider.setAttribute('aria-label',label+' opacity');output.textContent=Math.round(100*value)+'%';row.append(text,slider,output);slider.oninput=()=>{output.textContent=Math.round(100*Number(slider.value))+'%';onInput(Number(slider.value));};box.append(row);return{row,slider,output};}
  function controls(host,key,label,defaults,{wire=false,visible}={}){
   const values={...defaults,...saved()[key]},box=card(host,key,label),{fields}=box.geometryParts;
   if(visible){const row=node('label','layer'),input=node('input'),name=node('span','',label);input.type='checkbox';input.checked=values.visible!==false;input.disabled=!visible();input.setAttribute('aria-label','Show '+label);input.onchange=()=>{change(key,{visible:input.checked},defaults);if(input.checked)setLayerVisible('AIRFOIL_SECTIONS',true);};row.append(input,name);visibility(box,row);}
   const colorRow=node('label','display-control geometry-inline-control geometry-color'),color=node('input');colorRow.textContent='Color';color.type='color';color.value=values.color;color.setAttribute('aria-label',label+' color');color.title=label+' color';color.oninput=()=>change(key,{color:color.value},defaults);colorRow.append(color);fields.append(colorRow);
   if(!wire){const row=node('label','display-control geometry-inline-control geometry-finish'),select=node('select');row.textContent='Finish';select.setAttribute('aria-label',label+' finish');for(const style of STYLES){const option=node('option','',style[0].toUpperCase()+style.slice(1));option.value=style;select.append(option);}select.value=values.style;row.append(select);fields.append(row);
    const alpha=opacityControl(box,label,values.opacity,value=>change(key,{opacity:value},defaults));alpha.row.hidden=values.style!=='translucent';select.onchange=()=>{alpha.row.hidden=select.value!=='translucent';change(key,{style:select.value},defaults);};
   }
   return box;
  }
  function ensure(id,parent,cls){let el=doc.getElementById(id);if(!el&&parent){el=node('div',cls);el.id=id;parent.append(el);}return el;}
  function parkControls(){
   const panel=doc.getElementById('panel-displaygeometry');if(!panel)return;
   const park=ensure('geometry-control-parking',panel,'geometry-control-parking');park.hidden=true;
   for(const id of['show-reference-aero','show-rib-datums','rib-datum-size','layer-FUEL_TANK','layer-AIRFOIL_SECTIONS']){const row=rowFor(id);if(row)park.append(row);}
   const status=doc.getElementById('rib-datum-status');if(status)park.append(status);
  }
  function editReference(entry,edit){const reference=state.reference,previous=reference.active?.id??null;if(reference.active!==entry)reference.select(entry.id);edit(reference);if((reference.active?.id??null)!==previous)reference.select(previous);syncReferenceFields();}
  function syncReferenceFields(){for(const[entry,controls]of referenceControls){if(doc.activeElement!==controls.visible)controls.visible.checked=entry.visible!==false;if(doc.activeElement!==controls.wire)controls.wire.checked=entry.wireframe===true;if(doc.activeElement!==controls.alpha.slider)controls.alpha.slider.value=entry.opacity??1;controls.alpha.output.textContent=Math.round(100*(entry.opacity??1))+'%';}}
  function referenceCard(host,key,entry){
   const color=entry.material?.diffuseColor?.toHexString?.()||'#c5b2df',box=controls(host,key,entry.name,{color,style:'solid',opacity:1},{wire:true}),row=node('label','layer'),show=node('input'),label=node('span','',entry.name);show.type='checkbox';show.checked=entry.visible!==false;show.setAttribute('aria-label','Show reference '+entry.name);show.onchange=()=>editReference(entry,reference=>reference.setVisible(show.checked));row.append(show,label);visibility(box,row);
   const wireRow=node('label','layer geometry-reference-wire'),wire=node('input');wire.type='checkbox';wire.checked=entry.wireframe===true;wire.setAttribute('aria-label',entry.name+' wireframe');wire.onchange=()=>editReference(entry,reference=>reference.setAppearance({wireframe:wire.checked}));wireRow.append(wire,doc.createTextNode('Wire'));box.geometryParts.fields.append(wireRow);const alpha=opacityControl(box,entry.name,entry.opacity??1,value=>editReference(entry,reference=>reference.setAppearance({opacity:value})));referenceControls.set(entry,{visible:show,wire,alpha});return box;
  }
  function compact(){
   const results=doc.getElementById('geometry-results');if(results){results.classList.add('geometry-compact-section');const current=ensure('geometry-current-structure',results,'geometry-static-card'),reference=ensure('geometry-undeformed-structure',results,'geometry-static-card');const shown=rowFor('geometry-show-structure'),undeformed=rowFor('show-undeformed'),color=compactField(rowFor('undeformed-color'),'Color');if(shown){shown.classList.add('geometry-visibility');current.prepend(shown);}if(undeformed){undeformed.classList.add('geometry-visibility');reference.prepend(undeformed);}if(color){color.querySelector('input')?.setAttribute('aria-label','Undeformed model color');reference.append(color);}const action=results.querySelector('[data-workspace-target="results"]');if(action){action.classList.add('geometry-card-action');action.textContent='Results';current.append(action);}let appearance=current.querySelector('[data-geometry-appearance-link]');if(!appearance){appearance=node('button','mini geometry-card-action','Appearance');appearance.type='button';appearance.dataset.geometryAppearanceLink='true';appearance.title='Structural surface opacity, shell thickness and bar sections';appearance.onclick=()=>doc.getElementById('tab-displayappearance')?.click();current.append(appearance);}}
   const aero=doc.getElementById('aerodynamic-appearance'),shapes=doc.getElementById('aerodynamic-shape-controls');
   if(aero){aero.classList.add('geometry-static-card','geometry-aero-card');const head=ensure('geometry-aero-current-header',aero,'geometry-aero-header'),fields=ensure('geometry-aero-current-fields',aero,'geometry-card-fields'),shown=rowFor('show-deformed-aero');if(shown){shown.classList.add('geometry-visibility');head.prepend(shown);}head.append(fields);aero.prepend(head);for(const[id,label]of[['aero-surface-color','Color'],['aero-deformed-style','Finish']]){const row=compactField(rowFor(id),label);if(row)fields.append(row);}let notes=aero.querySelector('.geometry-card-notes');const paragraphs=Array.from(aero.querySelectorAll(':scope > p'));if(paragraphs.length){if(!notes){notes=node('details','geometry-card-notes');notes.append(node('summary','','Loft display details'));aero.append(notes);}for(const p of paragraphs){p.classList.add('geometry-secondary-note');notes.append(p);}}const curve=rowFor('show-aero-curvature');if(curve)curve.classList.add('geometry-compact-option');}
   const referenceBox=doc.querySelector('[data-geometry="REFERENCE_AERO"]');if(referenceBox)visibility(referenceBox,rowFor('show-reference-aero'));
   const fuel=doc.querySelector('[data-geometry="FUEL_TANK"]');if(fuel)visibility(fuel,rowFor('layer-FUEL_TANK'));
   const rib=doc.querySelector('[data-geometry="RIB_DATUMS"]');if(rib){visibility(rib,rowFor('show-rib-datums'));const size=rowFor('rib-datum-size');if(size){size.classList.add('geometry-compact-option');rib.append(size);}const status=doc.getElementById('rib-datum-status');if(status){status.classList.add('geometry-secondary-note');rib.append(status);}}
   const sections=doc.getElementById('geometry-airfoil-appearance'),master=rowFor('layer-AIRFOIL_SECTIONS');if(sections&&master){master.classList.add('geometry-section-toggle');sections.prepend(master);}
   const context=doc.getElementById('geometry-context');if(context)context.hidden=!!rib||!state.ribDatums?.layout.count;
   for(const id of['entity-group-overlays']){const group=doc.getElementById(id);if(group)group.hidden=true;}
   const referenceHost=doc.getElementById('geometry-references');if(referenceHost)referenceHost.classList.add('geometry-compact-references');
   const cuts=doc.getElementById('loft-cut-controls');if(cuts)cuts.classList.add('geometry-compact-section');
   return{results,aero,shapes};
  }
  function rebuild(){
   const host=doc.getElementById('geometry-appearance-controls');if(!host)return;parkControls();host.replaceChildren();referenceControls.clear();
   const environmentHost=doc.getElementById('environment-appearance-controls');environmentHost?.replaceChildren();
   const aeroHost=doc.getElementById('aerodynamic-reference-appearance');aeroHost?.replaceChildren();
   const shapes=doc.getElementById('aerodynamic-shape-controls'),sectionHost=ensure('geometry-airfoil-appearance',shapes||host,'geometry-airfoil-appearance');sectionHost.replaceChildren();
   for(const[key,label,color,opacity]of [['FUEL_TANK','Fuel tank','#57b88c',.22],['REFERENCE_AERO','Undeformed aero reference','#c5d1df',.14]])if(state.layers.has(key)){const box=controls(key==='REFERENCE_AERO'&&aeroHost?aeroHost:host,key,label,{color,style:'translucent',opacity});box.disabled=!available(key);box.hidden=key==='REFERENCE_AERO'&&box.disabled;}
   if(state.viewPlanes&&environmentHost){const ground=controls(environmentHost,'GROUND','Ground plane',{color:'#bfccd7',style:'solid',opacity:1});const note=node('p','pick-note','Metallic reflects the visible model across the ground height.');ground.append(note);controls(environmentHost,'SYMMETRY','Root symmetry plane',{color:'#a9c6df',style:'translucent',opacity:.09});}
   if(state.ribDatums?.layout.count)controls(host,'RIB_DATUMS','Rib datum planes',{color:'#91c8ee',style:'translucent',opacity:.18});
   const sections=state.aeroDisplay?.sections||[];sectionHost.hidden=!sections.length;
   for(const[i,section]of sections.entries())controls(sectionHost,'AIRFOIL_'+i,section.kind+' · '+section.name+' · η '+section.eta,{color:'#e6b8ff',style:'wireframe',opacity:1,visible:true},{wire:true,visible:()=>true});
   const referenceHost=doc.getElementById('geometry-references'),referenceAppearance=ensure('geometry-reference-appearance',referenceHost||host,'geometry-reference-appearance');referenceAppearance.replaceChildren();if(referenceHost)referenceHost.prepend(referenceAppearance);referenceAppearance.hidden=!(state.reference?.entries?.length);
   for(const[i,entry]of (state.reference?.entries||[]).entries())referenceCard(referenceAppearance,'REFERENCE_'+i,entry);
   if(!state.data)host.append(node('p','pick-note','Create or read a model to show its available geometry.'));
   compact();apply();
  }
  function reset(){for(const[mesh,old]of originals)if(!mesh.isDisposed?.()){mesh.material=old.material;mesh.useVertexColors=old.useVertexColors;if(old.color)mesh.color=old.color;mesh.alpha=old.alpha;if(old.fields)for(const[key,value]of Object.entries(old.fields))if(value!==undefined)old.material[key]=value;}for(const[m,colors]of referenceColors){m.diffuseColor=colors[0];m.emissiveColor=colors[1];}referenceColors.clear();for(const m of materials.values())m.dispose(false,false);materials.clear();originals.clear();environment?.dispose();environment=null;state.viewPlanes?.setGroundAppearance();}
  function syncReferences(){const next=JSON.stringify((state.reference?.entries||[]).map(e=>[e.id,e.name]));if(next!==referenceStamp){referenceStamp=next;rebuild();}else syncReferenceFields();}
  return{apply,rebuild,compact,reset,syncReferences};
 }
 return{normalize,STYLES,create};
});
