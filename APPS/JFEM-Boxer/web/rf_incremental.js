/* Reuse unaffected physical checks during certified fixed-load sizing. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./stress_report_data.js'):root.WingStressReportData,typeof module==='object'&&module.exports?require('./minimum_rf_data.js'):root.WingMinimumRFData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFIncremental=api;})(globalThis,function(data,minimum){
 'use strict';
 const entries=value=>value instanceof Map?[...value]:Object.entries(value||{}),json=value=>JSON.stringify(value);
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
  const props=value=>new Map(entries(value.elements).map(([,e])=>[Number(e.group?.pid),e.group?.properties])),a=props(input),b=props(previous),changed=new Set();
  for(const[pid,p]of a)if(json(p)!==json(b.get(pid)))changed.add(pid);
  if(json(input.allowables)!==json(previous.allowables))for(const pid of a.keys())changed.add(pid);
  return changed;
 }
 function members(raw,index){
  const pids=new Set(),visit=value=>{if(!value||typeof value!=='object')return;if(Number.isSafeInteger(value.pid))pids.add(value.pid);if(Array.isArray(value.property_ids))for(const pid of value.property_ids)pids.add(pid);if(Number.isSafeInteger(value.eid)&&index.has(value.eid))pids.add(index.get(value.eid));if(Array.isArray(value.member_element_ids))for(const eid of value.member_element_ids)if(index.has(eid))pids.add(index.get(eid));for(const v of Object.values(value))if(v&&typeof v==='object')Array.isArray(v)?v.forEach(visit):visit(v);};visit(raw);return pids;
 }
 function build(input,previous,prior){
  const fallback=()=>data.build(input);
  if(!previous||!prior||!input.estimated||input.meshIdentity!==prior.meshIdentity||input.studyEpoch!==prior.studyEpoch||input.failureMode!==prior.failureMode||['caseId','method','percentile'].some(k=>(input[k]??null)!==(prior[k]??null))||json(input.expectedCases)!==json(prior.expectedCases))return fallback();
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
    const dirty=rows.filter(row=>globalChanged||json(row)!==json(before.get(String(row.key)))||[...members(row,index)].some(pid=>changed.has(pid)));
    replace=new Set(dirty.map(row=>String(row.key)));key=row=>String(row.panelKey);
    if(!dirty.length){reports[mode]=oldReport;counts.reusedRows+=oldReport.rows.length;continue;}
    fresh=data.build({...scoped(input,mode,dirty),failureMode:mode});
   }
   reports[mode]=merge(oldReport,fresh,key,replace);counts.evaluatedRows+=fresh.rows.length;counts.reusedRows+=oldReport.rows.filter(row=>!replace.has(key(row))).length;counts.modes[mode]=fresh.rows.length;
  }
  const result=input.failureMode==='minimum_rf'?minimum.build(input,reports):reports[input.failureMode];
  result.incremental=counts;data.rememberCriteria(result,reports);return data.bindContext(result,input);
 }
 return{build,changedProperties,members};
});
