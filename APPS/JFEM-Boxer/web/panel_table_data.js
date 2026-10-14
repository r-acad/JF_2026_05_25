/* Physical panel overrides: sparse SI values; blank fields inherit defaults. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPanelTableData=api;})(globalThis,function(){
 'use strict';
 const PARAMETER='properties.panels';
 const FIELDS={skins:[
  {name:'thickness',label:'Monolithic thickness',unit:'mm',scale:1000,type:'number'},
  {name:'kind',label:'Construction',type:'kind'},
  {name:'material',label:'Monolithic material',type:'material'},
  {name:'face_thickness',label:'Each face thickness',unit:'mm',scale:1000,type:'number'},
  {name:'core_thickness',label:'Core thickness',unit:'mm',scale:1000,type:'number'},
  {name:'face_material',label:'Face material',type:'material'},
  {name:'core_material',label:'Core material',type:'material'}
 ],stringers:[
  {name:'flange_width',label:'T flange width b',unit:'mm',scale:1000,type:'number'},
  {name:'height',label:'T total height h',unit:'mm',scale:1000,type:'number'},
  {name:'flange_thickness',label:'T flange thickness tf',unit:'mm',scale:1000,type:'number'},
  {name:'web_thickness',label:'T web thickness tw',unit:'mm',scale:1000,type:'number'},
  {name:'material',label:'Stringer material',type:'material'}
 ]};
 const clone=v=>JSON.parse(JSON.stringify(v)),section=kind=>kind==='skins'?'skin':'stringer';
 function parameters(raw){const p={};for(const[key,value]of Object.entries(raw||{}))if(key.startsWith('properties.')||key.startsWith('material.')||key.startsWith('materials.'))p[key]=clone(value);return p;}
 function rows(p){const value=p?.[PARAMETER]||[];const result=typeof value==='string'?JSON.parse(value):value;if(!Array.isArray(result))throw Error('Panel overrides must be a table.');return result;}
 function materialList(p){let library=p?.['materials.library']||[];if(typeof library==='string')library=JSON.parse(library);return[{id:1,name:p?.['material.name']||'Default material'},...library].map(m=>({id:Number(m.id),name:String(m.name)}));}
 function inherited(snapshot,panel,kind){
  const p=snapshot.parameters||{},saved=panel['inherited_'+section(kind)]||{};
  const array=key=>typeof p[key]==='string'?JSON.parse(p[key]):p[key]||[];
  if(kind==='skins')return{kind:'monolithic',material:1,face_material:1,core_material:3,face_thickness:.0005,core_thickness:.01,...saved,
   ...array('materials.shells').find(row=>row.component===panel.skin+'_skin'),thickness:p['properties.t_skin_'+panel.skin]??saved.thickness??panel.skin_thickness_m};
  return{material:1,...saved,...array('materials.bars').find(row=>row.component==='stringer'),...Object.fromEntries(FIELDS.stringers.filter(f=>f.type==='number').map((f,i)=>[f.name,p['properties.stringer_'+f.name]??saved[f.name]??panel.stringer_dimensions_m?.[i]]))};
 }
 function override(snapshot,key){return rows(snapshot.parameters).find(row=>row.key===key)||null;}
 function fieldState(snapshot,kind,key,field){const value=override(snapshot,key)?.[section(kind)]?.[field];return value===undefined?{present:false}:{present:true,value};}
 function sameField(a,b){return !!a&&!!b&&a.present===b.present&&(!a.present||a.value===b.value);}
 function effective(snapshot,panel,kind){return{...inherited(snapshot,panel,kind),...override(snapshot,panel.key)?.[section(kind)]};}
 function validateSection(value,kind,p){
  const ids=new Set(materialList(p).map(m=>m.id)),positive=(v,name)=>{if(typeof v!=='number'||!Number.isFinite(v)||v<=0)throw Error(name+' must be a finite positive number.');},material=(v,name)=>{if(!Number.isInteger(v)||!ids.has(v))throw Error(name+' must use a material in the Study library.');};
  if(kind==='skins'){
   if(!['monolithic','sandwich'].includes(value.kind))throw Error('Choose monolithic or sandwich construction.');
   if(value.kind==='sandwich'){positive(value.face_thickness,'Each face thickness');positive(value.core_thickness,'Core thickness');material(value.face_material,'Face material');material(value.core_material,'Core material');}
   else{positive(value.thickness,'Monolithic thickness');material(value.material,'Monolithic material');}
  }else{
   for(const f of FIELDS.stringers.filter(f=>f.type==='number'))positive(value[f.name],f.label);
   if(value.flange_thickness>=value.height)throw Error('T flange thickness must be smaller than total height.');
   if(value.web_thickness>=value.flange_width)throw Error('T web thickness must be smaller than flange width.');
   material(value.material,'Stringer material');
  }
 }
 function update(snapshot,kind,key,field,raw){
  if(!FIELDS[kind])throw Error('Unknown panel table.');
  const definition=FIELDS[kind].find(f=>f.name===field);if(!definition)throw Error('Unknown panel property.');
  const panel=snapshot.panels?.find(p=>p.key===key);if(!panel)throw Error('This panel no longer exists. Refresh the table after creating FEM.');
  if(typeof snapshot.layout_token!=='string'||!snapshot.layout_token)throw Error('Create FEM with the updated server before editing individual panels.');
  const list=clone(rows(snapshot.parameters)),index=list.findIndex(row=>row.key===key),row=index<0?{key,layout_token:snapshot.layout_token}:list[index];
  if(row.layout_token!==snapshot.layout_token)throw Error('This override belongs to an earlier rib/stringer layout. Reset panel overrides before regenerating.');
  const target=section(kind),value=String(raw??'').trim();row[target]={...row[target]};
  if(!value)delete row[target][field];
  else if(definition.type==='kind'){if(!['monolithic','sandwich'].includes(value))throw Error('Choose monolithic or sandwich construction.');row[target][field]=value;}
  else{const number=Number(value)/(definition.scale||1);if(!Number.isFinite(number)||number<=0||definition.type==='material'&&!Number.isInteger(number))throw Error(definition.label+' must be a valid positive '+(definition.type==='material'?'material ID.':'number.'));row[target][field]=number;}
  validateSection({...inherited(snapshot,panel,kind),...row[target]},kind,snapshot.parameters);
  if(!Object.keys(row[target]).length)delete row[target];if(!row.skin&&!row.stringer){if(index>=0)list.splice(index,1);}else if(index<0)list.push(row);
  return list.sort((a,b)=>a.key.localeCompare(b.key,undefined,{numeric:true}));
 }
 function compact(raw={}){
  const panels=(raw.panels||[]).map(({shell_eids,stringer_eids,stringer_grid_ids,...p})=>p);
  return{parameters:parameters(raw.parameters),panels:clone(panels),layout_token:raw.layout_token||'',modelDirty:!!raw.modelDirty,busy:!!raw.busy,updating:!!raw.updating,resultsCurrent:raw.resultsCurrent===true,error:raw.error?String(raw.error):''};
 }
 function matrix(snapshot,skin){const panels=(snapshot.panels||[]).filter(p=>p.skin===skin),stringers=[...new Set(panels.map(p=>Number(p.stringer)))].sort((a,b)=>a-b),bays=[...new Set(panels.map(p=>Number(p.rib_bay)))].sort((a,b)=>a-b),cells=new Map();for(const p of panels){const key=p.stringer+':'+p.rib_bay;if(!cells.has(key))cells.set(key,[]);cells.get(key).push(p);}for(const list of cells.values())list.sort((a,b)=>a.segment-b.segment||a.id-b.id);return{stringers,bays,cells};}
 function display(value,field){return typeof value==='number'?String(Number((value*(field.scale||1)).toPrecision(10))):String(value??'');}
 return{PARAMETER,FIELDS,section,parameters,rows,materialList,inherited,override,fieldState,sameField,effective,validateSection,update,compact,matrix,display};
});
