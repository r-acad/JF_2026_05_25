/* Combine existing physical assessments without changing their ownership.
 * A column or plate result is shared with a property only through actual EIDs. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMinimumRFData=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),id=n=>Number.isSafeInteger(Number(n))&&Number(n)>0;
 const entries=v=>v instanceof Map?[...v]:Array.isArray(v)?v.map((item,i)=>[item.id??i+1,item]):Object.entries(v||{});
 const unique=v=>[...new Set(v.filter(id).map(Number))].sort((a,b)=>a-b);
 const COMPONENTS={spar_web_buckling:{kind:'spar_web',collection:'web_panels',type:'plate'},rib_web_buckling:{kind:'rib_web',collection:'web_panels',type:'plate'},spar_cap_buckling:{kind:'spar_cap',collection:'columns',type:'column'},rib_stiffener_buckling:{kind:'rib_stiffener',collection:'columns',type:'column'},rib_stiffener_blade:{kind:'rib_stiffener_blade',collection:'blades',type:'blade'}};
 const MODES={von_mises:'Von Mises stress',principal_strain:'Laminate principal strain',euler_column:'Euler column buckling',stringer_blade:'Stringer blade instability',skin_buckling:'Skin panel buckling',spar_web_buckling:'Spar-web buckling',rib_web_buckling:'Rib-web buckling',spar_cap_buckling:'Spar-cap column buckling',rib_stiffener_buckling:'Rib-stiffener column buckling',rib_stiffener_blade:'Rib-stiffener blade instability'};
 function modelIndex(input){
  const elements=new Map(),properties=new Map();
  for(const [raw,element]of entries(input.elements)){
   const group=element?.group,eid=Number(raw),pid=Number(group?.pid??group?.properties?.pid);
   if(!id(eid)||!id(pid)||!['quad','tria','shell','solid','bar'].includes(group?.kind)||group.name==='aero')continue;
   elements.set(eid,{pid,property:group.properties});
   if(!properties.has(pid))properties.set(pid,{elements:[],properties:[],names:new Set()});const region=properties.get(pid);region.elements.push(eid);region.names.add(group.name||'');
   if(!region.properties.includes(group.properties))region.properties.push(group.properties);
  }
  return{elements,properties};
 }
 function gaugeFor(propertyIds,index){
  const pids=unique(propertyIds),dimensions=[];
  const unknown=reason=>({known:false,atMinimum:false,propertyIds:pids,dimensions,reason});
  if(!pids.length)return unknown('No verified physical property membership is available.');
  for(const pid of pids){
   const properties=index.properties.get(pid)?.properties;if(!properties?.length)return unknown('P'+pid+' has no current property definition.');
   let proof=null;
   for(const property of properties){
    const g=property?.minimum_gauge;
    if(g?.status!=='known'||!Array.isArray(g.dimensions)||!g.dimensions.length)return unknown('P'+pid+': '+(g?.reason||'No configured minimum-gauge proof is available.'));
    const normalized=[];
    for(const d of g.dimensions){
     if(!d||typeof d.field!=='string'||!d.field||typeof d.minimum_key!=='string'||!d.minimum_key||!finite(d.value_m)||!finite(d.minimum_m)||d.value_m<0||d.minimum_m<0||typeof d.at_minimum!=='boolean')return unknown('P'+pid+' has incomplete minimum-dimension metadata.');
     const tolerance=1e-10*Math.max(Math.abs(d.value_m),Math.abs(d.minimum_m),1e-12),atMinimum=Math.abs(d.value_m-d.minimum_m)<=tolerance;
     if(d.value_m<d.minimum_m-tolerance||d.at_minimum!==atMinimum)return unknown('P'+pid+' has inconsistent minimum-dimension metadata.');
     normalized.push({pid,...d,atMinimum});
    }
    const atMinimum=normalized.every(d=>d.atMinimum);
    if(g.at_minimum!==atMinimum||g.can_reduce!==!atMinimum)return unknown('P'+pid+' minimum-gauge summary disagrees with its actual dimensions.');
    const signature=JSON.stringify(normalized.slice().sort((a,b)=>a.field.localeCompare(b.field)));
    if(proof&&proof.signature!==signature)return unknown('P'+pid+' has conflicting minimum-gauge definitions.');
    proof={signature,normalized};
   }
   dimensions.push(...proof.normalized);
  }
  return{known:true,atMinimum:dimensions.every(d=>d.atMinimum),propertyIds:pids,dimensions,reason:''};
 }
 function metadata(input,mode){const c=COMPONENTS[mode];if(c){const rows=input.componentBuckling?.[c.collection];return Array.isArray(rows)?rows.filter(r=>r.kind===c.kind):undefined;}return mode==='euler_column'?input.eulerColumns:mode==='stringer_blade'?input.stringerBlades:mode==='skin_buckling'?input.skinBucklingPanels:[];}
 function membership(raw,mode,index){
  const refs=[...(raw?.member_element_ids||[]).map(eid=>({eid}))];
  if(mode==='euler_column'||COMPONENTS[mode]?.type==='column')for(const station of raw?.stations||[])refs.push(...(station.force_terms||[]),...(station.parts||[]));
  if(mode==='stringer_blade'||COMPONENTS[mode]?.type==='blade')refs.push(...(raw?.bars||[]));
  if(mode==='skin_buckling'||COMPONENTS[mode]?.type==='plate')refs.push(...(raw?.elements||[]));
  const eids=unique(refs.map(r=>r.eid)),byPid=new Map(),missing=[];
  for(const eid of eids){const actual=index.elements.get(eid);if(!actual){missing.push(eid);continue;}if(!byPid.has(actual.pid))byPid.set(actual.pid,[]);byPid.get(actual.pid).push(eid);}
  let conflicting=false;for(const ref of refs){const actual=index.elements.get(Number(ref.eid));if(actual&&id(ref.pid)&&Number(ref.pid)!==actual.pid)conflicting=true;}
  return{elementIds:eids,propertyIds:[...byPid.keys()].sort((a,b)=>a-b),byPid,complete:eids.length>0&&!missing.length&&!conflicting&&raw?.membership_complete!==false,reason:raw?.membership_complete===false?'The full physical criterion membership could not be established.':conflicting?'Criterion element/property membership differs from the current model.':missing.length?'Criterion members are missing from the current model: '+missing.join(', '):!eids.length?'The physical criterion has no verified element membership.':''};
 }
 function decorate(report,input,index=modelIndex(input)){
  const mode=report.failureMode,map=new Map((metadata(input,mode)||[]).map(raw=>[String(raw.key),raw]));
  for(const row of report.rows||[]){
   if(mode==='von_mises'||mode==='principal_strain'||mode==='minimum_rf'){row.minimumGauge=gaugeFor([row.pid],index);continue;}
   const members=membership(map.get(String(row.panelKey)),mode,index);
   row.minimumGauge=members.complete?gaugeFor(members.propertyIds,index):{known:false,atMinimum:false,propertyIds:members.propertyIds,dimensions:[],reason:members.reason};
  }
  return report;
 }
 function vonMisesApplicable(properties){
  if(properties.some(p=>p?.type==='PCOMP'))return false;
  if(properties.some(p=>p?.material?.type&&p.material.type!=='MAT1'))return false;
  return true;
 }
 const noDemand=(row,mode)=>mode==='von_mises'?row.complete&&row.envelopeStress===0&&finite(row.allowableStress)&&row.allowableStress>0:mode==='principal_strain'?row.noDemand===true:mode==='euler_column'||COMPONENTS[mode]?.type==='column'?row.euler?.noCompression===true:mode==='stringer_blade'||COMPONENTS[mode]?.type==='blade'?row.blade?.noCompression===true:row.skinBuckling?.noDestabilizingLoad===true;
 function candidate(row,mode,members){
  const sentinel=noDemand(row,mode),complete=row.complete===true&&members.complete&&(sentinel||finite(row.reserveFactor)&&row.reserveFactor>0),scope=mode==='von_mises'||mode==='principal_strain'?'Full property P'+row.pid:row.label;
  return{failureMode:mode,modeLabel:MODES[mode]||mode,sourceRowKey:row.rowKey||(mode+':P'+row.pid),scope,scopeKey:row.panelKey||'property:'+row.pid,propertyIds:members.propertyIds,physicalElementCount:members.elementIds.length,physicalElementIds:members.elementIds,reserveFactor:complete?(sentinel?99:row.reserveFactor):null,noDemand:sentinel&&complete,complete,caseLabel:sentinel?'All selected cases (no demand)':row.envelopeCaseLabel||'',caseKey:sentinel?'':row.envelopeCaseKey||'',coverage:row.coverage,recoveryMethods:row.recoveryMethods||[],status:complete?'complete':row.status||'unavailable',reason:!members.complete?members.reason:complete?'':row.reserveFactorReason||'This applicable criterion has not been completely assessed.',certifiedCases:(row.caseResults||[]).filter(c=>c.certifiedNonGoverning).map(c=>({label:c.label,lowerBound:c.lowerBound,boundReason:c.boundReason})),...(row.skinBuckling?{plateCases:(row.caseResults||[]).map(c=>Object.fromEntries(['label','method','converged','noDestabilizingLoad','certifiedNonGoverning','basisM','basisN','basisSize','convergenceError','targetTolerance','basisStage','modeLimit','history','reason','recovered','total'].filter(k=>c[k]!==undefined).map(k=>[k,c[k]])))}:{}),details:row.euler||row.blade||row.skinBuckling||row.principalStrain||null};
 }
 const NOTE='Each original property reports the lowest complete reserve factor among applicable existing criteria and selected physical SOL101/full-load SOL106 cases. A physical column or plate contributes only when its actual member elements belong to that property. Its RF still describes the complete shared column or plate; it is not a new local property-only stress calculation. Candidate details retain the full physical scope and member IDs. Missing recovery, invalid applicable criteria or incomplete case coverage suppress the combined RF; the lowest available result is diagnostic only. No-demand RF 99 is a display sentinel and never takes precedence over a finite calculated RF, even when that calculated value exceeds 99. If all applicable checks have no demand, the displayed value is 99. This is an envelope of the implemented checks, not a prediction of all possible failure modes. Yellow means RF > 1 and every actual dimension of this property is verified at its configured minimum; other properties in a shared criterion may still be reducible.';
 function build(input,reports){
  const index=modelIndex(input),base=reports.von_mises,byPid=new Map((base.rows||[]).map(row=>[Number(row.pid),[]])),excluded=new Map(),unmapped=[];
  for(const row of base.rows||[]){
   const region=index.properties.get(Number(row.pid));
   if(!region)continue;
   if(!vonMisesApplicable(region.properties)){excluded.set(row.pid,[{failureMode:'von_mises',reason:'An isotropic von Mises check does not apply to this material/property definition.'}]);continue;}
   const members={elementIds:region.elements,propertyIds:[row.pid],byPid:new Map([[row.pid,region.elements]]),complete:true};
   byPid.get(row.pid).push({...candidate(row,'von_mises',members),elementIds:region.elements});
  }
  for(const item of reports.principal_strain?.excludedProperties||[]){if(!excluded.has(item.pid))excluded.set(item.pid,[]);excluded.get(item.pid).push(item);}
  for(const mode of ['principal_strain','euler_column','stringer_blade','skin_buckling',...Object.keys(COMPONENTS)]){
   if(input.generated===false&&mode!=='principal_strain')continue;
   const rawByKey=new Map((metadata(input,mode)||[]).map(raw=>[String(raw.key),raw]));
   for(const row of reports[mode]?.rows||[]){
    const raw=rawByKey.get(String(row.panelKey));
    if(raw?.applicable===false||raw?.status==='not_applicable'){
     for(const pid of membership(raw,mode,index).propertyIds){if(!excluded.has(pid))excluded.set(pid,[]);excluded.get(pid).push({failureMode:mode,scope:row.label,reason:raw.reason||'This physical criterion is explicitly inapplicable.'});}continue;
    }
    let members;
    if(mode==='principal_strain'){const region=index.properties.get(Number(row.pid));if(!region)continue;members={elementIds:region.elements,propertyIds:[row.pid],byPid:new Map([[row.pid,region.elements]]),complete:true};}
    else members=membership(raw,mode,index);
    if(!members.propertyIds.length){unmapped.push({failureMode:mode,scope:row.label,sourceRowKey:row.rowKey,reason:raw?.reason||members.reason});continue;}
    const assessed=candidate(row,mode,members);
    for(const pid of members.propertyIds)if(byPid.has(pid))byPid.get(pid).push({...assessed,elementIds:members.byPid.get(pid),scopeNote:'Applies through '+members.byPid.get(pid).length+' actual P'+pid+' element(s); criterion covers '+members.elementIds.length+' element(s) across '+members.propertyIds.map(p=>'P'+p).join(', ')+'.'});
   }
  }
  // An old saved generated mesh may have stresses but none of the newer
  // physical criterion metadata. Absence cannot silently mean inapplicable.
  // These are coverage requirements, not guessed ownership of a failed plate.
  const coverageGaps=[];
  if(input.generated===true){
   const family=region=>{const names=[...region.names];return{skin:names.some(n=>/^(?:UPPER_SKIN|LOWER_SKIN)(?:_|$)/.test(n)),stringer:names.some(n=>/^(?:STRINGERS|STRINGER_WEBS|STRINGER_FLANGES)(?:_|$)/.test(n)),beam:names.some(n=>/^STRINGERS(?:_|$)/.test(n)),spar_web:names.some(n=>/^(?:FRONT_SPAR_WEB|REAR_SPAR_WEB)(?:_|$)/.test(n)),rib_web:names.some(n=>/^RIB_WEBS(?:_|$)/.test(n)),spar_cap:names.some(n=>/^SPAR_CAPS(?:_|$)/.test(n)),rib_stiffener:names.some(n=>/^RIB_STIFFENERS(?:_|$)/.test(n))};};
   const families=new Map([...index.properties].map(([pid,region])=>[pid,family(region)])),hasStringers=[...families.values()].some(f=>f.stringer);
   const addGap=(mode,reason,affected)=>{coverageGaps.push({failureMode:mode,reason,propertyIds:affected});for(const pid of affected)if(byPid.has(pid))byPid.get(pid).push({failureMode:mode,modeLabel:MODES[mode]||'Physical assessment coverage',scope:'Generated-model criterion metadata',scopeKey:'coverage:'+mode,sourceRowKey:'coverage:'+mode,propertyIds:[pid],elementIds:[],physicalElementIds:[],physicalElementCount:0,coverageRequirement:true,complete:false,noDemand:false,reserveFactor:null,caseLabel:'',caseKey:'',reason,status:'unavailable',coverage:{recovered:0,total:1}});};
   for(const mode of ['euler_column','stringer_blade','skin_buckling']){
    const raw=metadata(input,mode),missing=!Array.isArray(raw),empty=Array.isArray(raw)&&!raw.length;
    const affected=[...families].filter(([,f])=>missing||(empty&&(mode==='skin_buckling'?f.skin:mode==='stringer_blade'?f.beam:hasStringers&&(f.skin||f.stringer)))).map(([pid])=>pid);
    if(affected.length)addGap(mode,'Generated physical '+(MODES[mode]||mode)+' metadata is missing. Regenerate the mesh before claiming a complete failure-mode envelope.',affected);
   }
   for(const [mode,descriptor]of Object.entries(COMPONENTS)){
    const raw=metadata(input,mode)||[],familyKey=descriptor.kind==='rib_stiffener_blade'?'rib_stiffener':descriptor.kind;
    const covered=new Set(raw.flatMap(r=>membership(r,mode,index).elementIds));
    const affected=[...families].filter(([pid,f])=>f[familyKey]&&index.properties.get(pid).elements.some(eid=>!covered.has(eid))).map(([pid])=>pid);
    if(affected.length)addGap(mode,'Generated physical '+MODES[mode]+' metadata does not cover every actual component element. Regenerate the mesh to assess this component.',affected);
   }
   if(unmapped.length)addGap('physical_coverage','One or more generated physical criteria cannot be associated with current element IDs; regenerate the mesh. Their unknown ownership prevents a complete envelope.',[...byPid.keys()]);
   // A failed Euler construction knows its stringer members but may not know
   // every skin intersected by its sections. Suppress a passing skin/stringer
   // envelope without pretending that an unknown region is a proven member.
   if((input.eulerColumns||[]).some(raw=>raw.applicable!==false&&raw.membership_complete===false))addGap('euler_column','A generated Euler column has incomplete physical membership. Associated skin ownership may be unresolved; complete section construction is required.',[...families].filter(([,f])=>f.skin||f.stringer).map(([pid])=>pid));
  }
  const rows=(base.rows||[]).map(original=>{
   const assessments=byPid.get(Number(original.pid))||[],available=assessments.filter(a=>a.complete&&!a.noDemand&&finite(a.reserveFactor)),governing=available.reduce((best,a)=>!best||a.reserveFactor<best.reserveFactor?a:best,null),complete=assessments.length>0&&assessments.every(a=>a.complete),sentinel=complete&&assessments.every(a=>a.noDemand),rf=complete?(sentinel?99:governing?.reserveFactor??null):null,knownMinimum=governing?.reserveFactor??null;
   const missing=assessments.filter(a=>!a.complete),why=!assessments.length?'No applicable implemented criterion can be associated with this property.':!complete?missing.map(a=>a.modeLabel+' / '+a.scope+': '+a.reason).join(' '):'';
   const selected=complete&&!sentinel?governing:null,caseLabel=sentinel?'All selected cases (no demand)':selected?.caseLabel||'';
   return{...original,rowKey:'minimum:P'+original.pid,reserveFactor:finite(rf)?rf:null,reserveFactorReason:why,complete,status:complete?'complete':assessments.some(a=>a.complete)?'partial':'unavailable',envelopeCaseLabel:caseLabel,envelopeCaseKey:selected?.caseKey||'',coverage:{recovered:assessments.filter(a=>a.complete).length,total:assessments.length},caseResults:[],reasons:missing.map(a=>({reason:a.reason,count:1,caseLabel:a.modeLabel+' / '+a.scope})),minimumGauge:gaugeFor([original.pid],index),combined:{governingMode:selected?.failureMode||'',governingModeLabel:sentinel?'No demand in applicable checks':selected?.modeLabel||'',governingCase:caseLabel,governingScope:sentinel?'All associated physical scopes':selected?.scope||'',governingScopeKey:selected?.scopeKey||'',governingSourceRowKey:selected?.sourceRowKey||'',assessments,excluded:excluded.get(original.pid)||[],knownMinimum,complete,sentinel}};
  });
  return{...base,failureMode:'minimum_rf',rows,complete:rows.length>0&&rows.every(r=>r.complete),coverage:{recovered:rows.reduce((n,r)=>n+r.coverage.recovered,0),total:rows.reduce((n,r)=>n+r.coverage.total,0),properties:rows.length},unmappedCriteria:unmapped,coverageGaps,note:NOTE+(input.generated===false?' Imported-model geometry has no verified generated rib-bay/plate boundaries; those physical checks are excluded. This envelope covers the available material allowable criteria only.':'')+(unmapped.length?' '+unmapped.length+' physical criterion/criteria could not be assigned to a property because actual member identities are unavailable; regenerate the mesh and review the assessment details.':'')+(coverageGaps.length?' Generated-model physical criterion coverage is incomplete; affected rows remain unassessed until the mesh and metadata are regenerated.':'')};
 }
 return{MODES,modelIndex,gaugeFor,membership,decorate,candidate,build,NOTE};
});
