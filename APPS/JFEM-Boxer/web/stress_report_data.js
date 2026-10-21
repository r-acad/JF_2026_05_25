/* Physical, property-level stress envelopes. Never combine normalized modes,
 * historical results, different meshes or per-case samples into one mean. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./material_allowables.js'):root.WingMaterialAllowables,typeof module==='object'&&module.exports?require('./color_scales.js'):root.WingColorScales,typeof module==='object'&&module.exports?require('./euler_column_data.js'):root.WingEulerColumnData,typeof module==='object'&&module.exports?require('./stringer_blade_data.js'):root.WingStringerBladeData,()=>typeof module==='object'&&module.exports?require('./reserve_factor_table_data.js'):root.WingReserveFactorTableData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingStressReportData=api;})(globalThis,function(allowables,colors,euler,blade,reserveFactors){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n);
 const METHODS={maximum:'Maximum',mean:'Average',trimmed_mean:'Average below percentile'};
 const format=n=>finite(n)?Number(n.toPrecision(5)).toString():'Unavailable';
 const entries=value=>value instanceof Map?[...value]:Array.isArray(value)?value.map((item,i)=>[item.id??i+1,item]):Object.entries(value||{});
 const analysisNumber=result=>{const value=String(result?.analysis??result?.analysis_type??result?.solution??''),match=/(?:^|\b)SOL\s*(101|103|105|106)(?:\b|_)|^(101|103|105|106)$/i.exec(value);return Number(match?.[1]||match?.[2])||null;};
 const reason=(message,count=1)=>({reason:message,count});
 function countReason(list,message){const item=list.find(item=>item.reason===message);if(item)item.count++;else list.push(reason(message));}
 function methodOptions(method='maximum',percentile=95){if(method==='max')method='maximum';if(!Object.hasOwn(METHODS,method))throw Error('Unknown stress envelope method.');if(!finite(percentile)||percentile<=0||percentile>100)throw Error('Stress percentile must be greater than 0 and at most 100.');return{method,percentile};}
 function percentileValue(sorted,p){if(!sorted.length)return null;const rank=(sorted.length-1)*p/100,lo=Math.floor(rank),f=rank-lo;return sorted[lo]*(1-f)+(sorted[Math.ceil(rank)]??sorted[lo])*f;}
 function aggregate(samples,method='maximum',percentile=95){
  ({method,percentile}=methodOptions(method,percentile));
  if(!samples.length)return{maximum:null,envelope:null,cutoff:null,retained:0,discarded:0,maxEid:null,maxFace:null};
  if(samples.some(item=>!finite(item.value)||item.value<0))throw Error('Stress samples must be finite and nonnegative.');
  let peak=samples[0];for(const sample of samples)if(sample.value>peak.value)peak=sample;
  const cutoff=method==='trimmed_mean'?percentileValue(samples.map(item=>item.value).sort((a,b)=>a-b),percentile):null;
  // Symmetric FE points often differ by a few floating-point ulps. Treat only
  // roundoff-scale differences as ties, so rank interpolation rounding cannot
  // arbitrarily exclude one of two physically identical peaks.
  const kept=method==='trimmed_mean'?samples.filter(item=>item.value<=cutoff||item.value-cutoff<=16*Number.EPSILON*Math.max(Math.abs(item.value),Math.abs(cutoff))):samples;
  // Scale by the retained peak before summing. The normalized average stays
  // within [0,1], including at Number.MAX_VALUE where sum(value/n) can still
  // overflow from rounding even though the mathematical mean is finite.
  let retainedPeak=0;for(const item of kept)retainedPeak=Math.max(retainedPeak,item.value);
  const envelope=method==='maximum'?peak.value:retainedPeak===0?0:retainedPeak*(kept.reduce((sum,item)=>sum+item.value/retainedPeak,0)/kept.length);
  return{maximum:peak.value,envelope,cutoff,retained:kept.length,discarded:samples.length-kept.length,maxEid:peak.eid??null,maxFace:peak.face??null};
 }
 function caseReason(r,context={}){
  const sol=analysisNumber(r);
  if(![101,106].includes(sol))return 'Only explicitly identified SOL101 and SOL106 results are included.';
  if(r?.source==='disk_results'||/^STATIC \(stored\)/i.test(r?.analysis||''))return 'The archive does not retain the analysis and stress-recovery provenance required by this report.';
  if(r?.available===false)return r.message||'Results are unavailable.';
  if(r?.matches!==true)return 'Results have not been verified against the current model.';
  if(r.historical)return 'Historical model formulation; rerun the current model.';
  if(context.signature!==undefined&&r.signature!==context.signature)return 'Results belong to a different model definition.';
  if(context.meshIdentity!==undefined&&r.meshIdentity!==context.meshIdentity)return 'Results belong to a different mesh.';
  if(!r.static)return 'No physical static result was returned.';
  if(/fail|cancel|timeout|stop|partial|running|pending|error/i.test(r.status||''))return 'The analysis is incomplete or unsuccessful ('+(r.status||'unknown')+').';
  if(r.validationIssues?.length)return r.validationIssues.join(' ');
  if(sol===106&&!r.convergence)return 'The nonlinear result has no full-load convergence record.';
  if(r.convergence&&(r.convergence.converged!==true||r.convergence.full_load!==true||r.convergence.partial))return 'The nonlinear result has not converged at full load.';
  if((sol===106||context.parentSolution===106)&&r.loadScale!==undefined&&(!finite(r.loadScale)||Math.abs(r.loadScale-1)>1e-12))return 'The comparison represents only a partial applied load.';
  return '';
 }
 function caseList(input={}){
  const selected=input.caseId??'all',included=[],excluded=[],present=new Set();
  const labels=new Map(entries(input.caseLabels).map(([id,item])=>[String(id),typeof item==='object'?item.label??item.name??String(id):String(item)]));
  const globalReason=input.modelDirty||input.pendingDrafts?'The model definition has unsolved changes.':input.running?'Analysis is running; completed current results are required.':'';
  for(const [id,parent]of entries(input.cases)){
   if(selected!=='all'&&String(selected)!==String(id))continue;
   present.add(String(id));const parentSolution=analysisNumber(parent),parentExcluded=parentSolution===105||parent?.modeKind==='buckling'||parentSolution===103||parent?.modeKind==='frequency';
   const physicalLabel=labels.get(String(id))||parent?.caseLabel||parent?.label||('Load case '+id);
   const variants=entries(parent?.variants);const records=variants.length?variants:[[parent?.variantId||'default',parent]];
   for(const [variant,r]of records){
    const solution=analysisNumber(r),item={caseId:Number(id)||id,caseKey:String(id)+':'+variant,variant:String(variant),solution,label:physicalLabel+' · SOL'+(solution||'?')+(parentSolution===106&&solution===101?' linear comparison':''),result:r};
    const why=globalReason||(parentExcluded?'This modal or buckling analysis is outside the SOL101/SOL106 report.':caseReason(r,{...input,parentSolution}));
    if(why)excluded.push({...item,reason:why,relevant:!parentExcluded&&([101,106].includes(solution)||solution===null)});else included.push(item);
   }
  }
  const missing=[];for(const [key,c]of entries(input.expectedCases)){
   const id=c?.id??key,solution=analysisNumber(c);if(c?.enabled===false||selected!=='all'&&String(selected)!==String(id)||[103,105].includes(solution))continue;
   const label=c?.label||c?.name||labels.get(String(id))||'Load case '+id;
   if(!present.has(String(id)))missing.push({caseId:Number(id)||id,label,reason:'No result has been returned for this load case.'});
   else if(solution&&!included.concat(excluded).some(item=>String(item.caseId)===String(id)&&item.solution===solution))missing.push({caseId:Number(id)||id,label,reason:'No SOL'+solution+' result has been returned for this load case.'});
  }
  return{included,excluded,missing,complete:!globalReason&&!missing.length&&!excluded.some(item=>item.relevant)&&included.length>0};
 }
 function propertyAllowable(properties,rows){
  const mids=new Set();
  for(const property of properties){
   if(!property)return{value:null,materialIds:[],reason:'Material definition unavailable.'};
   if(property.type==='PCOMP')return{value:null,materialIds:[...new Set((property.plies||[]).map(p=>Number(p.material_id??p.material?.id)).filter(Number.isSafeInteger))],reason:'Laminate properties require laminate-specific failure criteria; no isotropic von Mises reserve factor is assigned.'};
   const referenced=[...new Set([...(property.material_ids||[]),...Object.values(property.material_roles||{}),property.material_id,property.material?.id].map(Number).filter(id=>Number.isSafeInteger(id)&&id>0))];
   if(referenced.length>1)return{value:null,materialIds:referenced,reason:'The shell property references different membrane, bending or shear materials; no common allowable is assumed.'};
   const mat=property.material,mid=Number(property.material_id??mat?.id);if(!Number.isSafeInteger(mid)||mid<1||mat?.type!=='MAT1')return{value:null,materialIds:[...mids],reason:'A single isotropic MAT1 material is required for a von Mises reserve factor.'};
   mids.add(mid);
  }
  if(mids.size!==1)return{value:null,materialIds:[...mids],reason:'The property region contains different materials; no common allowable is assumed.'};
  const mid=[...mids][0],matching=(Array.isArray(rows)?rows:[]).filter(row=>Number(row?.material_id)===mid);
  if(matching.length!==1||matching[0].mode!=='stress'||!finite(matching[0].stress)||matching[0].stress<=0)return{value:null,materialIds:[mid],reason:'Enter one positive von Mises stress allowable for material '+mid+'.'};
  return{value:matching[0].stress,materialIds:[mid],reason:''};
 }
 function stressSample(property,record){
  if(!property)return{reason:'Property definition unavailable.'};
  if(property.type==='PCOMP')return{reason:'Laminate von Mises values are not used as isotropic stress criteria.'};
  // Shared recovery guards require both shell faces and reject invalid samples.
  // The helper also deliberately refuses an axial-stress proxy for beams.
  return allowables.equivalentStressSample(property,record);
 }
 function build(input={}){
  if(input.failureMode==='euler_column')return euler.build(input,caseList(input));
  if(input.failureMode==='stringer_blade')return blade.build(input,caseList(input));
  const {method,percentile}=methodOptions(input.method,input.percentile),cases=caseList(input),regions=new Map();
  for(const [rawEid,element]of entries(input.elements)){
   const group=element.group;if(!['quad','tria','shell','solid','bar'].includes(group?.kind)||group.name==='aero')continue;
   const pid=Number(group.pid??group.properties?.pid),eid=Number(rawEid);if(!Number.isSafeInteger(pid)||pid<=0||!Number.isSafeInteger(eid)||eid<=0)continue;
   let region=regions.get(pid);if(!region){region={pid,label:'P'+pid,names:new Set(),properties:[],elements:[]};regions.set(pid,region);}
   if(group.name)region.names.add(group.name);if(!region.properties.includes(group.properties))region.properties.push(group.properties);region.elements.push({eid,property:group.properties});
  }
  const rows=[];let recovered=0;
  for(const region of [...regions.values()].sort((a,b)=>a.pid-b.pid)){
   const limit=propertyAllowable(region.properties,input.allowables),caseResults=[];let maximum=null,envelope=null;const reasons=[];
   for(const item of cases.included){
    const samples=[],missing=[],records=item.result.elementResults??item.result.element_results;
    for(const {eid,property}of region.elements){const record=records instanceof Map?records.get(eid)??records.get(String(eid)):records?.[String(eid)],sample=stressSample(property,record);if(sample.reason){countReason(missing,sample.reason);continue;}samples.push({eid,value:sample.demand,face:sample.face});}
    const stats=aggregate(samples,method,percentile),result={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total:region.elements.length,recovered:samples.length,...stats,reasons:missing};caseResults.push(result);recovered+=samples.length;
    for(const missingReason of missing)reasons.push({...missingReason,caseLabel:item.label});
    if(finite(stats.maximum)&&(!maximum||stats.maximum>maximum.maximum))maximum=result;if(finite(stats.envelope)&&(!envelope||stats.envelope>envelope.envelope))envelope=result;
   }
   const complete=cases.complete&&caseResults.every(c=>c.recovered===c.total),rf=complete&&limit.value!==null&&envelope?.envelope>0?limit.value/envelope.envelope:null;
   const reserveFactorReason=!complete?'Incomplete case or element coverage; reserve factor is not assessed.':limit.reason||(!envelope?.envelope?'Zero stress has no finite reserve factor.':!finite(rf)?'Allowable / stress ratio exceeds the numeric range.':'');
   rows.push({pid:region.pid,label:region.label,names:[...region.names],propertyType:[...new Set(region.properties.map(p=>p?.type||'Unknown'))].join(' / '),materialIds:limit.materialIds,elementCount:region.elements.length,
    maxStress:maximum?.maximum??null,maxCaseLabel:maximum?.label??'',maxCaseKey:maximum?.caseKey??'',maxEid:maximum?.maxEid??null,maxFace:maximum?.maxFace??null,
    envelopeStress:envelope?.envelope??null,envelopeCaseLabel:envelope?.label??'',envelopeCaseKey:envelope?.caseKey??'',envelopeEid:method==='maximum'?envelope?.maxEid??null:null,
    allowableStress:limit.value,reserveFactor:finite(rf)?rf:null,reserveFactorReason,complete,status:complete?'complete':caseResults.some(c=>c.recovered)?'partial':'unavailable',coverage:{recovered:caseResults.reduce((sum,c)=>sum+c.recovered,0),total:region.elements.length*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length)},caseResults,reasons});
  }
  const note='One sample per element: its maximum explicitly recovered von Mises stress over the available faces or integration points. Compute the selected statistic separately in each property and load case, then take the largest case value. Means weight elements equally, not by area or volume. The percentile uses linear interpolation at rank (n − 1) × p / 100; the trimmed mean keeps element peaks at or below that value, including ties within 16 machine epsilons of relative roundoff. Raw maximum stress is always retained. Missing recovery is never replaced by zero; incomplete coverage suppresses reserve factors. SOL106 reserve factors are elastic demand ratios, not predicted load multipliers.';
  return{failureMode:'von_mises',rows,includedCases:cases.included.map(({result,...item})=>item),excludedCases:cases.excluded.map(({result,...item})=>item),missingCases:cases.missing,method,percentile,stressUnit:input.sourceUnits?'source stress units':'MPa',stressFactor:input.sourceUnits?1:1e-6,complete:cases.complete&&rows.length>0&&rows.every(row=>row.complete),coverage:{recovered,total:rows.reduce((sum,row)=>sum+row.coverage.total,0),properties:rows.length},note};
 }
 const escapeHTML=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const escapeMD=value=>String(value??'').replace(/\\/g,'\\\\').replace(/[|*_`\[\]<>]/g,'\\$&').replace(/\r?\n/g,'<br>');
 function table(report,kind='stress'){
  if(report.failureMode==='euler_column')return{title:'Euler stringer-column reserve factors',headers:['Stringer column','Stringer property','Material IDs','Critical load ('+report.forceUnit+')','Compressive demand ('+report.forceUnit+')','Reserve factor','Governing case','Governing cut','Unbraced length ('+report.lengthUnit+')','End-fixity coefficient c','Weakest EI ('+report.forceUnit+'·'+report.lengthUnit+'²)','Recovery','Status / note'],rows:report.rows.map(row=>{const r=row.euler||{};return[row.label,'P'+row.pid,row.materialIds.join('; '),format(r.criticalLoad),format(r.compressionDemand),format(row.reserveFactor),row.envelopeCaseLabel||'—',r.governingStation??'—',format(r.length),format(r.endFactor),format(r.weakestEI),row.coverage.recovered+' / '+row.coverage.total,row.reserveFactorReason||r.note||row.status];})};
  const factor=report.stressFactor,stress=value=>finite(value)?format(value*factor):'Unavailable';
  if(report.failureMode==='stringer_blade')return{title:'Stringer blade instability reserve factors',headers:['Stringer blade','Stringer property','Material IDs','Critical stress ('+report.stressUnit+')','Mean compression ('+report.stressUnit+')','Reserve factor','Governing case','Mean signed axial stress ('+report.stressUnit+')','Critical EID','Clear web height (m)','Web thickness (m)','Plate coefficient k','Young modulus ('+report.stressUnit+')','Poisson ratio','Bar recovery','Status / note'],rows:report.rows.map(row=>{const r=row.blade||{};return[row.label,'P'+row.pid,row.materialIds.join('; '),stress(r.criticalStress),stress(r.compressionDemand),format(row.reserveFactor),row.envelopeCaseLabel||'—',stress(r.averageStress),r.criticalEid??'—',format(r.clearHeight),format(r.thickness),format(r.coefficient),stress(r.young),format(r.poisson),row.coverage.recovered+' / '+row.coverage.total,row.reserveFactorReason||r.note||row.status];})};
  const headers=kind==='reserve'?['Property','Material IDs','Allowable ('+report.stressUnit+')','Envelope ('+report.stressUnit+')','Reserve factor','Governing case','Coverage','Status / note']:['Property','Type','Maximum ('+report.stressUnit+')','Maximum case','Peak EID','Envelope ('+report.stressUnit+')','Envelope case','Coverage','Status'];
  const rows=report.rows.map(row=>kind==='reserve'?[row.label,row.materialIds.join('; '),stress(row.allowableStress),stress(row.envelopeStress),format(row.reserveFactor),row.envelopeCaseLabel,row.coverage.recovered+' / '+row.coverage.total,row.reserveFactorReason||row.status]:[row.label,row.propertyType,stress(row.maxStress),row.maxCaseLabel,row.maxEid??'',stress(row.envelopeStress),row.envelopeCaseLabel,row.coverage.recovered+' / '+row.coverage.total,row.status]);
  return{title:kind==='reserve'?'Reserve factors':'Property stress report',headers,rows};
 }
 const methodLabel=report=>report.failureMode==='euler_column'?'Minimum reserve factor across section cuts and load cases':report.failureMode==='stringer_blade'?'Equal-weight mean signed bar axial stress in each case; minimum reserve factor across cases':METHODS[report.method]+(report.method==='trimmed_mean'?' · '+format(report.percentile)+'th percentile':'');
 function exportNotes(report){const euler=report.failureMode==='euler_column',blade=report.failureMode==='stringer_blade';return[(euler||blade?'Assessment method: ':'Envelope method: ')+methodLabel(report),...(report.palette?['Color scale: '+report.palette+'. Reserve-factor colors use fixed limits 0 to 2; larger values saturate and use dark-orange numbers.']:[]),report.note,...report.excludedCases.map(c=>'Excluded '+c.label+': '+c.reason),...report.missingCases.map(c=>'Missing '+c.label+': '+c.reason),...report.rows.flatMap(row=>row.reasons.map(r=>row.label+' / '+r.caseLabel+': '+r.count+(euler?' section-cut(s): ':' element(s): ')+r.reason))];}
 function csvCell(value){let text=String(value??'');if(typeof value==='string'&&/^\s*[=+@-]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';}
 function csv(report,kind='stress'){const t=table(report,kind);return '\uFEFF'+[[t.title],...exportNotes(report).map(s=>[s]),[],t.headers,...t.rows].map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n';}
 function markdown(report,kind='stress'){const t=table(report,kind);return '# '+t.title+'\n\n'+exportNotes(report).map(escapeMD).join('\n\n')+'\n\n| '+t.headers.map(escapeMD).join(' | ')+' |\n| '+t.headers.map(()=>'---').join(' | ')+' |\n'+t.rows.map(row=>'| '+row.map(escapeMD).join(' | ')+' |').join('\n')+'\n';}
 function html(report,kind='stress'){
  const t=table(report,kind),isBuckling=['euler_column','stringer_blade'].includes(report.failureMode),isReserve=kind==='reserve'||isBuckling,rf=reserveFactors(),scale=isReserve&&rf?rf.scale(report.rows.map(row=>({pid:row.pid,rowKey:row.rowKey,value:row.reserveFactor}))):colorScales(report,'stress');
  const coloredColumn=isBuckling?5:isReserve?4:5,palette=report.palette||(isReserve?'signed':'viridis');
  function cell(text,column,index){
   let style='',inner=escapeHTML(text);const row=report.rows[index],value=isReserve?row.reserveFactor:row.envelopeStress;
   if(column===coloredColumn&&finite(value)){
    if(isReserve&&rf){const background=rf.valueColor(value,scale,palette),ink=rf.valueInk(value,scale,palette);if(background){style=' style="background:'+background+';color:'+ink.color+'"';if(ink.backing)inner='<span style="background:'+ink.backing+';padding:2px 4px;border-radius:2px">'+inner+'</span>';}}
    else if(!isReserve){const color=scale.color(value,palette);if(color)style=' style="background:'+colors.css(color)+';color:'+(color[0]*.299+color[1]*.587+color[2]*.114>.54?'#102436':'#fff')+'"';}
   }
   return '<td'+style+'>'+inner+'</td>';
  }
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>'+t.title+'</title><style>body{font:15px/1.5 system-ui,sans-serif;color:#163047;background:white;margin:2rem}table{border-collapse:collapse;width:100%}td,th{padding:.5rem;border:1px solid #bfd0dd;text-align:left}th{background:#e4eef6}p{max-width:90rem}tr{break-inside:avoid}</style></head><body><h1>'+t.title+'</h1>'+exportNotes(report).map(s=>'<p>'+escapeHTML(s)+'</p>').join('')+'<table><thead><tr>'+t.headers.map(s=>'<th>'+escapeHTML(s)+'</th>').join('')+'</tr></thead><tbody>'+t.rows.map((row,i)=>'<tr>'+row.map((s,j)=>cell(s,j,i)).join('')+'</tr>').join('')+'</tbody></table></body></html>\n';
 }
 function colorScales(report,kind='stress'){const key=kind==='reserve'?'reserveFactor':'envelopeStress';let min=null,max=null,count=0;for(const row of report.rows){const value=row[key];if(!finite(value))continue;min=min===null?value:Math.min(min,value);max=max===null?value:Math.max(max,value);count++;}return{min,max,count,unit:kind==='reserve'?'ratio':report.stressUnit,factor:kind==='reserve'?1:report.stressFactor,color(value,name='spectrum'){if(!finite(value)||min===null)return null;return colors?.valueColor(name,value,min,max)||null;}};}
 return{METHODS,format,analysisNumber,aggregate,percentileValue,caseReason,caseList,stressSample,propertyAllowable,build,table,csv,markdown,html,colorScales,methodLabel};
});
