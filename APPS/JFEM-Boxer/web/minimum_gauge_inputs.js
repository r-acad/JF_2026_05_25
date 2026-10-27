/* Editable family minima constrain active local property dimensions. SI storage. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMinimumGaugeInputs=api;})(globalThis,function(){
 'use strict';
 const finite=v=>typeof v==='number'&&Number.isFinite(v),array=v=>typeof v==='string'?JSON.parse(v):Array.isArray(v)?v:[];
 const SHELL_KEYS={upper_skin:'properties.t_skin_upper',lower_skin:'properties.t_skin_lower',spar_web:'properties.t_spar_web',rib_web:'properties.t_rib_web',leading_edge_skin:'leading_edge.t_skin',leading_edge_rib:'leading_edge.t_rib'};
 const T_FIELDS=['flange_width','height','flange_thickness','web_thickness'];
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
 return{dimensions,validate,fieldMinimum};
});
