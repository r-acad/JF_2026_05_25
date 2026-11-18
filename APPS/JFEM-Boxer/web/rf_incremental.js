/* Reuse unaffected physical checks during certified fixed-load sizing. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./assessment_load_policy.js'):root.WingAssessmentLoadPolicy,typeof module==='object'&&module.exports?require('./stress_report_data.js'):root.WingStressReportData,typeof module==='object'&&module.exports?require('./minimum_rf_data.js'):root.WingMinimumRFData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFIncremental=api;})(globalThis,function(policy,data,minimum){
 'use strict';
 const entries=value=>value instanceof Map?[...value]:Object.entries(value||{}),canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value,json=value=>JSON.stringify(canonical(value));
 // Derived section constants can differ in the last arithmetic bits when
 // regenerated. This tolerance is far below admitted UI precision. Integer
 // identifiers, types, object membership and ordered arrays remain exact.
 function equivalent(a,b,key=''){
  if(Object.is(a,b)||a===b)return true;
  if(/(^|_)(id|ids|count|index|number)$|^(pid|eid|nodes|connectivity|rib_bay|stringer|segment|version|basisM|basisN|basisSize|modeLimit)$/.test(key)&&typeof a==='number'&&typeof b==='number')return false;
  if(typeof a==='number'&&typeof b==='number'&&Number.isFinite(a)&&Number.isFinite(b))return!(Number.isSafeInteger(a)&&Number.isSafeInteger(b))&&Math.abs(a-b)<=1e-10*Math.max(Math.abs(a),Math.abs(b),Number.MIN_VALUE);
  if(!a||!b||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false;
  if(Array.isArray(a)&&a.length!==b.length)return false;
  const ak=Object.keys(a),bk=Object.keys(b);return ak.length===bk.length&&ak.every(k=>Object.hasOwn(b,k)&&equivalent(a[k],b[k],Array.isArray(a)?key:k));
 }
 function propertyDefinitions(value){const props=new Map();for(const[,e]of entries(value?.elements)){const pid=Number(e.group?.pid);if(!Number.isSafeInteger(pid)||pid<=0||!['quad','tria','shell','solid','bar'].includes(e.group?.kind)||e.group?.name==='aero')continue;if(!props.has(pid))props.set(pid,[]);if(!props.get(pid).some(p=>equivalent(p,e.group?.properties)))props.get(pid).push(e.group?.properties);}return props;}
 const COMPONENTS={spar_web_buckling:['web_panels','spar_web'],rib_web_buckling:['web_panels','rib_web'],spar_cap_buckling:['columns','spar_cap'],rib_stiffener_buckling:['columns','rib_stiffener'],rib_stiffener_blade:['blades','rib_stiffener']};
 function metadata(input,mode){if(COMPONENTS[mode]){const[key,kind]=COMPONENTS[mode];return input.componentBuckling?.[key]?.filter(row=>row.kind===kind);}return input[{euler_column:'eulerColumns',stringer_blade:'stringerBlades',skin_buckling:'skinBucklingPanels'}[mode]];}
 function scoped(input,mode,rows){if(COMPONENTS[mode])return{...input,componentBuckling:{...input.componentBuckling,[COMPONENTS[mode][0]]:rows}};return{...input,[{euler_column:'eulerColumns',stringer_blade:'stringerBlades',skin_buckling:'skinBucklingPanels'}[mode]]:rows};}
 function merge(previous,updated,key,replace){
  const rows=previous.rows.filter(row=>!replace.has(key(row))).concat(updated.rows);
  rows.sort((a,b)=>(Number(a.pid)||0)-(Number(b.pid)||0)||String(a.panelKey||a.rowKey).localeCompare(String(b.panelKey||b.rowKey)));
  const coverage={...previous.coverage,properties:rows.length,recovered:rows.reduce((n,r)=>n+(r.coverage?.recovered||0),0),total:rows.reduce((n,r)=>n+(r.coverage?.total||0),0)};
  const excludedProperties=(previous.excludedProperties||[]).filter(row=>!replace.has(key(row))).concat(updated.excludedProperties||[]);
  return{...previous,rows,coverage,...(previous.excludedProperties||updated.excludedProperties?{excludedProperties}:{}),complete:updated.missingCases?.length===0&&!updated.excludedCases?.some(c=>c.relevant)&&rows.length>0&&rows.every(r=>r.complete),includedCases:updated.includedCases,excludedCases:updated.excludedCases,missingCases:updated.missingCases};
 }
 function changedProperties(input,previous){
  const a=propertyDefinitions(input),b=propertyDefinitions(previous),changed=new Set();
  for(const[pid,p]of a)if(p.length!==b.get(pid)?.length||p.some(value=>!b.get(pid).some(old=>equivalent(value,old))))changed.add(pid);
  if(json(input.allowables)!==json(previous.allowables))for(const pid of a.keys())changed.add(pid);
  return changed;
 }
 function members(raw,index){
  const pids=new Set(),visit=value=>{if(!value||typeof value!=='object')return;if(Number.isSafeInteger(value.pid))pids.add(value.pid);if(Array.isArray(value.property_ids))for(const pid of value.property_ids)pids.add(pid);if(Number.isSafeInteger(value.eid)&&index.has(value.eid))pids.add(index.get(value.eid));if(Array.isArray(value.member_element_ids))for(const eid of value.member_element_ids)if(index.has(eid))pids.add(index.get(eid));for(const v of Object.values(value))if(v&&typeof v==='object')Array.isArray(v)?v.forEach(visit):visit(v);};visit(raw);return pids;
 }
 function build(input,previous,prior){
  const fallback=()=>data.build(input);
  if(!previous||!prior||!input.estimated||input.meshIdentity!==prior.meshIdentity||input.studyEpoch!==prior.studyEpoch||input.failureMode!==prior.failureMode||['caseId','method','percentile'].some(k=>(input[k]??null)!==(prior[k]??null))||json(input.expectedCases)!==json(prior.expectedCases)||json(input.assessmentPolicy)!==json(prior.assessmentPolicy)||json(input.assessmentPolicyWarnings)!==json(prior.assessmentPolicyWarnings))return fallback();
  const sources=input.failureMode==='minimum_rf'?data.criteria(previous):{[input.failureMode]:previous};if(!sources)return fallback();
  const changed=changedProperties(input,prior),index=new Map(entries(input.elements).map(([eid,e])=>[Number(eid),Number(e.group?.pid)])),reports={},counts={properties:[...changed].filter(Number.isFinite).sort((a,b)=>a-b),evaluatedRows:0,reusedRows:0,modes:{}};
  for(const[mode,oldReport]of Object.entries(sources)){
   let fresh,replace,key;
   if(['von_mises','principal_strain'].includes(mode)){
    replace=changed;key=row=>Number(row.pid);
    if(!replace.size){reports[mode]=oldReport;counts.reusedRows+=oldReport.rows.length;continue;}
    const elements=new Map(entries(input.elements).filter(([,e])=>replace.has(Number(e.group?.pid))));fresh=data.build({...input,failureMode:mode,elements});
   }else{
    const rows=metadata(input,mode),old=metadata(prior,mode);if(!Array.isArray(rows)||!Array.isArray(old)){reports[mode]=oldReport;continue;}
    const before=new Map(old.map(row=>[String(row.key),row]));
    if(rows.length!==old.length||rows.some(row=>!before.has(String(row.key))))return fallback();
    const globalChanged=mode==='euler_column'?input.eulerFixityCoefficient!==prior.eulerFixityCoefficient:mode==='skin_buckling'?input.skinFixityCoefficient!==prior.skinFixityCoefficient:COMPONENTS[mode]?input.componentFixities?.[mode]!==prior.componentFixities?.[mode]:false;
    const dirty=rows.filter(row=>globalChanged||!equivalent(row,before.get(String(row.key)))||[...members(row,index)].some(pid=>changed.has(pid)));
    replace=new Set(dirty.map(row=>String(row.key)));key=row=>String(row.panelKey);
    if(!dirty.length){reports[mode]=oldReport;counts.reusedRows+=oldReport.rows.length;continue;}
    fresh=data.build({...scoped(input,mode,dirty),failureMode:mode});
   }
   reports[mode]=merge(oldReport,fresh,key,replace);counts.evaluatedRows+=fresh.rows.length;counts.reusedRows+=oldReport.rows.filter(row=>!replace.has(key(row))).length;counts.modes[mode]=fresh.rows.length;
  }
  const result=input.failureMode==='minimum_rf'?policy.annotate(minimum.build(input,reports),input):reports[input.failureMode];
  result.incremental=counts;data.rememberCriteria(result,reports);return data.bindContext(result,input);
 }
 return{build,changedProperties,members,equivalent,propertyDefinitions};
});
