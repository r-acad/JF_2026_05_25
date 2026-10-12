/* Read-only derivative tables. Fixed-state operator samples are not responses. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./sensitivity_results.js'):root.WingSensitivityResults,typeof module==='object'&&module.exports?require('./color_scales.js'):root.WingColorScales,()=>typeof module==='object'&&module.exports?require('./component_table_data.js').CATALOG:root.WingComponentTableData?.CATALOG);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSensitivityTableData=api;})(globalThis,function(effects,colors,componentCatalog){
 'use strict';const clone=value=>JSON.parse(JSON.stringify(value));
 function panel(row){const key=row.panel_key||/^properties\.panels#([^#]+)#/.exec(row.id||'')?.[1],match=/^(upper|lower):bay([1-9]\d*):stringer([1-9]\d*):segment([1-9]\d*)$/.exec(key||'');if(!match)return null;
  const ids=[...new Set((row.pids||[]).map(Number).filter(pid=>[5,6,7].includes(Math.floor(pid/1000000))).map(pid=>pid%1000000))],id=ids.length===1?ids[0]:Number(/^P(\d+)\b/.exec(row.label||'')?.[1])||null;
  return{key,skin:match[1],rib_bay:Number(match[2]),stringer:Number(match[3]),segment:Number(match[4]),id};
 }
 const GROUPS={upper:'Upper skin / stringers',lower:'Lower skin / stringers',sparwebs:'Spar webs',sparcaps:'Spar caps',ribwebs:'Rib webs',ribstiffeners:'Rib stiffeners',leskins:'Leading-edge skins',leribs:'Leading-edge ribs'},isPanelGroup=group=>group==='upper'||group==='lower';
 const PART_GROUP={front_web:'sparwebs',rear_web:'sparwebs',front_upper_cap:'sparcaps',front_lower_cap:'sparcaps',rear_upper_cap:'sparcaps',rear_lower_cap:'sparcaps',rib_web:'ribwebs',rib_stiffener:'ribstiffeners',leading_upper_skin:'leskins',leading_lower_skin:'leskins',leading_rib:'leribs'};
 // Physical location comes from the recorded variable ID, never an arbitrary
 // imported PID. Shared material/default derivatives retain their full scope.
 function component(row){const id=String(row.id||'');let match=/^properties\.components#([a-z_]+):([1-9]\d*)#/.exec(id),part,index;
  if(match){part=match[1];index=Number(match[2]);}
  else if((match=/^properties\.ribs#([1-9]\d*)#(.+)$/.exec(id))){part=match[2]==='thickness'?'rib_web':'rib_stiffener';index=Number(match[1]);}
  else if((match=/^properties\.spar_bays#([1-9]\d*)#(front|rear)_thickness$/.exec(id))){part=match[2]+'_web';index=Number(match[1]);}
  if(!PART_GROUP[part]||!Number.isSafeInteger(index))return null;
  return{key:part+':'+index,part,index,group:PART_GROUP[part]};
 }
 function rowGroups(snapshot,row){const physical=component(row);if(physical)return[physical.group];const p=panel(row);if(p)return[p.skin];const id=String(row.id||''),fixed={'properties.t_spar_web':'sparwebs','properties.spar_cap_side':'sparcaps','properties.t_rib_web':'ribwebs','leading_edge.t_skin':'leskins','leading_edge.t_rib':'leribs'};
  if(fixed[id])return[fixed[id]];if(id.startsWith('properties.rib_stiffener_'))return['ribstiffeners'];
  const sandwich=/^materials\.shells#([^#]+)#/.exec(id),shellGroups={spar_web:'sparwebs',rib_web:'ribwebs',leading_edge_skin:'leskins',leading_edge_rib:'leribs'};
  if(sandwich&&shellGroups[sandwich[1]])return[shellGroups[sandwich[1]]];
  const ownership=snapshot.ownership||snapshot.scope||snapshot.result?.scope||{},pids=new Set((row.pids||ownership.variables?.[row.id]?.pids||[]).map(Number)),groups=new Set();
  for(const item of ownership.groups||[]){if(!pids.has(Number(item.pid)))continue;const name=String(item.name||'').replace(/_P\d+$/,'');const group={FRONT_SPAR_WEB:'sparwebs',REAR_SPAR_WEB:'sparwebs',SPAR_CAPS:'sparcaps',RIB_WEBS:'ribwebs',RIB_STIFFENERS:'ribstiffeners',LE_UPPER_SKIN:'leskins',LE_LOWER_SKIN:'leskins',LE_RIB_WEBS:'leribs',LE_RIB_NOSE:'leribs'}[name];if(group)groups.add(group);}
  return[...groups];
 }
 // Only generated, physical length variables have an inferable unit when no
 // row was returned. Do not invent units for absent material/imported rows.
 function requestedComponents(snapshot){const recorded=new Set((snapshot.result?.rows||[]).map(row=>row.id)),unit=effects.baseline(snapshot.result).unit;return(snapshot.result?.request?.variables||[]).filter(id=>!recorded.has(id)&&component({id})&&/#(?:side|thickness|face_thickness|core_thickness|front_thickness|rear_thickness|flange_width|height|flange_thickness|web_thickness)$/.test(id)).map(id=>({id,pids:snapshot.ownership?.variables?.[id]?.pids||[],unit:'m',derivative_unit:unit?unit+' / m':''}));}
 function availableComponents(snapshot){
  const result=snapshot.result||{},ownership=snapshot.ownership||snapshot.scope||result.scope||{},unit=effects.baseline(result).unit,items=new Map();
  for(const row of ownership.available_components||[])if(component(row)&&Array.isArray(row.pids)&&row.pids.length)items.set(row.id,{...row,derivative_unit:row.derivative_unit||(unit?unit+' / '+(row.unit||'m'):''),available:true});
  // Early local-component runs did not save the complete catalogue. Their
  // verified generated formulation and recorded card ownership can still tell
  // us which local dimensions a shared variable controlled, but never their
  // uncomputed derivatives. Arbitrary imported PIDs must not be interpreted.
  if(!result.imported_signature&&/^rib_.*localcomponents_v\d+/.test(String(result.load_application_version||''))){
   const parts=['front_upper_cap','front_lower_cap','rear_upper_cap','rear_lower_cap','leading_upper_skin','leading_lower_skin','leading_rib','rib_web','rib_stiffener','front_web','rear_web'];
   const names={front_upper_cap:['SPAR_CAPS'],front_lower_cap:['SPAR_CAPS'],rear_upper_cap:['SPAR_CAPS'],rear_lower_cap:['SPAR_CAPS'],leading_upper_skin:['LE_UPPER_SKIN'],leading_lower_skin:['LE_LOWER_SKIN'],leading_rib:['LE_RIB_WEBS','LE_RIB_NOSE'],rib_web:['RIB_WEBS'],rib_stiffener:['RIB_STIFFENERS'],front_web:['FRONT_SPAR_WEB'],rear_web:['REAR_SPAR_WEB']};
   const dimensions={'shell.thickness':'thickness','shell.face_thickness':'face_thickness','shell.core_thickness':'core_thickness','section.square_side':'side','section.flange_width':'flange_width','section.height':'height','section.flange_thickness':'flange_thickness','section.web_thickness':'web_thickness'};
   const byPid=new Map();for(const row of result.rows||[]){const f=family(row),field=dimensions[f.key.split('|')[0]];if(!field)continue;for(const value of row.pids||ownership.variables?.[row.id]?.pids||[]){const pid=Number(value);if(!parts[Math.floor(pid/1000000)-8])continue;if(!byPid.has(pid))byPid.set(pid,[]);byPid.get(pid).push({row,f,field});}}
   for(const card of ownership.groups||[]){const pid=Number(card.pid),part=parts[Math.floor(pid/1000000)-8],index=pid%1000000,name=String(card.name||'').replace(/_KINKS$/,'').replace(/_P\d+$/,'');if(!part||!Number.isSafeInteger(index)||index<1||name&&!names[part].includes(name))continue;
    for(const {row,f,field} of byPid.get(pid)||[]){
     const id='properties.components#'+part+':'+index+'#'+field;if(!items.has(id))items.set(id,{id,pids:[pid],unit:row.unit||'m',derivative_unit:row.derivative_unit||(unit?unit+' / '+(row.unit||'m'):''),field_key:f.key.split('|')[0],field_label:f.name,available:true});
    }
   }
  }
  return [...items.values()];
 }
 function componentDefinitions(snapshot){return [...new Map([...availableComponents(snapshot),...requestedComponents(snapshot),...(snapshot.result?.rows||[])].map(row=>[row.id,row])).values()];}
 function groupFamilies(snapshot,group){if(isPanelGroup(group))return families(snapshot.result,group);const groups=new Map();for(const row of componentDefinitions(snapshot))if(rowGroups(snapshot,row).includes(group)){const f=family(row);if(!groups.has(f.key))groups.set(f.key,f);}return[...groups.values()].sort((a,b)=>(a.key.startsWith('shell.thickness|')?0:a.key.startsWith('section.')?1:2)-(b.key.startsWith('shell.thickness|')?0:b.key.startsWith('section.')?1:2)||a.key.localeCompare(b.key));}
 function availableGroups(snapshot){return Object.keys(GROUPS).filter(group=>groupFamilies(snapshot,group).length);}
 function componentMatrix(snapshot,group,field){const meta=componentCatalog()?.[group],definitions=new Map(),result=snapshot.result||{},returned=new Set(result.rows||[]),requested=new Set(result.request?.variables||[]),hasSelection=Array.isArray(result.request?.variables),all=componentDefinitions(snapshot);
  for(const row of all){const p=component(row);if(p?.group!==group)continue;if(!definitions.has(p.key))definitions.set(p.key,{...p,rows:[]});if(family(row).key!==field)continue;const item=definitions.get(p.key);if(!item.property_ids)item.property_ids=[];item.property_ids.push(row.id);if(returned.has(row))item.rows.push(row);}
  if(![...definitions.values()].some(item=>item.property_ids?.length))definitions.clear();
  const parts=(meta?.parts||[]).filter(part=>[...definitions.values()].some(item=>item.part===part)),indices=[...new Set([...definitions.values()].map(item=>item.index))].sort((a,b)=>a-b),cells=new Map();
  for(const item of definitions.values()){
   const selected=(item.property_ids||[]).some(id=>requested.has(id)),pending=['running','partial'].includes(String(result.status).toLowerCase());
   item.missing=selected?{status:pending?'pending':'missing',label:pending?'Selected · pending':'Selected · result missing',reason:'This local property was selected, but no derivative row was returned. '+(pending?'The run is not complete.':'Inspect the run log or rerun this property.')}:hasSelection?{status:'not_selected',label:'Not selected',reason:'This local component dimension was not selected in this recorded run. In Analysis → Sensitivity, refresh model properties: former shared component selections become independent bay/rib variables. Review the selection and click Run sensitivity. Add component variables also selects every local family. Existing shared derivatives cannot be split into local values.'}:{status:'not_recorded',label:'No result in this run',reason:'This older run does not record selected variables.'};
   cells.set(item.part+':'+item.index,item);
  }
  const shared=selectRows(snapshot,{mode:'panels',skin:group,field}).filter(row=>!component(row));
  const localCount=[...cells.values()].filter(item=>item.property_ids?.length).length,returnedCount=[...cells.values()].filter(item=>item.rows.length).length,selectedCount=[...cells.values()].filter(item=>(item.property_ids||[]).some(id=>requested.has(id))).length;
  return{parts,indices,cells,shared,localCount,returnedCount,selectedCount,ribs:!!meta?.ribs,partLabel:part=>meta?.rows?.[meta.parts.indexOf(part)]||part.replaceAll('_',' ')};
 }
 function family(row){const id=String(row.id||''),parts=id.split('#'),part=parts.at(-2),field=parts.at(-1),square=id==='properties.spar_cap_side'||/^properties\.components#(?:front|rear)_(?:upper|lower)_cap:\d+#side$/.test(id);
  let key=square?'section.square_side':row.field_key,name=square?'Square spar cap side':row.field_label;
  if(!key){if(/(?:^material\.|^materials\.library#).*?(?:[.#])(E|nu|rho)$/.test(id)){const f=id.split(/[.#]/).at(-1);key='material.'+f;name={E:'Elastic modulus',nu:'Poisson ratio',rho:'Material density'}[f];}
   else if(/(?:face|core)_thickness$/.test(id)){const f=id.endsWith('face_thickness')?'face_thickness':'core_thickness';key='shell.'+f;name='Sandwich '+f.replaceAll('_',' ');}
   else if(/(?:flange_width|flange_thickness|web_thickness|height)$/.test(id)){const f=id.match(/(flange_width|flange_thickness|web_thickness|height)$/)[1];key='section.'+f;name='T '+f.replaceAll('_',' ');}
   else if(component(row)||/^properties\.t_|^leading_edge\.t_|^properties\.spar_bays#/.test(id)||part==='skin'){key='shell.thickness';name='Shell thickness';}
   else key=(part==='stringer'?'section.':'')+field;
  }
  return{key:key+'|'+(row.derivative_unit||row.unit||''),name:name||field.replaceAll('_',' '),unit:row.derivative_unit||''};
 }
 function propertyLabel(row){const p=panel(row);if(!p)return effects.propertyLabel(row);const parts=String(row.id||'').split('#'),part=parts.at(-2),field=parts.at(-1),name=(part==='skin'?'Skin ':part==='stringer'?'Stringer ':'')+field.replaceAll('_',' ');
  return(p.id?'P'+p.id:'Panel')+' \u00b7 '+(p.skin==='upper'?'Upper':'Lower')+' R'+p.rib_bay+'\u2013R'+(p.rib_bay+1)+', stringer '+p.stringer+', segment '+p.segment+': '+name;
 }
 function requestedPanels(result){
  const recorded=new Set((result?.rows||[]).map(row=>row.id)),unit=effects.baseline(result).unit;
  return(result?.request?.variables||[]).filter(id=>!recorded.has(id)&&panel({id})).map(id=>({id,unit:'m',derivative_unit:unit?unit+' / m':''}));
 }
 function families(result,skin){const groups=new Map();for(const row of [...(result?.rows||[]),...requestedPanels(result)]){const p=panel(row);if(!p||(skin&&p.skin!==skin))continue;const f=family(row);if(!groups.has(f.key))groups.set(f.key,f);}return[...groups.values()].sort((a,b)=>(a.key.startsWith('shell.thickness|')?0:1)-(b.key.startsWith('shell.thickness|')?0:1));}
 function value(result,row,quantity='derivative'){
  if(['failed','unavailable','error'].includes(String(row.status||'').toLowerCase()))return{value:null,reason:row.warning||row.message||'Derivative unavailable ('+row.status+').',status:row.status};
  if(!Number.isFinite(row.derivative))return{value:null,reason:row.warning||row.message||'No finite derivative was returned.',status:'unavailable'};
  if(quantity==='derivative')return{value:row.derivative,unit:row.derivative_unit||((effects.baseline(result).unit||'response')+' / '+(row.unit||'property')),reason:row.warning||'',status:row.status||'ok'};
  const base=effects.baseline(result).value;if(!Number.isFinite(base)||base===0)return{value:null,unit:'dimensionless',reason:'Normalized derivative is undefined for a missing or zero baseline; choose df/dp.',status:'undefined'};
  const normalized=(row.value/base)*row.derivative;
  return Number.isFinite(normalized)?{value:normalized,unit:'dimensionless',reason:row.warning||'',status:row.status||'ok'}:{value:null,unit:'dimensionless',reason:'No finite normalized derivative is available.',status:'unavailable'};
 }
 function compact(raw={}){
  const result=raw.result?clone({...raw.result,rows:(raw.result.rows||[]).map(({samples,...row})=>row),scope:undefined,baseline_analysis:undefined}):null;
  const scope=raw.ownership||raw.scope||raw.result?.scope||{},ownership={groups:(scope.groups||[]).map(({pid,kind,name})=>({pid,kind,name})),variables:Object.fromEntries(Object.entries(scope.variables||{}).map(([id,item])=>[id,{pids:[...(item.pids||[])]}])),available_components:(scope.available_components||[]).map(({id,label,pids,unit,field_key,field_label,component_key,value})=>({id,label,pids:[...(pids||[])],unit,field_key,field_label,component_key,value}))};
  return{result,ownership,compatibility:clone(raw.compatibility||raw.result?.compatibility||{}),sourcePath:String(raw.sourcePath||raw.source_path||''),error:String(raw.error||''),panels:(raw.panels||[]).map(({id,key,skin,rib_bay,stringer,segment})=>({id,key,skin,rib_bay,stringer,segment}))};
 }
 function matrix(snapshot,skin,field){
  const definitions=new Map(),records=new Map(),rows=snapshot.result?.rows||[],requested=snapshot.result?.request?.variables,selection=Array.isArray(requested)?new Set(requested):null;
  if(snapshot.compatibility?.topology_match===true)for(const p of snapshot.panels||[])if(p.skin===skin)definitions.set(p.key,p);
  for(const row of rows){const p=panel(row);if(!p||p.skin!==skin)continue;definitions.set(p.key,p);if(family(row).key===field){if(!records.has(p.key))records.set(p.key,[]);records.get(p.key).push(row);}}
  for(const row of requestedPanels(snapshot.result)){const p=panel(row);if(p.skin===skin&&!definitions.has(p.key))definitions.set(p.key,p);}
  const panels=[...definitions.values()],stringers=[...new Set(panels.map(p=>p.stringer))].sort((a,b)=>a-b),bays=[...new Set(panels.map(p=>p.rib_bay))].sort((a,b)=>a-b),cells=new Map();
  const [part,name]=field.split('|')[0].split('.'),suffix=(part==='shell'?'skin':part==='section'?'stringer':part)+'#'+name;
  for(const p of panels){const key=p.stringer+':'+p.rib_bay,id='properties.panels#'+p.key+'#'+suffix,selected=selection?.has(id),pending=['running','partial'].includes(String(snapshot.result?.status).toLowerCase());
   const missing=selected?{status:pending?'pending':'missing',label:pending?'Selected · pending':'Selected · result missing',reason:'This property was selected in the recorded run, but no derivative row was returned. '+(pending?'The run is not complete.':'Inspect the run log or rerun this property.')}:selection?{status:'not_selected',label:'Not selected for this property',reason:'This panel/property combination was not selected in this recorded run. Selections in the Study may have changed since then.'}:{status:'not_recorded',label:'No result in this run',reason:'No derivative row is recorded and this older run does not record its selected variables.'};
   if(!cells.has(key))cells.set(key,[]);cells.get(key).push({...p,rows:records.get(p.key)||[],property_id:id,missing});}for(const cell of cells.values())cell.sort((a,b)=>a.segment-b.segment||a.id-b.id);
  return{stringers,bays,cells};
 }
 function selectRows(snapshot,{mode='all',skin='upper',field='',filter=''}={}){const query=filter.toLowerCase();return(snapshot.result?.rows||[]).filter(row=>{const p=panel(row);return(mode==='other'?!p:mode==='panels'?(isPanelGroup(skin)?p?.skin===skin:rowGroups(snapshot,row).includes(skin))&&family(row).key===field:true)&&(!query||[propertyLabel(row),row.id,row.field_label,p?.key].join(' ').toLowerCase().includes(query));});}
 const csvCell=value=>{let text=value==null?'':String(value);if(typeof value==='string'&&/^\s*[=+@-]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';};
 function csv(snapshot,options={}){const result=snapshot.result||{},baseline=effects.baseline(result),rows=[['Case','Objective','Baseline','Response unit','Property','Property ID','Panel','Skin','Stringer','Rib bay','Segment','Property value','Property unit','df/dp','Derivative unit','p/f * df/dp','Selected quantity','Selected value','Structural groups','Component','Rib / bay index','Property cards','Status','Note']];
  for(const row of selectRows(snapshot,options)){const p=panel(row),c=component(row),raw=value(result,row,'derivative'),normalized=value(result,row,'normalized'),selected=options.quantity==='normalized'?normalized:raw;rows.push([result.case_label||result.case_id,effects.objectiveLabel(result),baseline.value,baseline.unit,propertyLabel(row),row.id,p?.id? 'P'+p.id:'',p?.skin,p?.stringer,p?.rib_bay,p?.segment,row.value,row.unit,raw.value,raw.unit,normalized.value,options.quantity==='normalized'?'p/f * df/dp':'df/dp',selected.value,rowGroups(snapshot,row).map(group=>GROUPS[group]).join('; '),c?.part,c?.index,(row.pids||[]).join('; '),selected.status,selected.reason]);}
  return rows.map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n';
 }
 // Raw derivatives with different units cannot share a numerical color range.
 function colorScales(snapshot,options={}){
  const scales=new Map();for(const row of selectRows(snapshot,options)){
   const item=value(snapshot.result,row,options.quantity),unit=item.unit||row.derivative_unit||'unspecified units';
   if(!Number.isFinite(item.value))continue;
   const scale=scales.get(unit)||{unit,min:Infinity,max:-Infinity,count:0};scale.min=Math.min(scale.min,item.value);scale.max=Math.max(scale.max,item.value);scale.count++;scales.set(unit,scale);
  }
  return scales;
 }
 function valueColor(number,scale,palette='signed'){
  const min=scale?.min,max=scale?.max;if(!Number.isFinite(number)||!Number.isFinite(min)||!Number.isFinite(max)||min>max)return null;
  if(palette!=='signed'&&colors.scales[palette])return 'rgb('+colors.sample(palette,min===max?.5:(number-min)/(max-min)).map(v=>Math.round(v*255)).join(', ')+')';
  const red=[195,52,66],blue=[48,112,196],zero=[242,243,239],mix=(a,b,t)=>'rgb('+a.map((c,i)=>Math.round(c+(b[i]-c)*Math.min(1,Math.max(0,t)))).join(', ')+')';
  if(min===max)return mix(zero,number<0?red:number>0?blue:zero,.55);
  // Exact one-sided ranges use the full corresponding hue. If the values
  // straddle zero, the neutral stop sits at zero's true numerical position.
  if(max<=0)return mix(red,max===0?zero:[251,225,228],(number-min)/(max-min));
  if(min>=0)return mix(min===0?zero:[220,233,250],blue,(number-min)/(max-min));
  return number<0?mix(zero,red,number/min):mix(zero,blue,number/max);
 }
 function colorStops(scale,palette='signed'){
  const {min,max}=scale;if(min===max)return[{value:min,position:0,color:valueColor(min,scale,palette)}];
  if(palette!=='signed'&&colors.scales[palette])return colors.scales[palette].map(([position])=>{const value=min+(max-min)*position;return {value,position,color:valueColor(value,scale,palette)};});
  const values=min<0&&max>0?[min,0,max]:[min,min/2+max/2,max];
  return values.map(value=>({value,position:(value-min)/(max-min),color:valueColor(value,scale,palette)}));
 }
 return{GROUPS,isPanelGroup,component,rowGroups,groupFamilies,availableGroups,availableComponents,componentMatrix,panel,family,families,propertyLabel,value,compact,matrix,selectRows,csv,colorScales,valueColor,colorStops};
});
