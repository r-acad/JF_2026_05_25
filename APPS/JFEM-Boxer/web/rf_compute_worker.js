/* Numerical sizing work stays off the viewport/UI thread. */
importScripts('color_scales.js','material_allowables.js','euler_column_data.js','stringer_blade_data.js','skin_buckling_data.js','component_buckling_data.js','minimum_rf_data.js','stress_report_data.js','reserve_factor_table_data.js','rf_incremental.js');
self.onmessage=event=>{
 const{id,input,previous,prior,criteria}=event.data;
 try{
  if(previous&&criteria)WingStressReportData.rememberCriteria(previous,criteria);
  const report=WingRFIncremental.build(input,previous,prior);
  self.postMessage({id,report,criteria:WingStressReportData.criteria(report)});
 }catch(error){self.postMessage({id,error:error?.message||String(error)});}
};
