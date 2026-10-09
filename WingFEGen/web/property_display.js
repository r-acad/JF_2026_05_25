/* Generated-property colors. Never read draft inputs or invent a laminate modulus. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPropertyDisplay=api;})(globalThis,function(){
 'use strict';
 const defaults={enabled:false,field:'shell_thickness',materialRole:'single'};
 const FIELDS=[
  {id:'shell_thickness',group:'Shells',label:'Total thickness',unit:'mm'},
  {id:'face_thickness',group:'Shells',label:'Each sandwich face thickness',unit:'mm'},
  {id:'core_thickness',group:'Shells',label:'Sandwich core thickness',unit:'mm'},
  {id:'areal_mass',group:'Shells',label:'Mass per unit area',unit:'kg/m²'},
  {id:'mean_density',group:'Shells',label:'Through-thickness mean density',unit:'kg/m³'},
  {id:'beam_area',group:'Beams',label:'Section area',unit:'mm²'},
  {id:'beam_I1',group:'Beams',label:'Section I1',unit:'mm⁴'},
  {id:'beam_I2',group:'Beams',label:'Section I2',unit:'mm⁴'},
  {id:'beam_J',group:'Beams',label:'Torsion constant J',unit:'mm⁴'},
  {id:'beam_height',group:'Beams',label:'Section height',unit:'mm'},
  {id:'beam_width',group:'Beams',label:'Section width',unit:'mm'},
  {id:'beam_flange',group:'Beams',label:'T flange thickness',unit:'mm'},
  {id:'beam_web',group:'Beams',label:'T web thickness',unit:'mm'},
  {id:'section_type',group:'Beams',label:'Section card and shape',unit:'category',categorical:true},
  {id:'material',group:'Materials',label:'Material IDs and names',unit:'assignment',categorical:true},
  {id:'E',group:'Materials',label:'Young’s modulus',unit:'GPa',sample:true},
  {id:'nu',group:'Materials',label:'Poisson ratio',unit:'dimensionless',sample:true},
  {id:'rho',group:'Materials',label:'Material density',unit:'kg/m³',sample:true},
  {id:'pid',group:'Identification',label:'Property ID (PID)',unit:'PID',categorical:true},
 ];
 const roles={single:'Single-material elements',face:'Sandwich face (first ply)',core:'Sandwich core (middle ply)'};
 function validateState(value){
  if(value==null)return{...defaults};
  if(typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!Object.hasOwn(defaults,k)))throw Error('Invalid property-display settings.');
  const result={...defaults,...value};
  if(typeof result.enabled!=='boolean'||!FIELDS.some(f=>f.id===result.field)||!Object.hasOwn(roles,result.materialRole))throw Error('Invalid property-display selection.');
  return result;
 }
 function ids(value){
  if(value instanceof Int32Array||Array.isArray(value))return value;
  if(value instanceof Uint8Array&&value.byteLength%4===0){const view=new DataView(value.buffer,value.byteOffset,value.byteLength);return Array.from({length:value.byteLength/4},(_,i)=>view.getInt32(i*4,true));}
  return [];
 }
 const finite=value=>typeof value==='number'&&Number.isFinite(value);
 const scaled=(value,factor=1)=>finite(value)?value*factor:undefined;
 const sandwich=p=>p?.plies?.length===3&&(p.construction==='sandwich'||finite(p.face_thickness_m)&&finite(p.core_thickness_m));
 function material(p,role){
  if(p?.type!=='PCOMP')return role==='single'?p?.material:undefined;
  const plies=p.plies;
  if(!Array.isArray(plies)||!plies.length||role==='single')return undefined;
  // The generator writes explicit face/core/face plies. Do not guess another layup.
  if(!sandwich(p))return undefined;
  return plies[role==='face'?0:1]?.material;
 }
 function materialLabel(m){return Number.isInteger(m?.id)?(m.type||'MAT1')+' '+m.id+(m.name?' · '+m.name:''):null;}
 function value(group,field,settings){
  const p=group.properties||{},beam=group.kind==='bar',s=p.section||{},d=s.dimensions_m||[];
  if(field==='pid')return Number.isInteger(group.pid)?{key:String(group.pid),label:'PID '+group.pid}:undefined;
  if(field==='material'){
   if(p.type==='PCOMP'){
    if(!Array.isArray(p.plies)||!p.plies.length)return undefined;
    const names=p.plies.map(ply=>materialLabel(ply.material));if(names.some(n=>!n))return undefined;
    const standard=sandwich(p)&&p.plies[0].material.id===p.plies[2].material.id;
    return{key:'PCOMP:'+p.plies.map(ply=>ply.material.id).join('/'),label:standard?'Faces: '+names[0]+'; core: '+names[1]:'Plies: '+names.join(' / ')};
   }
   const label=materialLabel(p.material);return label?{key:(p.material.type||'MAT1')+':'+p.material.id,label}:undefined;
  }
  if(['E','nu','rho'].includes(field)){
   const m=material(p,settings.materialRole);return scaled(m?.[({E:'E_Pa',nu:'nu',rho:'rho_kg_m3'})[field]],field==='E'?1e-9:1);
  }
  if(beam){
   if(field==='section_type')return s.type&&s.shape?{key:s.type+':'+s.shape,label:s.type+' · '+(s.shape==='T'?'T section':s.shape==='BAR'?'Rectangle / square':s.shape)}:undefined;
   const quantities={beam_area:'area_m2',beam_I1:'I1_m4',beam_I2:'I2_m4',beam_J:'J_m4'};
   if(quantities[field])return scaled(s[quantities[field]],field==='beam_area'?1e6:1e12);
   if(!['T','BAR'].includes(s.shape))return undefined;
   if(field==='beam_height')return scaled(d[1],1e3);
   if(field==='beam_width')return scaled(d[0],1e3);
   if(s.shape==='T'&&field==='beam_flange')return scaled(d[2],1e3);
   if(s.shape==='T'&&field==='beam_web')return scaled(d[3],1e3);
   return undefined;
  }
  if(field==='shell_thickness')return scaled(p.thickness_m,1e3);
  if(field==='face_thickness'&&p.type==='PCOMP')return scaled(p.face_thickness_m,1e3);
  if(field==='core_thickness'&&p.type==='PCOMP')return scaled(p.core_thickness_m,1e3);
  if(field==='areal_mass')return scaled(p.areal_mass_kg_m2);
  if(field==='mean_density'&&finite(p.thickness_m)&&p.thickness_m>0)return scaled(p.areal_mass_kg_m2,1/p.thickness_m);
 }
 function build(data,options={}){
  const settings=validateState(options),field=FIELDS.find(f=>f.id===settings.field),byId=new Map(),categories=[],groups=[],categoryMap=new Map();let total=0;
  for(const group of data?.groups||[]){
   if(!['quad','tria','bar'].includes(group.kind))continue;
   const eids=ids(group.eids);total+=eids.length;const scalar=value(group,field.id,settings);
   if(field.categorical?scalar&&typeof scalar.key==='string':finite(scalar)){
    groups.push({eids,value:scalar});if(field.categorical)categoryMap.set(scalar.key,scalar.label);
   }
  }
  if(field.categorical)for(const [key,label]of [...categoryMap].sort((a,b)=>a[0].localeCompare(b[0],undefined,{numeric:true}))){categories.push({value:categories.length,key,label});}
  const indices=new Map(categories.map(c=>[c.key,c.value]));let min=Infinity,max=-Infinity;
  for(const group of groups){const scalar=field.categorical?indices.get(group.value.key):group.value;min=Math.min(min,scalar);max=Math.max(max,scalar);for(const eid of group.eids)byId.set(Number(eid),scalar);}
  if(!byId.size)min=max=0;
  let note=(data?.imported_deck?'Imported Nastran properties':'Generated FEM properties')+' · full element values; gray = not applicable or unavailable.';
  if(field.sample)note+=' '+roles[settings.materialRole]+'. No equivalent sandwich elastic modulus or Poisson ratio is assumed.';
  if(field.id==='mean_density')note+=' Shell areal mass divided by total thickness; this is a mass average, not an elastic equivalent.';
  if(field.id==='beam_J')note+=' J is the torsion constant used by the deck, including its PBARL approximation.';
  if(['beam_I1','beam_I2'].includes(field.id))note+=' About the section centroid in the beam’s local section frame.';
  return{kind:'properties',location:'element',domain:'all',name:field.group+' · '+field.label+(field.sample?' · '+roles[settings.materialRole]:''),
   unit:field.unit,field:field.id,materialRole:settings.materialRole,byId,min,max,categories:field.categorical?categories:undefined,
   count:byId.size,total,caseLabel:(data?.imported_deck?'Imported deck':'Generated model')+' · independent of load case',note};
 }
 function create(host,options={}){
  const doc=host.ownerDocument;let settings={...defaults},current=null,lastData=null;
  const select=doc.createElement('select');select.id='property-display-field';select.setAttribute('aria-label','Structural property to color');
  for(const group of new Set(FIELDS.map(f=>f.group))){const optgroup=doc.createElement('optgroup');optgroup.label=group;for(const f of FIELDS.filter(f=>f.group===group)){const option=doc.createElement('option');option.value=f.id;option.textContent=f.label+(f.categorical?'':' ('+f.unit+')');optgroup.append(option);}select.append(optgroup);}
  const fieldLabel=doc.createElement('label');fieldLabel.className='display-control';fieldLabel.textContent='Property';fieldLabel.append(select);
  const sampleLabel=doc.createElement('label');sampleLabel.className='display-control';sampleLabel.textContent='Material sample';
  const sample=doc.createElement('select');sample.id='property-display-material';for(const [value,label]of Object.entries(roles)){const option=doc.createElement('option');option.value=value;option.textContent=label;sample.append(option);}sampleLabel.append(sample);
  const actions=doc.createElement('div');actions.className='entity-actions';const show=doc.createElement('button'),hide=doc.createElement('button');show.id='property-display-show';hide.id='property-display-hide';show.className=hide.className='mini';show.textContent='Show property colors';hide.textContent='Hide property colors';actions.append(show,hide);
  const status=doc.createElement('p');status.id='property-display-status';status.className='pick-note';status.setAttribute('role','status');
  const warning=doc.createElement('p');warning.id='property-display-warning';warning.className='property-display-warning';warning.setAttribute('role','status');
  host.append(fieldLabel,sampleLabel,actions,status,warning);
  function refresh(data=options.data?.()){
   const hasData=!!data?.groups?.length;
   if(data!==lastData||!current){lastData=data;current=build(data,settings);}
   select.value=settings.field;sample.value=settings.materialRole;sampleLabel.hidden=!FIELDS.find(f=>f.id===settings.field).sample;
   show.disabled=!hasData;hide.disabled=!settings.enabled;show.classList.toggle('active',settings.enabled);show.setAttribute('aria-pressed',String(settings.enabled));
   status.textContent=!hasData?'Create FEM to display its structural properties.':current.count+' of '+current.total+' structural elements have this property.'+(settings.enabled?' Property colors are shown.':'')+(!current.count?' Choose another property or material sample.':'');
   warning.hidden=!hasData||!options.stale?.();warning.textContent='Definition changed: these colors describe the last generated FEM. Create FEM to update the displayed properties.';
   return current;
  }
  function update(next,notify=true){settings=validateState({...settings,...next});current=null;refresh();if(notify)options.onChange?.({...settings});return settings;}
  select.onchange=()=>update({field:select.value});sample.onchange=()=>update({materialRole:sample.value});show.onclick=()=>update({enabled:true});hide.onclick=()=>update({enabled:false});refresh();
  return{capture:()=>({...settings}),restore:value=>update(validateState(value),false),setEnabled:(enabled,notify=false)=>update({enabled:!!enabled},notify),refresh,
   contour:()=>settings.enabled?refresh():null,get enabled(){return settings.enabled;},destroy:()=>host.replaceChildren()};
 }
 return{FIELDS,defaults,roles,validateState,ids,material,value,build,create};
});
