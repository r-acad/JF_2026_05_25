/* Presentation adapter for authoritative native RF values. No strength, Euler,
 * plate eigenvalue or blade-capacity calculation occurs in this module. */
(function(root,factory){const common=typeof module==='object'&&module.exports;
 const api=factory(common?require('./assessment_load_policy.js'):root.WingAssessmentLoadPolicy,
 common?require('./stress_report_data.js'):root.WingStressReportData,
 common?require('./minimum_rf_data.js'):root.WingMinimumRFData,
 common?require('./euler_column_data.js'):root.WingEulerColumnData,
 common?require('./stringer_blade_data.js'):root.WingStringerBladeData,
 common?require('./skin_buckling_data.js'):root.WingSkinBucklingData,
 common?require('./component_buckling_data.js'):root.WingComponentBucklingData,
 common?require('./rf_incremental.js'):root.WingRFIncremental);
 if(common)module.exports=api;else root.WingRFNativeReportView=api;
})(globalThis,function(policy,data,minimum,euler,blade,skin,component,incremental){
 'use strict';
 const finite=v=>typeof v==='number'&&Number.isFinite(v),entries=v=>v instanceof Map?[...v]:Array.isArray(v)?v.map((x,i)=>[x.id??i+1,x]):Object.entries(v||{});
 const canonical=v=>v instanceof Map?canonical(Object.fromEntries(v)):Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
 const json=v=>JSON.stringify(canonical(v));
 const modes=['von_mises','principal_strain','euler_column','stringer_blade','skin_buckling',...Object.keys(component.MODES)];
 const collections={euler_column:'eulerColumns',stringer_blade:'stringerBlades',skin_buckling:'skinBucklingPanels'};
 const scope=(mode,key)=>['von_mises','principal_strain'].includes(mode)?'material:P'+key:mode+':'+key;
 const materialRegionScope=raw=>'material_region:'+raw.key+':P'+Number(raw.pid);
 const materialRegions=input=>Array.isArray(input?.materialRegions)?input.materialRegions:[];
 const rowScope=(mode,row)=>mode==='material_regions'?row.nativePhysicalScope:scope(mode,['von_mises','principal_strain'].includes(mode)?row.pid:row.panelKey);
 function metadata(input,mode){const d=component.MODES[mode];return d?(input.componentBuckling?.[d.collection]||[]).filter(r=>r.kind===d.kind):(input[collections[mode]]||[]);}
 function changedProperties(input,prior){
  const a=incremental.propertyDefinitions(input),b=incremental.propertyDefinitions(prior),changed=new Set([...a].filter(([pid,defs])=>defs.length!==b.get(pid)?.length||defs.some(value=>!b.get(pid).some(old=>incremental.equivalent(value,old)))).map(([pid])=>pid));
  if(json(input.allowables)!==json(prior?.allowables))for(const pid of a.keys())changed.add(pid);
  return changed;
 }
 const materials=properties=>[...new Set(properties.flatMap(p=>p?.type==='PCOMP'?(p.plies||[]).map(x=>Number(x.material_id??x.material?.id)):[...(p?.material_ids||[]),Number(p?.material_id??p?.material?.id)]).filter(x=>Number.isSafeInteger(x)&&x>0))];
 function planner(input,previous,prior,criteria){
  const full={incremental:false,replaceScopes:null,response_ids:null};
  if(!previous?.nativeBackend||!prior||!input.estimated||input.meshIdentity!==prior.meshIdentity||input.studyEpoch!==prior.studyEpoch||input.failureMode!==prior.failureMode||['caseId','method','percentile'].some(k=>(input[k]??null)!==(prior[k]??null))||json(input.expectedCases)!==json(prior.expectedCases)||json(input.assessmentPolicy)!==json(prior.assessmentPolicy)||json(input.assessmentPolicyWarnings)!==json(prior.assessmentPolicyWarnings))return full;
  const oldReports=input.failureMode==='minimum_rf'?criteria:{[input.failureMode]:previous};if(!oldReports)return full;
  const regional=materialRegions(input),oldRegional=materialRegions(prior),oldRegions=new Map(oldRegional.map(raw=>[materialRegionScope(raw),raw]));
  if(regional.length!==oldRegional.length||regional.some(raw=>!oldRegions.has(materialRegionScope(raw))||!incremental.equivalent(raw,oldRegions.get(materialRegionScope(raw)))))return full;
  if(regional.length&&!oldReports.material_regions){
   if(!criteria?.material_regions)return full;
   oldReports.material_regions=criteria.material_regions;
  }
  const changed=changedProperties(input,prior),index=new Map(entries(input.elements).map(([id,e])=>[Number(id),Number(e.group?.pid)]));
  const selected=new Set();
  for(const mode of Object.keys(oldReports)){
   if(mode==='material_regions'){for(const raw of regional)if(changed.has(Number(raw.pid)))selected.add(materialRegionScope(raw));continue;}
   if(['von_mises','principal_strain'].includes(mode)){for(const pid of changed)selected.add(scope(mode,pid));continue;}
   const rows=metadata(input,mode),old=metadata(prior,mode),before=new Map(old.map(r=>[String(r.key),r]));
   if(rows.length!==old.length||rows.some(r=>!before.has(String(r.key))))return full;
   const globalChanged=mode==='euler_column'?input.eulerFixityCoefficient!==prior.eulerFixityCoefficient:mode==='skin_buckling'?input.skinFixityCoefficient!==prior.skinFixityCoefficient:input.componentFixities?.[mode]!==prior.componentFixities?.[mode];
   for(const row of rows)if(globalChanged||!incremental.equivalent(row,before.get(String(row.key)))||[...incremental.members(row,index)].some(pid=>changed.has(pid)))selected.add(scope(mode,row.key));
  }
  const cases=data.caseList(input),response_ids=[...selected].flatMap(s=>cases.included.map(c=>s+':'+c.caseKey)),allScopes=new Set(Object.entries(oldReports).flatMap(([mode,r])=>(r.rows||[]).map(row=>rowScope(mode,row))));
  return{incremental:true,replaceScopes:[...selected],response_ids,reuse:!selected.size,changedPropertyIds:[...changed].filter(Number.isFinite).sort((a,b)=>a-b),counts:{affectedCriteria:selected.size,cachedCriteria:[...allScopes].filter(s=>!selected.has(s)).length,caseResponses:response_ids.length}};
 }
 // Keep the complete model client-side for the final envelope. Transport only
 // recovery needed by dirty criteria; a shared column includes its complete
 // skin and bar membership, never just the clicked element or property.
 function scopedInput(input,plan,{recoveryOnly=false}={}){
  if(!plan?.incremental)return input;
  const selected=new Set(plan.replaceScopes),index=minimum.modelIndex(input),needed=new Set();
  for(const[pid,region]of index.properties)if(selected.has(scope('von_mises',pid)))for(const eid of region.elements)needed.add(eid);
  const selectedRegions=materialRegions(input).filter(raw=>selected.has(materialRegionScope(raw)));
  for(const raw of selectedRegions)for(const eid of raw.member_element_ids||[])needed.add(Number(eid));
  const collectionsOut={},components={...(input.componentBuckling||{})};
  for(const mode of modes.filter(m=>!['von_mises','principal_strain'].includes(m))){
   const rows=metadata(input,mode).filter(raw=>selected.has(scope(mode,raw.key)));
   for(const raw of rows)for(const eid of minimum.membership(raw,mode,index).elementIds)needed.add(eid);
   const spec=component.MODES[mode];if(spec)components[spec.collection]=(components[spec.collection]||[]).filter(raw=>raw.kind!==spec.kind).concat(rows);else collectionsOut[collections[mode]]=rows;
  }
  const filteredRecords=records=>records instanceof Map?new Map([...records].filter(([eid])=>needed.has(Number(eid)))):records&&typeof records==='object'?Object.fromEntries(Object.entries(records).filter(([eid])=>needed.has(Number(eid)))):records;
  const caseRecord=record=>{const out={...record};for(const key of['elementResults','element_results'])if(out[key])out[key]=filteredRecords(out[key]);if(record?.variants)out.variants=new Map(entries(record.variants).map(([key,r])=>[key,caseRecord(r)]));return out;};
  const result={...input,cases:new Map(entries(input.cases).map(([key,r])=>[key,caseRecord(r)])),transportScope:{elementRecords:needed.size,modelElements:index.elements.size,physicalCriteria:selected.size}};
  if(!recoveryOnly)Object.assign(result,collectionsOut,{materialRegions:selectedRegions,componentBuckling:components,elements:new Map(entries(input.elements).filter(([eid])=>needed.has(Number(eid)))),panels:[],componentGroups:[],response_ids:plan.response_ids,restrict_responses:true});
  return result;
 }
 function planProgress(plan){return plan?.incremental?{phase:'assessment',...plan.counts,message:'Updating '+plan.counts.affectedCriteria+' affected physical criteria across '+plan.counts.caseResponses+' load-case responses; reusing '+plan.counts.cachedCriteria+' unchanged criteria…'}:{phase:'assessment',message:'Evaluating reserve factors for this assessment…'};}
 function build(input,packet,{previousReports=null,replaceScopes=null,changedPropertyIds=[]}={}){
  const native=packet.assessment||packet,cases=data.caseList(input),index=minimum.modelIndex(input),groups=new Map();
  for(const row of native.responses||[]){const key=row.physical_criterion_id;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);}
  const selected=replaceScopes?new Set(replaceScopes):null,needed=input.failureMode==='minimum_rf'?modes:[input.failureMode||'von_mises'];
  const caseInfo=new Map(cases.included.map(c=>[c.caseKey,c]));
  const nativeCase=(rows,item)=>rows.find(r=>String(r.case_key??(String(r.case_id)+':default'))===item.caseKey);
  const good=r=>r?.status==='ok';
  function common(mode,key,raw,total,pids,eids,label,physicalOverride=null){
   const physical=physicalOverride||scope(mode,key),values=(groups.get(physical)||[]).filter(r=>r.failure_mode===mode),plate=mode==='skin_buckling'||component.MODES[mode]?.type==='plate',column=mode==='euler_column'||component.MODES[mode]?.type==='column',freeWeb=mode==='stringer_blade'||component.MODES[mode]?.type==='blade';
   const caseResults=cases.included.map(item=>{
    const r=nativeCase(values,item),valid=good(r),details=r?.details||{},stats=r?.stress_statistics||{},base={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total,recovered:valid?total:0,reserveFactor:valid?(r.no_demand?99:r.raw_RF):null,reason:valid?'':r?.reason||raw?.reason||'Native assessment is unavailable.',nativeAssessment:true};
    if(mode==='von_mises')return{...base,recovered:stats.recovered??base.recovered,maximum:stats.maximum??null,envelope:stats.envelope??null,cutoff:stats.cutoff??null,retained:stats.retained??0,discarded:stats.discarded??0,maxEid:stats.maxEid??null,maxFace:stats.maxFace??null,recoveryMethods:r?.recovery_methods||[],reasons:valid?[]:[{reason:base.reason,count:total}]};
    if(mode==='principal_strain')return{...base,utilization:valid?r.utilization:null,peak:r?.principal_strain||null};
    if(column)return{...base,stations:details.stations||[],governingStation:details.governingStation??null};
    if(freeWeb)return{...base,averageStress:details.averageStress??null,compressionDemand:details.compressionDemand??null,assessmentCompressionDemand:finite(details.compressionDemand)?details.compressionDemand*policy.read(input).bucklingPolicyFactor:null,criticalStress:details.criticalStress??null,criticalEid:details.criticalEid??null};
    return{...base,...details,recovered:valid||r?.membrane_recovery_complete===true?total:0,membraneRecoveryComplete:r?.membrane_recovery_complete===true,lowerBound:r?.lower_bound_RF??null,certifiedNonGoverning:false,boundReason:'',noDestabilizingLoad:valid&&r.no_demand,converged:valid&&r.converged===true,approximation:valid&&r.approximation===true,selectedModes:r?.selected_modes||[],basisSize:r?.basis_size??details.basisSize??null,basisM:details.basisM??null,basisN:details.basisN??null,sourceBasisSize:r?.source_basis_size??null,sourceBasisM:r?.source_basis_m??null,sourceBasisN:r?.source_basis_n??null,basisStage:r?.basis_stage??null,targetTolerance:r?.target_tolerance??null,modeLimit:r?.mode_limit??null,convergenceError:r?.convergence_error??null,history:r?.basis_history||[],method:r?.method||'',gradientClass:r?.gradient_class||'',clusterSize:r?.cluster_size??1};
   });
   if(plate){
    const proven=caseResults.filter(c=>c.converged&&!c.noDestabilizingLoad&&finite(c.reserveFactor)&&c.reserveFactor>0).reduce((a,b)=>!a||b.reserveFactor<a.reserveFactor?b:a,null);
    if(proven)for(const c of caseResults)if(!c.converged&&!c.approximation&&c.membraneRecoveryComplete&&c.recovered===c.total&&finite(c.lowerBound)&&c.lowerBound>proven.reserveFactor*(1+1e-8)){
     c.certifiedNonGoverning=true;c.boundReason='Every positive buckling multiplier of this equivalent plate is at least '+c.lowerBound.toPrecision(5)+' by the conservative bending/principal-membrane-load and rectangular Poincare bound, above the converged governing RF '+proven.reserveFactor.toPrecision(5)+'. The case eigenvalue remains unresolved.';
    }
   }
   const valid=values.filter(good),demand=valid.filter(r=>!r.no_demand&&finite(r.raw_RF)),governing=demand.reduce((a,b)=>!a||b.raw_RF<a.raw_RF?b:a,null),complete=cases.complete&&caseResults.length>0&&values.length===cases.included.length&&caseResults.every(c=>c.recovered===c.total&&(good(nativeCase(values,caseInfo.get(c.caseKey)))||c.certifiedNonGoverning)),noDemand=complete&&values.length>0&&values.every(r=>r.no_demand),chosen=governing||valid[0]||values[0],chosenCase=chosen?caseInfo.get(chosen.case_key??(String(chosen.case_id)+':default')):null;
   const reason=!complete?(values.filter(r=>!good(r)).map(r=>r.reason||'Native assessment unavailable.').join(' ')||caseResults.filter(c=>c.recovered!==c.total).map(c=>c.label+': '+c.reason).join(' ')||'The selected load-case set is incomplete.'):'',rf=complete?(noDemand?(mode==='von_mises'?null:99):governing?.raw_RF??null):null;
   const reportPrefix=mode==='euler_column'?'euler':mode==='stringer_blade'?'blade':mode==='skin_buckling'?'skin':mode;
   const props=pids.flatMap(pid=>index.properties.get(pid)?.properties||[]),row={pid:pids[0]??Number(raw?.pid),propertyIds:pids,rowKey:['von_mises','principal_strain'].includes(mode)?mode+':P'+key:reportPrefix+':'+key,panelKey:['von_mises','principal_strain'].includes(mode)?undefined:String(key),label,names:['von_mises','principal_strain'].includes(mode)?[...(index.properties.get(Number(key))?.names||[])]:[minimum.MODES[mode]||mode],propertyType:['von_mises','principal_strain'].includes(mode)?[...new Set(props.map(p=>p?.type||'Unknown'))].join(' / '):plate?'Physical plate':column?'Physical column':'Free web',materialIds:materials(props),elementCount:eids.length,reserveFactor:rf,reserveFactorReason:reason||(mode==='von_mises'&&noDemand?'Zero stress has no finite reserve factor.':''),complete,status:complete?'complete':valid.length?'partial':'unavailable',coverage:{recovered:caseResults.reduce((n,c)=>n+c.recovered,0),total:total*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length)},caseResults,reasons:caseResults.filter(c=>c.recovered!==c.total).map(c=>({reason:c.reason,count:c.total-c.recovered,caseLabel:c.label})),envelopeCaseLabel:noDemand?'':chosenCase?.label||'',envelopeCaseKey:noDemand?'':chosenCase?.caseKey||'',maxStress:null,envelopeStress:null,allowableStress:null,approximation:values.some(r=>r.approximation),governingApproximation:governing?.approximation===true,nativePhysicalScope:physical};
   if(mode==='von_mises'){
    const peak=caseResults.filter(c=>finite(c.maximum)).reduce((a,b)=>!a||b.maximum>a.maximum?b:a,null),envelope=caseResults.filter(c=>finite(c.envelope)).reduce((a,b)=>!a||b.envelope>a.envelope?b:a,null),allowable=chosen?.stress_statistics?.allowable??null;
    Object.assign(row,{maxStress:peak?.maximum??null,maxCaseLabel:peak?.label||'',maxCaseKey:peak?.caseKey||'',maxEid:peak?.maxEid??null,maxFace:peak?.maxFace??null,envelopeStress:envelope?.envelope??null,envelopeCaseLabel:envelope?.label||'',envelopeCaseKey:envelope?.caseKey||'',envelopeEid:(input.method||'maximum')==='maximum'?envelope?.maxEid??null:null,assessmentStress:finite(envelope?.envelope)?envelope.envelope*policy.read(input).strengthSafetyFactor:null,allowableStress:allowable,recoveryMethods:caseResults.flatMap(c=>c.recoveryMethods.map(m=>({...m,caseLabel:c.label})))});
   }else if(mode==='principal_strain'){row.principalStrain=chosen?.principal_strain||null;row.noDemand=noDemand;}
   else if(column){row.euler={...(chosen?.details||{}),noCompression:noDemand,governingCase:chosenCase?.label||'',note:noDemand?'RF99 is a no-compression display sentinel, not a finite failure multiplier.':''};}
   else if(freeWeb){row.blade={...(chosen?.details||{}),noCompression:noDemand,governingCase:chosenCase?.label||''};row.envelopeStress=row.blade.compressionDemand??null;row.allowableStress=row.blade.criticalStress??null;row.maxStress=Math.max(0,...caseResults.map(c=>-(c.averageStress??0)));}
   else row.skinBuckling={...(chosen?.details||{}),noDestabilizingLoad:noDemand,governingCase:chosenCase?.label||'',criticalFactor:noDemand?null:rf,approximation:chosen?.approximation===true,basisSize:chosen?.basis_size??null,history:chosen?.basis_history||[]};
   return row;
  }
  function modeRows(mode){
   const rows=[];
   if(['von_mises','principal_strain'].includes(mode)){
    for(const[pid,region]of[...index.properties].sort((a,b)=>a[0]-b[0])){
     if(selected&&!selected.has(scope(mode,pid)))continue;
     if(mode==='principal_strain'&&!region.properties.some(p=>p?.type==='PCOMP'))continue;
     rows.push(common(mode,pid,null,region.elements.length,[pid],region.elements,'P'+pid));
    }
    return rows;
   }
   for(const raw of metadata(input,mode)){
    if(selected&&!selected.has(scope(mode,raw.key)))continue;
    const members=minimum.membership(raw,mode,index),type=component.MODES[mode]?.type;
    const total=mode==='euler_column'||type==='column'?Math.max(1,raw.stations?.length||0):mode==='stringer_blade'||type==='blade'?Math.max(1,raw.bars?.length||0):Math.max(1,raw.elements?.length||0);
    let label=raw.label||raw.key;
    if(mode==='euler_column'&&!raw.label)label='P'+raw.panel_id+' · '+(raw.skin==='upper'?'Upper':'Lower')+' stringer '+raw.stringer+' · R'+raw.rib_bay+'–R'+(Number(raw.rib_bay)+1);
    if(mode==='skin_buckling')label=(raw.skin==='upper'?'Upper':'Lower')+' · R'+raw.rib_bay+'–R'+(Number(raw.rib_bay)+1)+' · '+(raw.label||raw.key)+(Number(raw.segment)>1?' · segment '+raw.segment:'');
    const row=common(mode,raw.key,raw,total,members.propertyIds,members.elementIds,label);
    row.locations=component.MODES[mode]?raw.locations||[]:mode==='euler_column'?euler.columnLocations(raw):mode==='stringer_blade'?blade.bladeLocations(raw):skin.panelLocations(raw);
    if(component.MODES[mode])row.componentBuckling={kind:component.MODES[mode].kind,method:type,scope:label,note:type==='plate'?component.WEB_NOTE:type==='column'?component.COLUMN_NOTE:blade.NOTE,fieldMethod:type==='plate'?'Spatial piecewise membrane field':type==='column'?'Isolated-member section cuts':'Mean signed bar axial stress'};
    rows.push(row);
   }
   return rows;
  }
  const reports={};let evaluatedRows=0,reusedRows=0;
  for(const mode of needed){
   const fresh=modeRows(mode),old=previousReports?.[mode];let rows=fresh;
   if(selected&&old){const keep=(old.rows||[]).filter(r=>!selected.has(scope(mode,['von_mises','principal_strain'].includes(mode)?r.pid:r.panelKey)));rows=keep.concat(fresh);reusedRows+=keep.length;}
   evaluatedRows+=fresh.length;rows.sort((a,b)=>(Number(a.pid)||0)-(Number(b.pid)||0)||String(a.panelKey||a.rowKey).localeCompare(String(b.panelKey||b.rowKey)));
   const note='RF values are evaluated by the native JFEM assessment kernels; this view only groups cases and properties. '+(mode==='euler_column'?euler.NOTE:mode==='stringer_blade'?blade.NOTE:mode==='skin_buckling'?skin.NOTE:component.MODES[mode]?(component.MODES[mode].type==='plate'?component.WEB_NOTE:component.MODES[mode].type==='column'?component.COLUMN_NOTE:blade.NOTE):mode==='principal_strain'?'Principal tensile/compressive strain utilization over all actual laminate ply faces.':'One recovered peak per element; equal-element averaging or percentile trimming is performed within each case.');
   reports[mode]=minimum.decorate(policy.annotate({failureMode:mode,rows,includedCases:cases.included.map(({result,...c})=>c),excludedCases:cases.excluded.map(({result,...c})=>c),missingCases:cases.missing,method:input.method||'maximum',percentile:input.percentile??95,stressUnit:mode==='principal_strain'?'strain':input.sourceUnits?'source stress units':'MPa',stressFactor:mode==='principal_strain'||input.sourceUnits?1:1e-6,forceUnit:input.sourceUnits?'source force units':'N',forceFactor:1,lengthUnit:input.sourceUnits?'source length units':'m',complete:cases.complete&&rows.length>0&&rows.every(r=>r.complete),coverage:{recovered:rows.reduce((n,r)=>n+r.coverage.recovered,0),total:rows.reduce((n,r)=>n+r.coverage.total,0),properties:rows.length},note,excludedProperties:[]},input,['von_mises','principal_strain'].includes(mode)?'strength':'buckling'),input,index);
  }
  const freshRegions=[];
  for(const raw of materialRegions(input)){
   const physical=materialRegionScope(raw);if(selected&&!selected.has(physical))continue;
   const pid=Number(raw.pid),properties=index.properties.get(pid)?.properties||[],mode=properties.some(p=>p?.type==='PCOMP')?'principal_strain':'von_mises';
   if(input.failureMode!=='minimum_rf'&&input.failureMode!==mode)continue;
   const ids=Array.from(raw.member_element_ids||[]).map(Number),row=common(mode,pid,raw,ids.length,[pid],ids,raw.label||raw.key,physical);
   Object.assign(row,{rowKey:physical,panelKey:String(raw.key),materialRegionKey:String(raw.key),memberElementIds:ids,
    failureMode:mode,nativeMaterialRegion:true,memberKind:raw.member_kind||'component'});
   const values=(groups.get(physical)||[]).filter(r=>r.failure_mode===mode);
   row.noDemand=row.complete&&values.length===cases.included.length&&values.length>0&&values.every(r=>r.no_demand);
   if(row.noDemand){row.reserveFactor=99;row.reserveFactorReason='';}
   freshRegions.push(row);
  }
  const previousRegions=previousReports?.material_regions?.rows||[],keptRegions=selected?previousRegions.filter(row=>!selected.has(row.nativePhysicalScope)):[];
  if(materialRegions(input).length||previousRegions.length){
   const rows=keptRegions.concat(freshRegions);reports.material_regions={failureMode:'material_regions',rows,
    complete:cases.complete&&rows.length>0&&rows.every(row=>row.complete),includedCases:cases.included.map(({result,...c})=>c)};
   evaluatedRows+=freshRegions.length;reusedRows+=keptRegions.length;
  }
  const report=input.failureMode==='minimum_rf'?policy.annotate(minimum.build(input,reports),input):reports[input.failureMode||'von_mises'];
  report.materialRegions=reports.material_regions?.rows||[];
  report.nativeBackend=true;report.nativeRFVersion=packet.format||'jfem-native-rf-report-1';report.nativePostprocessingSeconds=packet.seconds??null;
  if(selected)report.incremental={properties:changedPropertyIds,evaluatedRows,reusedRows,modes:Object.fromEntries(Object.entries(reports).map(([mode,r])=>[mode,r.rows.length]))};
  data.rememberCriteria(report,reports);return{report,criteria:reports};
 }
 return{build,planner,metadata,scopedInput,planProgress};
});
