/* Local elastic instability of a PBARL T stringer's free web. The supported
 * web edge follows the attached flange; the opposite longitudinal edge is
 * free. This is a plate check, independent of the column's Euler end fixity. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingStringerBladeData=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0,validID=n=>Number.isSafeInteger(Number(n))&&Number(n)>0;
 const COEFFICIENT=.425;
 const failure=reason=>({reason});
 const recordAt=(records,eid)=>records instanceof Map?records.get(eid)??records.get(String(eid)):records?.[String(eid)];
 function criticalStress(bar){
  if(bar?.reason)return failure(bar.reason);
  if(bar?.material_type&&bar.material_type!=='MAT1')return failure('The free-web plate equation requires an isotropic MAT1 material.');
  const {young_pa:E,poisson:nu,web_height_m:h,web_thickness_m:t}=bar||{};
  if(!positive(E)||!finite(nu)||nu<=-1||nu>=.5)return failure('A positive isotropic Young modulus and Poisson ratio between -1 and 0.5 are required.');
  if(!positive(h)||!positive(t))return failure('A positive clear web height H minus flange thickness and web thickness are required.');
  // The long-outstand limit omits any finite-length stabilizing correction.
  // No Euler end-fixity coefficient belongs in this local plate equation.
  const value=COEFFICIENT*Math.PI**2/(12*(1-nu*nu))*E*(t/h)**2;
  return positive(value)?{value,coefficient:COEFFICIENT,young:E,poisson:nu,clearHeight:h,thickness:t}:failure('The elastic blade critical stress exceeds the numeric range.');
 }
 function signedMean(values){
  if(!Array.isArray(values)||!values.length||!values.every(finite))return failure('Every bar element must have a finite signed axial stress.');
  const scale=values.reduce((peak,value)=>Math.max(peak,Math.abs(value)),0);
  if(scale===0)return{value:0,compression:0,tolerance:0};
  // Normalize before summing to avoid overflow. Compensation prevents a
  // long bar list from accumulating a fictitious compressive mean at zero.
  let sum=0,correction=0,magnitude=0;
  for(const value of values){const x=value/scale,y=x-correction,next=sum+y;correction=(next-sum)-y;sum=next;magnitude+=Math.abs(x);}
  const value=scale*Math.max(-1,Math.min(1,sum/values.length)),tolerance=scale*(16*Number.EPSILON*magnitude/values.length);
  if(!finite(value))return failure('The mean axial stress exceeds the numeric range.');
  return{value,compression:value < -tolerance?-value:0,tolerance};
 }
 function axialStress(record,sourceUnit){
  const stress=record?.stress;
  if(!stress)return failure('No recovered signed bar axial stress is available.');
  const unit=record.stress_units||sourceUnit||'Pa',unitMatch=/^\s*(Pa|kPa|MPa|GPa)\b/i.exec(unit),factor=unitMatch?({pa:1,kpa:1e3,mpa:1e6,gpa:1e9})[unitMatch[1].toLowerCase()]:null;
  if(factor===null)return failure('The bar axial-stress units cannot be converted to the SI blade material units.');
  const convert=sample=>{if(sample.reason)return sample;const value=sample.value*factor,tolerance=(sample.tolerance??16*Number.EPSILON*Math.abs(sample.value))*factor;return finite(value)&&finite(tolerance)?{value,tolerance}:failure('The bar axial stress exceeds the numeric range after unit conversion.');};
  const hasA=Object.hasOwn(stress,'axial_end_a'),hasB=Object.hasOwn(stress,'axial_end_b');
  if(hasA||hasB){
   if(!hasA||!hasB||!finite(stress.axial_end_a)||!finite(stress.axial_end_b))return failure('Both signed bar endpoint axial stresses must be finite when endpoint recovery is present.');
   return convert(signedMean([stress.axial_end_a,stress.axial_end_b]));
  }
  return finite(stress.axial)?convert({value:stress.axial}):failure('No finite signed bar axial stress is available; equivalent or bending stress is not a substitute.');
 }
 function bladeLocations(blade){
  const skin=blade.skin,bay=Number(blade.rib_bay),stringer=Number(blade.stringer);
  if(!['upper','lower'].includes(skin)||!validID(bay)||!validID(stringer))return[];
  return[{group:skin,rowKey:'stringer:'+stringer,rowLabel:(skin==='upper'?'U':'L')+stringer,index:bay,columnLabel:'R'+bay+'–R'+(bay+1),key:blade.key,cellLabel:'Stringer blade'+(Number(blade.segment)>1?' · segment '+blade.segment:''),part:'stringer_blade',ribs:false,segment:blade.segment??1,stringer,panelId:blade.panel_id,panelKey:blade.key}];
 }
 function assessBlade(blade,cases){
  const bars=Array.isArray(blade.bars)?blade.bars:[],reasons=[],caseResults=[],seen=new Set();
  let baseReason=blade.reason||(!bars.length?'No actual bar elements are available for this stringer blade.':''),critical=null;
  for(const bar of bars){
   const eid=Number(bar.eid),capacity=criticalStress(bar);
   if(!validID(eid))baseReason||='An actual bar element ID is missing or invalid.';
   else if(seen.has(eid))baseReason||='The same bar element occurs more than once in this stringer blade.';
   seen.add(eid);
   if(capacity.reason)baseReason||='Element '+eid+': '+capacity.reason;
   else if(!critical||capacity.value<critical.value)critical={...capacity,eid,pid:Number(bar.pid),materialId:Number(bar.material_id)};
  }
  let recovered=0,governing=null,maximumElementCompression=0,maxEid=null,maxCaseLabel='',maxCaseKey='',allNonCompressive=true;
  for(const item of cases.included){
   const records=item.result.elementResults??item.result.element_results,samples=[];
   for(const bar of bars){
    const eid=Number(bar.eid),sample=baseReason?failure(baseReason):axialStress(recordAt(records,eid),item.result.stress_units);
    if(sample.reason){reasons.push({reason:'Element '+eid+': '+sample.reason,count:1,caseLabel:item.label});continue;}
    samples.push({eid,value:sample.value,tolerance:sample.tolerance});recovered++;
    if(-sample.value>maximumElementCompression){maximumElementCompression=-sample.value;maxEid=eid;maxCaseLabel=item.label;maxCaseKey=item.caseKey;}
   }
   const complete=!baseReason&&samples.length===bars.length&&bars.length>0,mean=complete?signedMean(samples.map(s=>s.value)):failure('Incomplete bar-stress coverage.');
   if(complete&&!mean.reason){mean.tolerance=Math.max(mean.tolerance,signedMean(samples.map(s=>s.tolerance)).value);mean.compression=mean.value < -mean.tolerance?-mean.value:0;}
   const compression=mean.compression??null;
   const ratio=complete&&compression>0?critical.value/compression:null;
   if(complete&&compression>0&&!positive(ratio))reasons.push({reason:'The blade reserve factor exceeds the numeric range.',count:1,caseLabel:item.label});
   const row={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total:Math.max(1,bars.length),recovered:samples.length,averageStress:mean.value??null,compressionDemand:compression,reserveFactor:positive(ratio)?ratio:null,criticalStress:critical?.value??null,criticalEid:critical?.eid??null};
   caseResults.push(row);
   if(complete&&compression>0){allNonCompressive=false;if(positive(ratio)&&(!governing||ratio<governing.reserveFactor))governing=row;}
  }
  if(baseReason&&!reasons.length)reasons.push({reason:baseReason,count:1,caseLabel:''});
  const complete=!baseReason&&cases.complete&&caseResults.length>0&&caseResults.every(c=>c.recovered===c.total&&(c.compressionDemand===0||positive(c.reserveFactor))),noCompression=complete&&allNonCompressive;
  const reserveFactor=complete?(noCompression?99:governing?.reserveFactor??null):null;
  const reserveFactorReason=baseReason||(!complete?'Incomplete case or signed bar-stress coverage; blade reserve factor is not assessed.':reserveFactor===null?'No finite blade reserve factor is available.':'');
  const selected=governing||caseResults.reduce((a,b)=>a===null||(finite(b.averageStress)&&b.averageStress<a.averageStress)?b:a,null),materialIds=[...new Set(bars.map(b=>Number(b.material_id)).filter(validID))],total=Math.max(1,bars.length)*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length);
  const note=noCompression?'RF 99 means no included case has a compressive average bar axial stress after complete recovery. Individual elements may still be compressed; 99 is a display sentinel, not a calculated failure multiplier.':'';
  return{rowKey:'blade:'+blade.key,panelKey:blade.key,panelId:blade.panel_id,pid:Number(blade.pid),label:blade.label||('P'+blade.panel_id+' · '+(blade.skin==='upper'?'Upper':'Lower')+' stringer '+blade.stringer+' · R'+blade.rib_bay+'–R'+(Number(blade.rib_bay)+1)),names:['Stringer blade instability'],propertyType:'PBARL T free web',materialIds,locations:bladeLocations(blade),elementCount:bars.length,
   maxStress:maximumElementCompression,maxCaseLabel,maxCaseKey,maxEid,maxFace:null,envelopeStress:governing?.compressionDemand??(noCompression?0:null),envelopeCaseLabel:governing?.label||'',envelopeCaseKey:governing?.caseKey||'',envelopeEid:null,allowableStress:critical?.value??null,
   reserveFactor,reserveFactorReason,complete,status:complete?'complete':recovered?'partial':'unavailable',coverage:{recovered,total},caseResults,reasons,
   blade:{criticalStress:critical?.value??null,compressionDemand:governing?.compressionDemand??(noCompression?0:null),averageStress:selected?.averageStress??null,clearHeight:critical?.clearHeight??null,thickness:critical?.thickness??null,poisson:critical?.poisson??null,young:critical?.young??null,coefficient:COEFFICIENT,sourceCount:bars.length,noCompression,criticalEid:critical?.eid??null,criticalPid:critical?.pid??null,governingCase:governing?.label||'',note}};
 }
 const NOTE='Stringer blade instability: elastic long-outstand plate stress σcr = 0.425 × π² E / [12 (1 − ν²)] × (tw / h)², with clear web height h = overall T height minus attached-flange thickness. One longitudinal edge is simply supported at the attached flange and the other is free. The conservative long-plate coefficient includes no finite-length stabilizing correction and is independent of Euler column end fixity. Only actual isotropic PBARL T bars are assessed. Each bar contributes its signed axial stress (tension positive); if two signed axial endpoint stresses are present, their mean is used first. The bay or segment demand is the arithmetic mean of these element stresses with equal element weights, not length or area weights. Bending peaks, equivalent stress and skin stress are not substituted. The lowest local critical stress is used if bar section or material varies. RF is critical stress divided by the magnitude of compressive mean stress, then the lowest ratio across current SOL101 and fully converged SOL106 cases governs. RF 99 means no average compression in any fully recovered included case; individual elements may still be compressed. Missing, stale or incomplete recovery is unassessed. This is an elastic local plate screening check, not a prediction of plastic crippling, coupled local/global buckling or nonlinear failure load. Stress percentile trimming and Euler fixity do not apply.';
 function build(input,cases){
  const blades=Array.isArray(input.stringerBlades)?input.stringerBlades:[],rows=blades.map(blade=>assessBlade(blade,cases));
  return{failureMode:'stringer_blade',rows,includedCases:cases.included.map(({result,...item})=>item),excludedCases:cases.excluded.map(({result,...item})=>item),missingCases:cases.missing,method:'mean',percentile:100,stressUnit:'MPa',stressFactor:1e-6,lengthUnit:'m',complete:cases.complete&&rows.length>0&&rows.every(row=>row.complete),coverage:{recovered:rows.reduce((a,r)=>a+r.coverage.recovered,0),total:rows.reduce((a,r)=>a+r.coverage.total,0),properties:rows.length},note:NOTE+(!blades.length?' No generated PBARL T stringer-blade geometry is available for the current model.':'')};
 }
 return{COEFFICIENT,criticalStress,signedMean,axialStress,bladeLocations,assessBlade,build,NOTE};
});
