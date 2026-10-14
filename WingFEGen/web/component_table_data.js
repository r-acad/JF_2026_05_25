/* Physical rib/bay table adapter; all dimensions are persisted in SI units. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./panel_table_data.js'):root.WingPanelTableData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingComponentTableData=api;})(globalThis,function(base){
 'use strict';
 const PARAMETER='properties.components',clone=v=>JSON.parse(JSON.stringify(v));
 const CATALOG={sparwebs:{title:'Spar web properties',parts:['front_web','rear_web'],rows:['Front spar','Rear spar']},sparcaps:{title:'Spar cap properties',parts:['front_upper_cap','front_lower_cap','rear_upper_cap','rear_lower_cap'],rows:['Front upper','Front lower','Rear upper','Rear lower']},ribwebs:{title:'Rib web properties',parts:['rib_web'],rows:['Main-box web'],ribs:true},ribstiffeners:{title:'Rib stiffener properties',parts:['rib_stiffener'],rows:['Vertical T stiffeners'],ribs:true},leskins:{title:'Leading-edge skin properties',parts:['leading_upper_skin','leading_lower_skin'],rows:['Upper skin','Lower skin'],leading:true},leribs:{title:'Leading-edge rib properties',parts:['leading_rib'],rows:['Leading-edge web'],leading:true,ribs:true}};
 const FIELDS=Object.fromEntries(Object.keys(CATALOG).map(kind=>[kind,kind==='sparcaps'?[{name:'side',label:'Square cap side',unit:'mm',scale:1000,type:'number'},{name:'material',label:'Material',type:'material'}]:kind==='ribstiffeners'?[...base.FIELDS.stringers.map(f=>({...f,label:f.name==='material'?'Stiffener material':f.label})),{name:'enabled',label:'Create stiffeners',type:'boolean'}]:base.FIELDS.skins]));
 const rows=p=>{let value=p?.[PARAMETER]||[];if(typeof value==='string')value=JSON.parse(value);if(!Array.isArray(value))throw Error('Component overrides must be a table.');return value;};
 const override=(s,key)=>rows(s.parameters).find(r=>r.key===key)||null;
 function inherited(snapshot,item,kind){const p=snapshot.parameters,part=item.part,index=item.index,array=key=>typeof p[key]==='string'?JSON.parse(p[key]):p[key]||[];
  if(kind==='sparcaps')return{side:p['properties.spar_cap_side'],material:1,...array('materials.bars').find(r=>r.component==='spar_cap')};
  const old=array(kind==='sparwebs'?'properties.spar_bays':'properties.ribs').find(r=>r[kind==='sparwebs'?'bay':'rib']===index)||{};
  if(kind==='ribstiffeners')return{material:1,...array('materials.bars').find(r=>r.component==='rib_stiffener'),...Object.fromEntries(base.FIELDS.stringers.filter(f=>f.type==='number').map(f=>[f.name,old[f.name]??p['properties.rib_stiffener_'+f.name]])),enabled:old.stiffener_enabled??p['properties.rib_stiffeners_enabled']};
  const component=kind==='sparwebs'?'spar_web':kind==='ribwebs'?'rib_web':kind==='leskins'?'leading_edge_skin':'leading_edge_rib';
  const thickness=kind==='sparwebs'?(old[part==='front_web'?'front_thickness':'rear_thickness']??p['properties.t_spar_web']):kind==='ribwebs'?(old.thickness??p['properties.t_rib_web']):p[kind==='leskins'?'leading_edge.t_skin':'leading_edge.t_rib'];
  const value={kind:'monolithic',material:1,face_material:1,core_material:3,face_thickness:.0005,core_thickness:.01,...array('materials.shells').find(r=>r.component===component),thickness};
  const total=kind==='sparwebs'?old[part==='front_web'?'front_thickness':'rear_thickness']:kind==='ribwebs'?old.thickness:undefined;
  if(total!==undefined){value.legacy_total_thickness=total;if(value.kind==='sandwich')value.core_thickness=total-2*value.face_thickness;}
  return value;
 }
 const effective=(s,item,kind)=>{const local=override(s,item.key)||{},v={...inherited(s,item,kind),...local};if(v.kind==='sandwich'&&v.legacy_total_thickness!==undefined&&local.core_thickness===undefined)v.core_thickness=v.legacy_total_thickness-2*v.face_thickness;return v;};
 const fieldState=(s,kind,key,field)=>{const value=override(s,key)?.[field];return value===undefined?{present:false}:{present:true,value};};
 function update(s,kind,key,field,raw){const f=FIELDS[kind]?.find(f=>f.name===field),item=s.panels.find(p=>p.key===key);if(!f||!item)throw Error('This physical component no longer exists; create FEM and refresh the table.');if(s.readOnly)throw Error('Imported Reference properties are read-only in these generated-model tables.');
  const result=clone(rows(s.parameters)),i=result.findIndex(r=>r.key===key),row=i<0?{key}:result[i],value=String(raw??'').trim();
  if(!value)delete row[field];else if(f.type==='kind'){if(!['monolithic','sandwich'].includes(value))throw Error('Choose a valid construction.');row[field]=value;}else if(f.type==='boolean'){if(!['true','false'].includes(value))throw Error('Choose On or Off.');row[field]=value==='true';}else{const n=Number(value)/(f.scale||1);if(!Number.isFinite(n)||n<=0||f.type==='material'&&!Number.isInteger(n))throw Error(f.label+' must be a positive '+(f.type==='material'?'material ID.':'value.'));row[field]=n;}
  const next={...inherited(s,item,kind),...row};if(next.kind==='sandwich'&&next.legacy_total_thickness!==undefined&&row.core_thickness===undefined)next.core_thickness=next.legacy_total_thickness-2*next.face_thickness;
  if(kind==='sparcaps'){if(!(Number.isFinite(next.side)&&next.side>0))throw Error('The cap side must be positive.');if(!base.materialList(s.parameters).some(m=>m.id===next.material))throw Error('Choose a material from the Study library.');}
  else base.validateSection(next,kind==='ribstiffeners'?'stringers':'skins',s.parameters);
  if(Object.keys(row).length===1){if(i>=0)result.splice(i,1);}else if(i<0)result.push(row);
  return result.sort((a,b)=>a.key.localeCompare(b.key,undefined,{numeric:true}));
 }
 function compact(raw={},kind){const meta=CATALOG[kind],parameters={...base.parameters(raw.parameters),...Object.fromEntries(Object.entries(raw.parameters||{}).filter(([k])=>k.startsWith('leading_edge.')))},n=raw.rib_count??raw.ribs?.length??0,panels=[];
  const disabled=new Set();for(const entry of String(parameters['leading_edge.disabled_bays']||'').split(',')){const pair=entry.trim().match(/^(\d+)(?:\s*-\s*(\d+))?$/);if(pair)for(let b=+pair[1];b<=+(pair[2]||pair[1]);b++)disabled.add(b);}
  const first=Number(parameters['leading_edge.start_rib']||1),last=Number(parameters['leading_edge.end_rib']||n),active=new Set();for(let b=first;b<last;b++)if(!disabled.has(b))active.add(b);
  if(meta&&!raw.readOnly)meta.parts.forEach((part,r)=>{for(let index=1;index<=(meta.ribs?n:n-1);index++){if(meta.leading&&(!parameters['leading_edge.enabled']||!(meta.ribs?(active.has(index)||active.has(index-1)):active.has(index))))continue;panels.push({key:part+':'+index,id:part+':'+index,part,index,stringer:r+1,rib_bay:index,segment:1,skin:'upper',label:meta.ribs?'R'+index:'R'+index+'–R'+(index+1)});}});
  return{parameters,panels,rib_count:n,layout_token:raw.component_layout_token||raw.layout_token||'',modelDirty:!!raw.modelDirty,busy:!!raw.busy,updating:!!raw.updating,readOnly:!!raw.readOnly,error:String(raw.error||'')};
 }
 function matrix(s){const stringers=[...new Set(s.panels.map(p=>p.stringer))].sort((a,b)=>a-b),bays=[...new Set(s.panels.map(p=>p.rib_bay))].sort((a,b)=>a-b),cells=new Map();for(const p of s.panels)cells.set(p.stringer+':'+p.rib_bay,[p]);return{stringers,bays,cells};}
 return{PARAMETER,FIELDS,CATALOG,section:()=>null,rows,materialList:base.materialList,inherited,override,fieldState,sameField:base.sameField,effective,update,compact,matrix,display:base.display,component:true};
});
