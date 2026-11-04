/* Assessment factors act on recovered LIMIT demands, never on solved loads.
 * Material strength and elastic buckling deliberately use separate factors. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAssessmentLoadPolicy=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n);
 const DEFAULTS=Object.freeze({strengthSafetyFactor:1.5,bucklingPolicyFactor:1});
 function read(input={}){
  const p=input.assessmentPolicy||{},strengthSafetyFactor=p.strengthSafetyFactor??input.strengthSafetyFactor??input['assessment.strength_safety_factor']??DEFAULTS.strengthSafetyFactor,
   bucklingPolicyFactor=p.bucklingPolicyFactor??input.bucklingPolicyFactor??input['assessment.buckling_policy_factor']??DEFAULTS.bucklingPolicyFactor;
  if(!finite(strengthSafetyFactor)||strengthSafetyFactor<=0)throw Error('The strength safety factor must be finite and greater than zero.');
  if(!finite(bucklingPolicyFactor)||bucklingPolicyFactor<=0)throw Error('The buckling policy factor must be finite and greater than zero.');
  return{strengthSafetyFactor,bucklingPolicyFactor};
 }
 const stamp=input=>JSON.stringify(read(input));
 const divide=(value,factor)=>finite(value)?value/factor:null;
 function note(input={},kind='combined',nonlinear=false){
  nonlinear=nonlinear||input.nonlinear===true||input.nonlinearDemandEstimate===true||/(?:^|\b)(?:SOL\s*)?106(?:\b|_)/i.test(String(input.solution??input.analysis??''));
  const p=read(input),parts=['Recovered aerodynamic and inertia case demands are the LIMIT basis; any explicit case multiplier is already included once.'];
  if(kind!=='buckling')parts.push('ULTIMATE strength demand = LIMIT demand × '+p.strengthSafetyFactor+'. Strength RF = allowable / ULTIMATE stress or strain demand.');
  if(kind!=='strength')parts.push('Buckling assessment demand = LIMIT demand × '+p.bucklingPolicyFactor+'. Buckling RF = elastic critical load / buckling assessment demand; the strength safety factor does not enter buckling.');
  if(nonlinear)parts.push('SOL106: factors act proportionally on the recovered full-load LIMIT demands. These are engineering demand estimates, not a separately equilibrated nonlinear ULTIMATE state or a nonlinear buckling/failure load prediction.');
  for(const warning of input.assessmentPolicyWarnings||[])if(typeof warning==='string'&&warning)parts.push(warning);
  return parts.join(' ');
 }
 function sample(value,input={}){
  if(!value||value.reason)return value;
  const p=read(input),factor=p.strengthSafetyFactor,utilization=value.utilization*factor;
  if(!finite(utilization))return{reason:'Factored strength demand / allowable exceeds the numeric range.'};
  return{...value,limit_demand:value.demand,ultimate_demand:value.demand*factor,limit_utilization:value.utilization,
   utilization,reserve_factor:utilization>0?1/utilization:null,margin:utilization>0?1/utilization-1:null,
   assessment_factor:factor,assessment_basis:'ULTIMATE = strength safety factor × LIMIT',load_basis:'LIMIT'};
 }
 function annotate(report,input={},kind='combined'){
  const assessmentPolicy=read(input),nonlinear=(report.includedCases||[]).some(c=>Number(c.solution)===106),assessmentNote=note(input,kind,nonlinear),factor=kind==='strength'?assessmentPolicy.strengthSafetyFactor:kind==='buckling'?assessmentPolicy.bucklingPolicyFactor:null;
  return{...report,assessmentPolicy,loadBasis:'LIMIT',assessmentFactor:factor,assessmentNote,
   nonlinearDemandEstimate:nonlinear,note:(report.note?report.note+' ':'')+assessmentNote,
   rows:(report.rows||[]).map(row=>({...row,assessmentPolicy,loadBasis:'LIMIT',assessmentFactor:factor,assessmentNote,
    nonlinearDemandEstimate:nonlinear&&(row.caseResults||[]).some(c=>Number(c.solution)===106)}))};
 }
 return{DEFAULTS,read,stamp,divide,note,sample,annotate};
});
