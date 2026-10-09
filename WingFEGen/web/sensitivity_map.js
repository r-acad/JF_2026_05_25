/* A property controls many elements. Its scalar-response derivative is shared,
   never divided among elements or presented as a local stress sensitivity. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./sensitivity_results.js'):root.WingSensitivityResults);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSensitivityMap=api;})(globalThis,function(effects){
 'use strict';
 function valueRange(values){
  let min=Infinity,max=-Infinity,count=0;for(const value of values){if(!Number.isFinite(value))continue;min=Math.min(min,value);max=Math.max(max,value);count++;}
  return count?{min:min||0,max:max||0,count}:{min:0,max:0,count:0};
 }
 function build(result,row,scope,changePercent=1,metric='percent'){
  const effect=effects.rowEffect(result,row,changePercent);
  if(!effect.valid)throw Error(effect.reason);
  const ids=scope?.variables?.[row.id]?.eids;
  if(!Array.isArray(ids)||!ids.length)throw Error('No verified element scope is available for this property. Open the matching Study and create its FEM, then reopen the saved run.');
  const usePercent=metric==='percent'&&effect.percentOfBaseline!==null;
  const value=(usePercent?effect.percentOfBaseline:effect.deltaResponse)||0;
  return {kind:'sensitivity',location:'element',domain:'all',byId:new Map(ids.map(id=>[Number(id),value])),min:value,max:value,
   name:'Predicted response change · '+effects.propertyLabel(row),unit:usePercent?'% of baseline':effect.responseUnit,
   caseLabel:(result.case_label||'Case '+result.case_id)+' · '+effects.objectiveLabel(result),
   note:'Shared whole-property effect for '+changePercent+'% change. Gray = other properties. First-order estimate; not a local sensitivity field.',effect,row};
 }
 function family(row){
  if(row.field_key)return{key:row.field_key,label:row.field_label||row.field_key};
  const id=String(row.id||''),last=id.split('#').at(-1);
  if(/^material\.|^materials\.library#/.test(id)){const field=id.startsWith('material.')?id.slice(9):last;return {key:'material.'+field,label:({E:'Elastic modulus',nu:'Poisson ratio',rho:'Material density'})[field]||field};}
  if(/t_skin_(upper|lower)$/.test(id))return{key:'skin_thickness',label:'Box skin thickness'};
  if(id==='properties.t_spar_web'||/^properties\.spar_bays#.*#(front|rear)_thickness$/.test(id))return{key:'spar_thickness',label:'Spar web thickness'};
  if(id==='properties.t_rib_web'||/^properties\.ribs#.*#thickness$/.test(id))return{key:'rib_thickness',label:'Rib web thickness'};
  if(id.startsWith('properties.stringer_'))return{key:id,label:'Stringer '+id.slice(20).replaceAll('_',' ')};
  if(id.startsWith('properties.rib_stiffener_')||/^properties\.ribs#/.test(id)){const field=id.startsWith('properties.rib_stiffener_')?id.slice(25):last;return{key:'rib_stiffener_'+field,label:'Rib stiffener '+field.replaceAll('_',' ')};}
  if(/^materials\.shells#/.test(id))return{key:'sandwich_'+last,label:'Sandwich '+last.replaceAll('_',' ')};
  return{key:id,label:effects.propertyLabel(row)};
 }
 function fields(result,scope){
  const groups=new Map();
  for(const row of result?.rows||[]){
   if(!scope?.variables?.[row.id]?.eids?.length)continue;
   const descriptor=family(row),key=descriptor.key+'|'+(row.derivative_unit||row.unit||'');
   if(!groups.has(key))groups.set(key,{key,label:descriptor.label,rows:[]});
   groups.get(key).rows.push(row);
  }
  return [...groups.values()];
 }
 function buildField(result,scope,key,metric='normalized'){
  const field=fields(result,scope).find(item=>item.key===key);if(!field)throw Error('Choose a structural property field from this run.');
  const owners=new Map(),priority=new Map(),byId=new Map(),rowsById=new Map();let invalid=0;
  // Ownership includes unavailable derivatives: two variables affecting the
  // same element cannot be represented by one property derivative.
  for(const row of field.rows)for(const rawId of scope.variables[row.id].eids){
   const eid=Number(rawId),rank=row.panel_key?2:1;
   if(!owners.has(eid)||rank>priority.get(eid)){owners.set(eid,row.id);priority.set(eid,rank);}
   else if(rank===priority.get(eid)&&owners.get(eid)!==row.id)owners.set(eid,null);
  }
  for(const row of field.rows){
   const effect=effects.rowEffect(result,row,1),value=metric==='derivative'?row.derivative:effect.normalizedDerivative;
   if(!effect.valid||!Number.isFinite(value)){invalid++;continue;}
   for(const rawId of scope.variables[row.id].eids){
    const eid=Number(rawId);
    if(owners.get(eid)===row.id){byId.set(eid,value);rowsById.set(eid,row);}
   }
  }
  if(!byId.size)throw Error(metric==='normalized'?'No unambiguous normalized derivatives are available. For a zero baseline, choose df/dp.':'No unambiguous finite derivatives are available for this field.');
  const {min,max}=valueRange(byId.values());let ambiguous=0;
  for(const owner of owners.values())if(owner===null)ambiguous++;
  return{kind:'sensitivity_field',location:'element',domain:'all',byId,rowsById,min,max,
   name:(metric==='derivative'?'Sensitivity df/dp':'Normalized sensitivity')+' · '+field.label,
   unit:metric==='derivative'?(field.rows[0].derivative_unit||effects.baseline(result).unit+' / '+field.rows[0].unit):'p/f × df/dp',
   caseLabel:(result.case_label||'Case '+result.case_id)+' · '+effects.objectiveLabel(result),field,metric,
   note:'Derivative of the selected response with respect to each attached property. Panel-local derivatives take precedence over shared defaults. Shared properties repeat the same value; values are not summed or averaged.'+
    (ambiguous?' '+ambiguous+' elements have overlapping variables and are gray; inspect the individual property preview.':'')+
    (invalid?' '+invalid+' unavailable property derivatives.':'')+' Gray = no selected property derivative.'};
 }
 return {build,family,fields,buildField,valueRange};
});
