(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFCompute=api;})(globalThis,function(root){
 'use strict';
 function wire(context){
  if(!context)return null;
  const entries=value=>value instanceof Map?[...value]:Object.entries(value||{});
  const record=r=>{const out={};for(const k of ['analysis','analysis_type','solution','available','status','matches','historical','source','signature','meshIdentity','loadScale','convergence','validationIssues','elementResults','element_results','variantId','modeKind'])if(r[k]!==undefined)out[k]=r[k];if(r.static)out.static={};if(r.variants)out.variants=new Map([...r.variants].map(([k,v])=>[k,record(v)]));return out;};
  return{...context,report:undefined,elements:new Map(entries(context.elements).map(([id,e])=>[id,{nodes:e.nodes,group:{name:e.group?.name,kind:e.group?.kind,pid:e.group?.pid,properties:e.group?.properties}}])),cases:new Map(entries(context.cases).map(([id,r])=>[id,record(r)]))};
 }
 function create(){
  let worker=null,sequence=0,pending=null;
  function cancel(){if(pending){const error=Error('A newer property edit superseded this assessment.');error.name='AbortError';pending.reject(error);pending=null;}worker?.terminate();worker=null;}
  function evaluate(input,previous,prior){
   if(typeof root.Worker!=='function')return Promise.resolve(root.WingRFIncremental.build(input,previous,prior));
   cancel();worker=new root.Worker('rf_compute_worker.js');const id=++sequence;
   return new Promise((resolve,reject)=>{
    pending={reject};worker.onmessage=event=>{if(event.data.id!==id||!pending)return;pending=null;if(event.data.error){reject(Error(event.data.error));return;}const report=event.data.report;root.WingStressReportData.rememberCriteria(report,event.data.criteria);resolve(root.WingStressReportData.bindContext(report,input));};worker.onerror=event=>{pending=null;reject(Error(event.message||'RF worker failed'));};
    worker.postMessage({id,input:wire(input),previous,prior:wire(prior),criteria:previous?root.WingStressReportData.criteria(previous):null});
   });
  }
  return{evaluate,cancel,destroy:cancel};
 }
 return{create,wire};
});
