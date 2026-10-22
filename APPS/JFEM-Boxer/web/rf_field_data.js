/* Project assessed reserve factors onto actual FE element IDs. Property checks
 * retain their whole-property scope; physical checks retain their exact members. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./stress_report_data.js'):root.WingStressReportData,typeof module==='object'&&module.exports?require('./minimum_rf_data.js'):root.WingMinimumRFData,typeof module==='object'&&module.exports?require('./reserve_factor_table_data.js'):root.WingReserveFactorTableData,typeof module==='object'&&module.exports?require('./component_buckling_data.js'):root.WingComponentBucklingData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFFieldData=api;})(globalThis,function(stress,minimum,tables,component){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n);
 const FAILURE_MODES=Object.freeze({...minimum.MODES});
 const FIELD_KINDS=Object.freeze({minimum_rf:'Minimum reserve factor',failure_rf:'Failure-mode reserve factor',critical_case:'Critical load case',critical_failure:'Critical failure mode'});
 const NO_DEMAND_KEY='no_demand',NO_DEMAND_COLOR=[.53,.67,.65];
 const propertyModes=new Set(['minimum_rf','von_mises','principal_strain']);
 const modes=Object.keys(FAILURE_MODES);
 const modeColors=['#0277bd','#ad1457','#00897b','#ef6c00','#6a1b9a','#3949ab','#8d6e00','#00838f','#c62828','#5d4037'];
 const NOTE='Colors apply to actual element membership. A property-wide stress or combined RF colors its whole property region; a physical plate, blade or column RF colors its recorded members, including shared constituents. Overlapping applicable checks use their lowest computed RF, and any incomplete overlapping check leaves those elements unassessed. RF 99 is a no-demand sentinel only when explicitly identified; it never outranks a calculated RF greater than 99. Critical-case and failure-mode categories require a complete minimum-RF assessment. Gray means unassessed or inapplicable, not zero. SOL106 RFs are demand ratios, not predicted failure-load multipliers.';
 function options(input={},request={}){
  const kind=request.kind??input.kind??'minimum_rf';if(!Object.hasOwn(FIELD_KINDS,kind))throw Error('Unknown reserve-factor field presentation: '+kind);
  const failureMode=kind==='failure_rf'?(request.failureMode??input.failureMode??'von_mises'):'minimum_rf';
  if(failureMode!=='minimum_rf'&&!Object.hasOwn(FAILURE_MODES,failureMode))throw Error('Unknown reserve-factor failure mode: '+failureMode);
  const palette=request.palette??input.palette??'signed';
  return{...request,kind,failureMode,palette:tables.PALETTES.some(([key])=>key===palette)?palette:'signed'};
 }
 function metadata(input,mode){
  const descriptor=component.MODES[mode];
  if(descriptor){const rows=input.componentBuckling?.[descriptor.collection??(descriptor.type==='plate'?'web_panels':descriptor.type==='column'?'columns':'blades')];return Array.isArray(rows)?rows.filter(row=>row.kind===descriptor.kind):[];}
  return mode==='euler_column'?input.eulerColumns||[]:mode==='stringer_blade'?input.stringerBlades||[]:mode==='skin_buckling'?input.skinBucklingPanels||[]:[];
 }
 function noDemand(row,mode){return mode==='minimum_rf'?row.combined?.sentinel===true:mode==='principal_strain'?row.noDemand===true:row.euler?.noCompression===true||row.blade?.noCompression===true||row.skinBuckling?.noDestabilizingLoad===true;}
 function rgb(css){
  if(/^#[0-9a-f]{6}$/i.test(css))return[1,3,5].map(i=>parseInt(css.slice(i,i+2),16)/255);
  const m=/^rgba?\(\s*([\d.]+)[, ]+\s*([\d.]+)[, ]+\s*([\d.]+)/.exec(css||'');return m?m.slice(1).map(v=>Number(v)/255):null;
 }
 function hsl(h,s,l){const a=s*Math.min(l,1-l),f=n=>{const k=(n+h/30)%12;return l-a*Math.max(-1,Math.min(k-3,9-k,1));};return[f(0),f(8),f(4)];}
 function categoryColor(key){
  if(key===NO_DEMAND_KEY)return NO_DEMAND_COLOR.slice();
  if(key.startsWith('mode:'))return rgb(modeColors[Math.max(0,modes.indexOf(key.slice(5)))%modeColors.length]);
  let hash=2166136261;for(let i=0;i<key.length;i++){hash^=key.charCodeAt(i);hash=Math.imul(hash,16777619);}
  return hsl((hash>>>0)%36000/100,.67,.43+((hash>>>16)%3)*.055);
 }
 function caseSignature(cases){return(cases||[]).map(c=>String(c.caseKey)+'|'+String(c.solution)).sort().join('\n');}
 function freshness(input,report){
  if(input.modelDirty||input.pendingDrafts)return 'The model definition has unsolved changes. Rerun the selected cases before displaying reserve factors.';
  if(input.running)return 'Analysis is running; completed current results are required.';
  if(input.cases!==undefined){
   if(report.assessmentContext&&report.assessmentContext!==stress.contextStamp(input))return 'Assessment options or the model changed. Rebuild the field for the current material limits, fixities and case selection.';
   const current=stress.caseList(input);
   if(!current.complete)return[...new Set([...current.excluded.filter(c=>c.relevant).map(c=>c.reason),...current.missing.map(c=>c.label+': '+c.reason),...(!current.included.length?['No eligible current SOL101/full-load SOL106 result is available.']:[])])].join(' ');
   if(caseSignature(current.included)!==caseSignature(report.includedCases))return 'The field report belongs to a different load-case selection. Rebuild the report for the current cases.';
  }
  return '';
 }
 function collectionMap(rows,key){const map=new Map();for(const row of rows){const k=String(key(row));if(!map.has(k))map.set(k,[]);map.get(k).push(row);}return map;}
 function sources(input,report,index){
  const mode=report.failureMode,out=[];
  if(propertyModes.has(mode)){
   const byPid=collectionMap(report.rows||[],row=>row.pid);
   for(const [pid,region]of index.properties){const rows=byPid.get(String(pid))||[];for(const row of rows)out.push({row,members:{elementIds:region.elements,propertyIds:[pid],complete:rows.length===1,reason:rows.length===1?'':'More than one report row claims the same property.'},scope:'Full property P'+pid});}
   return out;
  }
  const rawByKey=collectionMap(metadata(input,mode),row=>row.key),rowByKey=collectionMap(report.rows||[],row=>row.panelKey);
  for(const [key,raws]of rawByKey){
   const rows=rowByKey.get(key)||[];
   for(const raw of raws){
    if(raw.applicable===false||raw.status==='not_applicable')continue;
    const members=minimum.membership(raw,mode,index);
    if(raws.length!==1||rows.length!==1){members.complete=false;members.reason=raws.length>1||rows.length>1?'Duplicate physical-region identity; regenerate the mesh and report.':'No assessment row was returned for this applicable physical region.';}
    out.push({row:rows.length===1?rows[0]:null,members,scope:rows[0]?.label||raw.label||key,sourceKey:key});
   }
  }
  return out;
 }
 function detailFor(source,report,index){
  const row=source.row,mode=report.failureMode,members=source.members;
  if(!row)return{available:false,reason:members.reason,scope:source.scope,modeKey:mode,modeLabel:FAILURE_MODES[mode]||'Minimum reserve factor'};
  const checked=tables.reserveValue(row),valid=members.complete&&checked.value!==null,modeKey=mode==='minimum_rf'?row.combined?.governingMode||'':mode;
  const gauge=members.complete?minimum.gaugeFor(members.propertyIds,index):{known:false,atMinimum:false,reason:members.reason};
  return{available:valid,reason:!members.complete?members.reason:checked.reason||'',reserveFactor:valid?checked.value:null,rowKey:row.rowKey||mode+':P'+row.pid,propertyIds:members.propertyIds,memberElementIds:members.elementIds,
   modeKey,modeLabel:mode==='minimum_rf'?row.combined?.governingModeLabel||'':FAILURE_MODES[mode],caseKey:row.envelopeCaseKey||'',caseLabel:row.envelopeCaseLabel||'',scope:mode==='minimum_rf'?row.combined?.governingScope||source.scope:source.scope,
   propertyScope:propertyModes.has(mode)?'Full property P'+row.pid:'',noDemand:valid&&noDemand(row,mode),minimumGauge:gauge,coverage:row.coverage,status:valid?'complete':row.status||'unavailable',
   notes:[...(tables.caseCertificateNotes?.(row)||[]),...(row.caseResults||[]).flatMap(c=>(c.recoveryMethods||[]).map(m=>c.label+': '+(m.description||m.method))),...(row.combined?.assessments||[]).flatMap(a=>(a.recoveryMethods||[]).map(m=>m.description||m.method))],
   colorRecord:{complete:valid,coverage:row.coverage,reserveFactorReason:valid?'':members.reason||checked.reason,minimumGauge:gauge}};
 }
 function category(detail,report,kind){
  if(detail.noDemand)return{key:NO_DEMAND_KEY,label:'No demand in applicable checks',color:categoryColor(NO_DEMAND_KEY)};
  if(kind==='critical_failure'){
   if(!Object.hasOwn(FAILURE_MODES,detail.modeKey))return{reason:'The complete minimum RF has no identified governing failure mode.'};
   const key='mode:'+detail.modeKey;return{key,label:FAILURE_MODES[detail.modeKey],color:categoryColor(key)};
  }
  const cases=(report.includedCases||[]).filter(c=>String(c.caseKey)===String(detail.caseKey));
  if(!detail.caseKey||cases.length!==1||![101,106].includes(cases[0].solution))return{reason:'The governing case identity or solution provenance is unavailable; no load-case color is assigned.'};
  const c=cases[0],key='case:'+c.solution+':'+c.caseKey,label=String(c.label||detail.caseLabel||('Case '+c.caseId));
  return{key,label,caseKey:c.caseKey,caseId:c.caseId,solution:c.solution,color:categoryColor(key)};
 }
 function project(input={},report,request={}){
  const opt=options(input,request),index=minimum.modelIndex(input),categorical=opt.kind==='critical_case'||opt.kind==='critical_failure';
  if(!report||report.failureMode!==opt.failureMode)throw Error('The requested field requires a '+opt.failureMode+' report.');
  const title=opt.kind==='failure_rf'?(FAILURE_MODES[opt.failureMode]+' reserve factor'):FIELD_KINDS[opt.kind],byId=new Map(),colorById=new Map(),detailsById=new Map(),unavailableById=new Map(),buckets=new Map(),issues=[],stale=freshness(input,report);
  for(const eid of index.elements.keys())unavailableById.set(eid,stale||'No applicable complete assessment is associated with this element.');
  if(!stale)for(const source of sources(input,report,index)){
   const detail=detailFor(source,report,index);
   if(!source.members.complete)issues.push({scope:source.scope,reason:source.members.reason});
   for(const eid of source.members.elementIds){if(!index.elements.has(eid))continue;if(!buckets.has(eid))buckets.set(eid,[]);buckets.get(eid).push(detail);}
  }
  const categoryMap=new Map();let actualMin=null,actualMax=null;
  for(const [eid,candidates]of buckets){
   const missing=candidates.filter(c=>!c.available);
   if(missing.length){const reason=[...new Set(missing.map(c=>c.scope+': '+c.reason))].join(' ');unavailableById.set(eid,reason);detailsById.set(eid,{available:false,status:'unassessed',reason,assessments:candidates});continue;}
   const computed=candidates.filter(c=>!c.noDemand),eligible=computed.length?computed:candidates;
   const governing=eligible.reduce((best,c)=>!best||c.reserveFactor<best.reserveFactor||c.reserveFactor===best.reserveFactor&&String(c.rowKey)<String(best.rowKey)?c:best,null);
   const detail={...governing,assessments:candidates};delete detail.colorRecord;
   if(categorical){const item=category(governing,report,opt.kind);if(item.reason){detail.available=false;detail.reason=item.reason;unavailableById.set(eid,item.reason);detailsById.set(eid,detail);continue;}categoryMap.set(item.key,item);detail.categoryKey=item.key;colorById.set(eid,item.color);}
   else{byId.set(eid,governing.reserveFactor);colorById.set(eid,rgb(tables.valueColor(governing.reserveFactor,{min:0,max:2},opt.palette,governing.colorRecord)));}
   actualMin=actualMin===null?governing.reserveFactor:Math.min(actualMin,governing.reserveFactor);actualMax=actualMax===null?governing.reserveFactor:Math.max(actualMax,governing.reserveFactor);
   detailsById.set(eid,detail);unavailableById.delete(eid);
  }
  const categories=[...categoryMap.values()].sort((a,b)=>a.key.localeCompare(b.key));
  const labels=new Map();for(const item of categories)labels.set(item.label,(labels.get(item.label)||0)+1);
  categories.forEach((item,i)=>{item.value=i+1;if(labels.get(item.label)>1)item.label+=' ['+item.caseKey+']';});
  if(categorical){const ids=new Map(categories.map(c=>[c.key,c.value]));for(const [eid,detail]of detailsById)if(detail.available&&detail.categoryKey)byId.set(eid,ids.get(detail.categoryKey));}
  for(const [eid,reason]of unavailableById)if(!detailsById.has(eid))detailsById.set(eid,{available:false,status:'unassessed',reason,propertyIds:[index.elements.get(eid).pid]});
  const available=byId.size,total=index.elements.size,note=NOTE+(stale?' '+stale:'')+(issues.length?' '+issues.length+' physical-region membership/assessment issue(s) remain; see element details.':'');
  return{kind:'reserve_factor_field',fieldKind:opt.kind,failureMode:opt.failureMode,palette:opt.palette,name:title,title,unit:categorical?'category':'RF',location:'element',domain:'all',byId,colorById,detailsById,unavailableById,categorical,categories,gradient:categorical?[]:tables.colorStops({min:0,max:2},opt.palette),min:categorical?(categories.length?1:0):0,max:categorical?categories.length:2,actualMin,actualMax,available,total,coverage:{available,total,unavailable:total-available},complete:available===total&&total>0,issues,stale:!!stale,message:stale||available+' / '+total+' structural elements assessed; gray = unassessed or inapplicable.',note,report};
 }
 function build(input={},request={}){
  const opt=options(input,request),context={...input,...request,failureMode:opt.failureMode},cached=input.report;
  const report=cached?.failureMode===opt.failureMode&&!freshness(context,cached)&&(context.cases===undefined||stress.currentContext(cached,context))?cached:stress.build(context);
  return project(context,report,opt);
 }
 return{FIELD_KINDS,FAILURE_MODES,NOTE,options,categoryColor,build,project};
});
