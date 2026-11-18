/* Numerical sizing work stays off the viewport/UI thread. */
importScripts('assessment_load_policy.js','color_scales.js','material_allowables.js','euler_column_data.js','stringer_blade_data.js','skin_buckling_data.js','component_buckling_data.js','minimum_rf_data.js','stress_report_data.js','reserve_factor_table_data.js','rf_incremental.js','rf_native_report_view.js');
self.onmessage=async event=>{
 const{id,input,previous,prior,criteria}=event.data;
 try{
  if(previous&&criteria)WingStressReportData.rememberCriteria(previous,criteria);
  const compatible=()=>{const report=WingRFIncremental.build(input,previous,prior);report.nativeBackend=false;report.browserCompatibility=true;report.note='Browser compatibility assessment: native RF service is unavailable in this static or older viewer. '+report.note;return{report,criteria:WingStressReportData.criteria(report)};};
  if(typeof self.fetch!=='function'){self.postMessage({id,...compatible()});return;}
  const plan=WingRFNativeReportView.planner(input,previous,prior,criteria);
  self.postMessage({id,progress:WingRFNativeReportView.planProgress(plan)});
  if(plan.reuse){self.postMessage({id,report:previous,criteria});return;}
  const request_id=event.data.request_id||'rf-view-'+Date.now()+'-'+id;
  const requestInput=WingRFNativeReportView.scopedInput(input,plan);
  const response=await self.fetch('/api/rf_assessment',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:requestInput,request_id},(_,value)=>value instanceof Map?Object.fromEntries(value):ArrayBuffer.isView(value)?Array.from(value):value)});
  // A standalone static/older viewer has no Julia endpoint. Keep this explicit
  // compatibility mode; failures from the current native service never fall
  // back to a second numerical implementation.
  if(response.status===404){self.postMessage({id,...compatible()});return;}
  const packet=await response.json();
  if(!response.ok||packet.ok===false)throw Error(packet.error||packet.message||'Native RF assessment failed.');
  const result=WingRFNativeReportView.build(input,packet,{previousReports:criteria,replaceScopes:plan.replaceScopes,changedPropertyIds:plan.changedPropertyIds});
  self.postMessage({id,...result});
 }catch(error){self.postMessage({id,error:error?.message||String(error)});}
};
