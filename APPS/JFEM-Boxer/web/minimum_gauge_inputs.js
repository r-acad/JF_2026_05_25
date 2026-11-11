/* Editable family minima constrain active local property dimensions. SI storage. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMinimumGaugeInputs=api;})(globalThis,function(){
 'use strict';
 const finite=v=>typeof v==='number'&&Number.isFinite(v),array=v=>typeof v==='string'?JSON.parse(v):Array.isArray(v)?v:[];
 const SHELL_KEYS={upper_skin:'properties.t_skin_upper',lower_skin:'properties.t_skin_lower',spar_web:'properties.t_spar_web',rib_web:'properties.t_rib_web',leading_edge_skin:'leading_edge.t_skin',leading_edge_rib:'leading_edge.t_rib'};
 const T_FIELDS=['flange_width','height','flange_thickness','web_thickness'];
 const isMinimumKey=key=>Object.values(SHELL_KEYS).includes(key)||key==='properties.spar_cap_side'||/^properties\.(stringer|rib_stiffener)_(flange_width|height|flange_thickness|web_thickness)$/.test(key);
 function dimensions(p,component,value){
  const rows=[],add=(field,actual,minimum,key)=>{if(finite(minimum)&&minimum>=0)rows.push({field,value:actual,minimum,key});};
  if(SHELL_KEYS[component]){
   const key=SHELL_KEYS[component],base=array(p['materials.shells']).find(r=>r.component===component)||{},sandwich=base.kind==='sandwich',stack=sandwich?2*base.face_thickness+base.core_thickness:0,min=Math.max(finite(p[key])?p[key]:0,finite(stack)?stack:0);
   add('total_thickness',value.kind==='sandwich'?2*value.face_thickness+value.core_thickness:value.thickness,min,key);
   if(value.kind==='sandwich'&&sandwich){add('face_thickness',value.face_thickness,base.face_thickness,'materials.shells');add('core_thickness',value.core_thickness,base.core_thickness,'materials.shells');}
  }else if(component==='spar_cap')add('side',value.side,p['properties.spar_cap_side'],'properties.spar_cap_side');
  else if(['stringer','rib_stiffener'].includes(component)&&value.enabled!==false){
   const blade=component==='stringer'&&value.flange_width===0;
   for(const field of T_FIELDS){if(blade&&field==='flange_thickness')continue;const key='properties.'+component+'_'+field;add(field,value[field],p[key],key);}
  }
  return rows;
 }
 function validate(p,component,value,label=component.replaceAll('_',' ')){
  for(const row of dimensions(p,component,value)){
   const tolerance=1e-10*Math.max(Math.abs(row.minimum),Math.abs(row.value),1e-12);
   if(!finite(row.value)||row.value<row.minimum-tolerance)throw Error(label+': '+row.field.replaceAll('_',' ')+' cannot be below the minimum gauge '+Number((row.minimum*1000).toPrecision(8))+' mm. Increase the local value or deliberately edit its minimum in Properties.');
  }
  return value;
 }
 function fieldMinimum(p,component,value,field){
  const rows=dimensions(p,component,value),direct=rows.find(r=>r.field===field);let minimum=direct?.minimum;
  if(field==='thickness'&&value.kind!=='sandwich')minimum=rows.find(r=>r.field==='total_thickness')?.minimum;
  if(value.kind==='sandwich'&&['face_thickness','core_thickness'].includes(field)){
   const total=rows.find(r=>r.field==='total_thickness')?.minimum;
   if(finite(total)){const balance=field==='face_thickness'?(total-value.core_thickness)/2:total-2*value.face_thickness;minimum=Math.max(minimum??0,balance,0);}
  }
  return finite(minimum)?minimum:null;
 }
 // This is an explicit editing action, not a loader/parser repair. Raising a
 // family minimum must raise existing smaller local dimensions as well; an
 // unchanged imported Study still goes through the ordinary strict validation.
 function reconcileMinimumEdit(parameters,key){
  const component=Object.keys(SHELL_KEYS).find(part=>SHELL_KEYS[part]===key),
   t=/^properties\.(stringer|rib_stiffener)_(flange_width|height|flange_thickness|web_thickness)$/.exec(key),
   cap=key==='properties.spar_cap_side',minimum=parameters[key];
  if((!component&&!t&&!cap)||!finite(minimum)||minimum<0||minimum===0&&t?.[2]!=='flange_width')return{patches:{},changes:[]};
  const p={...parameters},patches={},changes=[];
  for(const name of ['materials.shells','properties.panels','properties.ribs','properties.spar_bays','properties.components'])p[name]=structuredClone(array(parameters[name]));
  const raise=(row,field,floor,scope)=>{
   const value=row[field],tolerance=1e-10*Math.max(Math.abs(floor),Math.abs(value||0),1e-12);
   if(finite(value)&&value>=0&&value<floor-tolerance){row[field]=floor;changes.push({scope,field,from:value,to:floor});}
  };
  let base=p['materials.shells'].find(row=>row.component===component)||{};
  if(component&&base.kind==='sandwich'&&finite(base.face_thickness)&&finite(base.core_thickness)){
   raise(base,'core_thickness',Math.max(0,minimum-2*base.face_thickness),component+' minimum sandwich');
  }
  const totalFloor=Math.max(minimum,base.kind==='sandwich'?2*base.face_thickness+base.core_thickness:0);
  const shell=(row,family,scope)=>{
   if(family!==component)return;
   let section={...base,...row};const floor=Math.max(minimum,base.kind==='sandwich'?2*base.face_thickness+base.core_thickness:0);
   if(section.kind==='sandwich'){
    // A thicker local face can make the total pass while its explicit core
    // still falls below a newly raised inherited core floor. Respect each
    // active layer minimum as well as the total; preserve thicker layers.
    if(base.kind==='sandwich'){
     raise(row,'face_thickness',base.face_thickness,scope);
     raise(row,'core_thickness',base.core_thickness,scope);
     section={...base,...row};
    }
    if(finite(section.face_thickness)&&finite(section.core_thickness)&&section.core_thickness>=0&&2*section.face_thickness+section.core_thickness<floor){
     const from=section.core_thickness;row.core_thickness=Math.max(section.core_thickness,floor-2*section.face_thickness);changes.push({scope,field:'core_thickness',from,to:row.core_thickness});
    }
   }else raise(row,'thickness',floor,scope);
  };
  const legacyFloor=(part,index)=>{
   const local=p['properties.components'].find(row=>row.key===part+':'+index)||{};
   if((local.kind??base.kind)==='sandwich'&&base.kind==='sandwich'&&!Object.hasOwn(local,'core_thickness')){
    // Legacy rib/spar totals determine their remaining core. Account for a
    // thicker local face when preserving the inherited core minimum.
    const face=Math.max(local.face_thickness??base.face_thickness,base.face_thickness);
    return Math.max(totalFloor,2*face+base.core_thickness);
   }
   return totalFloor;
  };
  for(const row of p['properties.panels']){
   if(component&&row.skin)shell(row.skin,row.key?.startsWith('upper:')?'upper_skin':'lower_skin',row.key);
   if(t?.[1]==='stringer'&&row.stringer)raise(row.stringer,t[2],minimum,row.key+' stringer');
  }
  for(const row of p['properties.ribs']){
   if(component==='rib_web')raise(row,'thickness',legacyFloor('rib_web',row.rib),'R'+row.rib);
   if(t?.[1]==='rib_stiffener')raise(row,t[2],minimum,'R'+row.rib+' stiffener');
  }
  for(const row of p['properties.spar_bays'])if(component==='spar_web')for(const[field,part]of [['front_thickness','front_web'],['rear_thickness','rear_web']])raise(row,field,legacyFloor(part,row.bay),'Bay '+row.bay);
  const families={front_web:'spar_web',rear_web:'spar_web',rib_web:'rib_web',leading_upper_skin:'leading_edge_skin',leading_lower_skin:'leading_edge_skin',leading_rib:'leading_edge_rib'};
  for(const row of p['properties.components']){
   const part=row.key?.split(':')[0];
   if(component)shell(row,families[part],row.key);
   if(t?.[1]==='rib_stiffener'&&part==='rib_stiffener')raise(row,t[2],minimum,row.key);
   if(cap&&['front_upper_cap','front_lower_cap','rear_upper_cap','rear_lower_cap'].includes(part))raise(row,'side',minimum,row.key);
  }
  for(const name of ['materials.shells','properties.panels','properties.ribs','properties.spar_bays','properties.components'])if(JSON.stringify(p[name])!==JSON.stringify(array(parameters[name])))patches[name]=p[name];
  return{patches,changes};
 }
 function reconcileMaterialMinimumEdit(parameters,component){
  const key=SHELL_KEYS[component],assignment=array(parameters['materials.shells']).find(row=>row.component===component);
  if(!key||assignment?.kind!=='sandwich'||!finite(parameters[key])||!finite(assignment.face_thickness)||assignment.face_thickness<=0||!finite(assignment.core_thickness)||assignment.core_thickness<=0)return{patches:{},changes:[]};
  const result=reconcileMinimumEdit(parameters,key);
  // A newly typed layer can be valid while older local totals make the form
  // temporarily invalid. Commit its actual candidate assignment together with
  // the repaired local layers/totals, never a previous canonical assignment.
  result.patches['materials.shells']??=structuredClone(array(parameters['materials.shells']));
  return result;
 }
 return{dimensions,validate,fieldMinimum,reconcileMinimumEdit,reconcileMaterialMinimumEdit,isMinimumKey,shellMinimumKey:component=>SHELL_KEYS[component]||null};
});
