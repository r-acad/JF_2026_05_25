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
  let originals=new Map(),environment=null,referenceStamp='';const materials=new Map(),referenceColors=new Map();
  const saved=()=>state.geometryAppearance||{};
  function remember(mesh){if(originals.has(mesh))return;const m=mesh.material;originals.set(mesh,{material:m,useVertexColors:mesh.useVertexColors,color:mesh.color?.clone(),alpha:mesh.alpha,fields:m?{diffuseColor:m.diffuseColor?.clone(),emissiveColor:m.emissiveColor?.clone(),alpha:m.alpha,wireframe:m.wireframe,transparencyMode:m.transparencyMode}:null});}
  function material(mesh,metallic){
   remember(mesh);
   if(!metallic){mesh.material=originals.get(mesh).material;return mesh.material;}
   if(!materials.has(mesh)){
    if(!environment){environment=new B.RawCubeTexture(state.scene,WingAeroDisplay.studioFaces(),64,B.Engine.TEXTUREFORMAT_RGBA,B.Engine.TEXTURETYPE_UNSIGNED_BYTE,true,false,B.Texture.TRILINEAR_SAMPLINGMODE);environment.coordinatesMode=B.Texture.CUBIC_MODE;environment.gammaSpace=false;}
    const m=new B.PBRMaterial('geometry-metal-'+mesh.uniqueId,state.scene);m.metallic=1;m.roughness=.25;m.reflectionTexture=environment;m.environmentIntensity=1.5;m.backFaceCulling=false;m.twoSidedLighting=true;materials.set(mesh,m);
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
  function controls(host,key,label,defaults,{wire=false,visible}={}){
   const values={...defaults,...saved()[key]},box=doc.createElement('fieldset');box.className='geometry-appearance';box.dataset.geometry=key;
   const legend=doc.createElement('legend');legend.textContent=label;box.append(legend);
   if(visible){const row=doc.createElement('label'),input=doc.createElement('input');row.className='layer';input.type='checkbox';input.checked=values.visible!==false;input.disabled=!visible();input.setAttribute('aria-label','Show '+label);input.onchange=()=>{change(key,{visible:input.checked},defaults);if(input.checked)setLayerVisible('AIRFOIL_SECTIONS',true);};row.append(input,doc.createTextNode('Show this airfoil'));box.append(row);}
   const colorRow=doc.createElement('label'),color=doc.createElement('input');colorRow.className='display-control';colorRow.textContent='Color';color.type='color';color.value=values.color;color.setAttribute('aria-label',label+' color');color.oninput=()=>change(key,{color:color.value},defaults);colorRow.append(color);box.append(colorRow);
   if(!wire){const row=doc.createElement('label'),select=doc.createElement('select');row.className='display-control';row.textContent='Finish';select.setAttribute('aria-label',label+' finish');for(const style of STYLES){const option=doc.createElement('option');option.value=style;option.textContent=style[0].toUpperCase()+style.slice(1);select.append(option);}select.value=values.style;row.append(select);box.append(row);
    const alphaRow=doc.createElement('label'),alpha=doc.createElement('input');alphaRow.className='display-control';alphaRow.textContent='Opacity';alpha.type='range';alpha.min='.03';alpha.max='1';alpha.step='.01';alpha.value=values.opacity;alpha.setAttribute('aria-label',label+' opacity');alphaRow.append(alpha);alphaRow.hidden=values.style!=='translucent';box.append(alphaRow);
    select.onchange=()=>{alphaRow.hidden=select.value!=='translucent';change(key,{style:select.value},defaults);};alpha.oninput=()=>change(key,{opacity:Number(alpha.value)},defaults);
   }
   host.append(box);return box;
  }
  function rebuild(){
   const host=doc.getElementById('geometry-appearance-controls');if(!host)return;host.replaceChildren();
   const environmentHost=doc.getElementById('environment-appearance-controls');environmentHost?.replaceChildren();
   const aeroHost=doc.getElementById('aerodynamic-reference-appearance');aeroHost?.replaceChildren();
   for(const[key,label,color,opacity]of [['FUEL_TANK','Fuel tank','#57b88c',.22],['REFERENCE_AERO','Undeformed aero reference appearance','#c5d1df',.14]])if(state.layers.has(key)){const box=controls(key==='REFERENCE_AERO'&&aeroHost?aeroHost:host,key,label,{color,style:'translucent',opacity});box.disabled=!available(key);box.hidden=key==='REFERENCE_AERO'&&box.disabled;}
   if(state.viewPlanes&&environmentHost){const ground=controls(environmentHost,'GROUND','Ground plane',{color:'#bfccd7',style:'solid',opacity:1});const note=doc.createElement('p');note.className='pick-note';note.textContent='Metallic reflects the visible model across the ground height.';ground.append(note);controls(environmentHost,'SYMMETRY','Root symmetry plane',{color:'#a9c6df',style:'translucent',opacity:.09});}
   if(state.ribDatums?.layout.count)controls(host,'RIB_DATUMS','Rib datum planes',{color:'#91c8ee',style:'translucent',opacity:.18});
   const sections=state.aeroDisplay?.sections||[];
   for(const[i,section]of sections.entries())controls(host,'AIRFOIL_'+i,section.kind+' airfoil · '+section.name+' · η '+section.eta,{color:'#e6b8ff',style:'wireframe',opacity:1,visible:true},{wire:true,visible:()=>true});
   for(const[i,entry]of (state.reference?.entries||[]).entries())controls(host,'REFERENCE_'+i,'Reference · '+entry.name,{color:'#c5b2df',style:'solid',opacity:1},{wire:true});
   if(!state.data){const note=doc.createElement('p');note.className='pick-note';note.textContent='Create or read a model to show its available geometry.';host.append(note);}
   apply();
  }
  function reset(){for(const[mesh,old]of originals)if(!mesh.isDisposed?.()){mesh.material=old.material;mesh.useVertexColors=old.useVertexColors;if(old.color)mesh.color=old.color;mesh.alpha=old.alpha;if(old.fields)for(const[key,value]of Object.entries(old.fields))if(value!==undefined)old.material[key]=value;}for(const[m,colors]of referenceColors){m.diffuseColor=colors[0];m.emissiveColor=colors[1];}referenceColors.clear();for(const m of materials.values())m.dispose(false,false);materials.clear();originals.clear();environment?.dispose();environment=null;state.viewPlanes?.setGroundAppearance();}
  function syncReferences(){const next=JSON.stringify((state.reference?.entries||[]).map(e=>[e.id,e.name]));if(next!==referenceStamp){referenceStamp=next;rebuild();}}
  return{apply,rebuild,reset,syncReferences};
 }
 return{normalize,STYLES,create};
});
