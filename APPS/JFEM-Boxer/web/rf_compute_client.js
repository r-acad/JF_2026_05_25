(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFCompute=api;})(globalThis,function(root){
 'use strict';
 const sessionPrefix=typeof root.crypto?.randomUUID==='function'?root.crypto.randomUUID():Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);let clientSequence=0;
 function cancelBackend(request_id){if(!request_id||typeof root.fetch!=='function')return;try{Promise.resolve(root.fetch('/api/rf_assessment/cancel',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({request_id}),keepalive:true})).catch(()=>{});}catch(_){/* Worker cancellation still proceeds if the connection is unavailable. */}}
 const jsonReplacer=(_,value)=>value instanceof Map?Object.fromEntries(value):ArrayBuffer.isView(value)&&!(value instanceof DataView)?Array.from(value):value;
 function wire(context){
  if(!context)return null;
  const entries=value=>value instanceof Map?[...value]:Array.isArray(value)?value.map((row,i)=>[row.id??i+1,row]):Object.entries(value||{});
  const record=r=>{const out={};for(const k of ['analysis','analysis_type','solution','available','status','matches','historical','source','signature','meshIdentity','loadScale','convergence','validationIssues','elementResults','element_results','variantId','modeKind','caseLabel','label'])if(r[k]!==undefined)out[k]=r[k];if(r.static)out.static=true;if(r.variants)out.variants=new Map(entries(r.variants).map(([k,v])=>[k,record(v)]));return out;};
  return{...context,report:undefined,elements:new Map(entries(context.elements).map(([id,e])=>[id,{nodes:e.nodes,group:{name:e.group?.name,kind:e.group?.kind,pid:e.group?.pid,properties:e.group?.properties}}])),cases:new Map(entries(context.cases).map(([id,r])=>[id,record(r)]))};
 }
 function create(){
  let worker=null,sequence=0,pending=null;const clientId=++clientSequence;
  function cancel(){if(pending){cancelBackend(pending.request_id);pending.controller?.abort();const error=Error('A newer property edit superseded this assessment.');error.name='AbortError';pending.reject(error);pending=null;}worker?.terminate();worker=null;}
  function withoutWorker(id,request_id,input,previous,prior,options={}){
   return new Promise((resolve,reject)=>{
    const controller=typeof root.AbortController==='function'?new root.AbortController():null;pending={id,request_id,reject,controller};const active=()=>pending?.id===id;
    const compatibility=()=>{const report=root.WingRFIncremental.build(input,previous,prior);report.nativeBackend=false;report.browserCompatibility=true;report.note='Browser compatibility assessment: native RF service is unavailable in this static or older viewer. '+(report.note||'');return report;};
    (async()=>{
     if(typeof root.fetch!=='function')return compatibility();
     const view=root.WingRFNativeReportView;if(!view)throw Error('Native RF report support is unavailable. Refresh the app to load the current report module.');
     const previousReports=previous?root.WingStressReportData.criteria(previous):null,plan=view.planner(input,previous,prior,previousReports);
     options.onProgress?.(view.planProgress?.(plan)||{phase:'assessment',message:'Evaluating reserve factors…'});
     if(plan.reuse)return root.WingStressReportData.bindContext(previous,input);
     const sent=wire(view.scopedInput?.(input,plan)||input);if(plan.incremental){sent.response_ids=plan.response_ids;sent.restrict_responses=true;}
     const response=await root.fetch('/api/rf_assessment',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:sent,request_id},jsonReplacer),...(controller?{signal:controller.signal}:{})});
     if(response.status===404)return compatibility();
     let packet;try{packet=await response.json();}catch(_){throw Error('The native RF service returned an unreadable response.');}
     if(!response.ok||packet.ok===false)throw Error(packet.error||packet.message||'Native RF assessment failed.');
     if(!active())return null;const result=view.build(input,packet,{previousReports,replaceScopes:plan.replaceScopes,changedPropertyIds:plan.changedPropertyIds});root.WingStressReportData.rememberCriteria(result.report,result.criteria);return root.WingStressReportData.bindContext(result.report,input);
    })().then(report=>{if(!active())return;pending=null;resolve(report);},error=>{if(!active())return;cancelBackend(request_id);pending=null;reject(error);});
   });
  }
  function evaluateRaw(input,previous,prior,options={}){
   cancel();const id=++sequence,request_id='rf-view-'+sessionPrefix+'-'+clientId+'-'+id;
   if(typeof root.Worker!=='function')return withoutWorker(id,request_id,input,previous,prior,options);
   const ownedWorker=new root.Worker('rf_compute_worker.js');worker=ownedWorker;
   return new Promise((resolve,reject)=>{
    pending={id,request_id,reject};
    const active=()=>worker===ownedWorker&&pending?.id===id;
    ownedWorker.onmessage=event=>{
     // terminate() cannot retract an event already queued on the main thread.
     // A cancelled worker must never consume a newer worker's pending request.
     if(event.data.id!==id||!active())return;
     if(event.data.progress){options.onProgress?.(event.data.progress);return;}
     pending=null;
     if(event.data.error){cancelBackend(request_id);ownedWorker.terminate();if(worker===ownedWorker)worker=null;reject(Error(event.data.error));return;}
     try{const report=event.data.report;root.WingStressReportData.rememberCriteria(report,event.data.criteria);resolve(root.WingStressReportData.bindContext(report,input));}catch(error){reject(error);}
    };
    ownedWorker.onerror=event=>{if(!active())return;cancelBackend(pending.request_id);pending=null;ownedWorker.terminate();if(worker===ownedWorker)worker=null;reject(Error(event.message||'RF worker failed'));};
    try{const criteria=previous?root.WingStressReportData.criteria(previous):null,view=root.WingRFNativeReportView,
      plan=view?.planner(input,previous,prior,criteria),scoped=plan?.incremental&&view.scopedInput;
      ownedWorker.postMessage({id,request_id,input:wire(scoped?view.scopedInput(input,plan,{recoveryOnly:true}):input),previous,
        prior:wire(scoped?view.scopedInput(prior,plan,{recoveryOnly:true}):prior),criteria});}
    catch(error){if(active())pending=null;ownedWorker.terminate();if(worker===ownedWorker)worker=null;reject(error);}
   });
  }
  function evaluate(input,previous,prior,options={}){
   const activity=root.WingActivity,owned=options.activity!==false&&!options.activityToken;
   const token=options.activityToken||(owned?activity?.begin('Calculating reserve factors',{category:'numerical',blocking:false,detail:'Evaluating current failure checks and recovering internal loads…'}):null);
   const onProgress=detail=>{if(token)activity?.update(token,{detail:detail?.message||'Evaluating reserve factors…'});options.onProgress?.(detail);};
   try{return Promise.resolve(evaluateRaw(input,previous,prior,{...options,onProgress})).finally(()=>{if(owned&&token)activity?.end(token);});}
   catch(error){if(owned&&token)activity?.end(token);throw error;}
  }
  return{evaluate,cancel,destroy:cancel};
 }
 return{create,wire,jsonReplacer};
});
