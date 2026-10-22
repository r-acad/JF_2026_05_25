/* Elastic column checks for actual stringer/tributary-skin cross-sections.
 * Geometry, material axes and force ownership come from the generated mesh.
 * Nothing is inferred from a property number or from a von Mises contour. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingEulerColumnData=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0;
 const failure=reason=>({reason});
 const recordsOf=result=>result?.elementResults??result?.element_results;
 const recordAt=(records,eid)=>records instanceof Map?records.get(eid)??records.get(String(eid)):records?.[String(eid)];
 function matrixPart(p){
  const k=p.axial_matrix;
  if(!Array.isArray(k)||k.length!==3||!k.every(r=>Array.isArray(r)&&r.length===3&&r.every(finite))||!positive(k[0][0])||!positive(p.area_m2))return failure('The coupled section law is missing a finite positive axial stiffness or physical area.');
  for(let i=0;i<3;i++)for(let j=0;j<i;j++)if(Math.abs(k[i][j]-k[j][i])>16*Number.EPSILON*Math.max(Math.abs(k[i][j]),Math.abs(k[j][i])))return failure('The coupled section law is not symmetric.');
  const EA=k[0][0],y=k[0][1]/EA,z=k[0][2]/EA;
  // K uses [extension, d(extension)/dy, d(extension)/dz]. Eliminating
  // extension retains the full laminate extension/bending coupling; it is
  // equivalent to shifting each part to its elastic neutral axis before
  // assembling the whole section. Parts are not condensed independently
  // and then simply added: the parallel-axis terms below retain coupling.
  const EIzz=k[1][1]-k[0][1]*y,EIyy=k[2][2]-k[0][2]*z,EIyz=.5*(k[1][2]+k[2][1])-k[0][1]*z;
  if(![y,z,EIyy,EIzz,EIyz].every(finite)||EIyy<0||EIzz<0)return failure('The coupled section law is not positive semidefinite after eliminating extension.');
  const scale=Math.max(EIyy,EIzz,Math.abs(EIyz));
  if(scale>0&&(EIyy/scale)*(EIzz/scale)-(EIyz/scale)**2 < -16*Number.EPSILON)return failure('The coupled section law has an indefinite reduced bending matrix.');
  return{A:p.area_m2,y,z,EIyy,EIzz,EIyz,EA};
 }
 // iyy = integral(z^2 dA), izz = integral(y^2 dA), iyz = integral(y*z dA),
 // all about each part's own centroid and in one common section frame.
 function section(parts){
  if(!Array.isArray(parts)||!parts.length)return failure('No current cross-section parts are available.');
  const items=[];let maxEA=0;
  for(const p of parts){
   if(p?.reason)return failure(p.reason);
   if(p?.axial_matrix!==undefined){const item=matrixPart(p);if(item.reason)return item;maxEA=Math.max(maxEA,item.EA);items.push(item);continue;}
   const {area_m2:A,centroid_y_m:y,centroid_z_m:z,iyy_m4:Iyy,izz_m4:Izz,iyz_m4:Iyz=0,young_pa:E}=p||{};
   if(!positive(A)||!positive(E)||![y,z,Iyy,Izz,Iyz].every(finite)||Iyy<0||Izz<0)return failure('Cross-section area, centroid, isotropic modulus or centroidal inertia is unavailable or invalid.');
   const scale=Math.max(Iyy,Izz,Math.abs(Iyz));
   if(scale>0&&(Iyy/scale)*(Izz/scale)-(Iyz/scale)**2 < -16*Number.EPSILON)return failure('A cross-section part has an invalid inertia tensor.');
   const EA=E*A;if(!positive(EA))return failure('Cross-section axial stiffness exceeds the numeric range.');
   maxEA=Math.max(maxEA,EA);items.push({A,y,z,EIyy:E*Iyy,EIzz:E*Izz,EIyz:E*Iyz,EA});
  }
  const weights=items.map(p=>p.EA/maxEA),weight=weights.reduce((a,b)=>a+b,0);
  const cy=items.reduce((a,p,i)=>a+weights[i]*p.y,0)/weight,cz=items.reduce((a,p,i)=>a+weights[i]*p.z,0)/weight;
  let EIyy=0,EIzz=0,EIyz=0,area=0;
  for(const p of items){const dy=p.y-cy,dz=p.z-cz;EIyy+=p.EIyy+p.EA*dz*dz;EIzz+=p.EIzz+p.EA*dy*dy;EIyz+=p.EIyz+p.EA*dy*dz;area+=p.A;}
  const axialStiffness=maxEA*weight;
  if(![cy,cz,EIyy,EIzz,EIyz,area,axialStiffness].every(finite))return failure('Cross-section stiffness exceeds the numeric range.');
  const scale=Math.max(EIyy,EIzz,Math.abs(EIyz));if(!positive(scale))return failure('The cross-section has no positive bending stiffness.');
  const a=EIyy/scale,d=EIzz/scale,b=EIyz/scale,major=(a+d+Math.hypot(a-d,2*b))/2;
  // det / lambda_max avoids subtracting nearly equal principal values for a
  // slender blade. The section is not assigned fictitious minimum stiffness.
  const weakestEI=scale*((a*d-b*b)/major);
  if(!positive(weakestEI))return failure('The weakest cross-section bending stiffness is zero, singular or numerically unresolved.');
  return{area,axialStiffness,centroidY:cy,centroidZ:cz,EIyy,EIzz,EIyz,weakestEI,materialIds:[...new Set(parts.flatMap(p=>[p.material_id,...(p.material_ids||[])]).map(Number).filter(n=>Number.isSafeInteger(n)&&n>0))]};
 }
 function criticalLoad(stiffness,length,endFactor=1){
  endFactor??=1;
  if(!positive(length))return failure('A positive full rib-to-rib unbraced length is required.');
  if(!positive(endFactor))return failure('The Euler end-fixity coefficient must be a finite positive number.');
  if(!positive(stiffness))return failure('A positive weakest-axis bending stiffness is required.');
  const value=endFactor*Math.PI*Math.PI*(stiffness/length)/length;
  return positive(value)?{value}:failure('The Euler critical load exceeds the numeric range.');
 }
 function forceTerm(term,records){
  if(term?.reason)return failure(term.reason);
  const eid=Number(term?.eid);if(!Number.isSafeInteger(eid)||eid<=0)return failure('An axial-force source element is not identified.');
  const forces=recordAt(records,eid)?.forces;if(!forces)return failure('Element '+eid+' has no recovered force resultants.');
  if(term.kind==='beam_axial')return finite(forces.axial)?{value:forces.axial,eid}:failure('Element '+eid+' has no finite signed beam axial force.');
  if(term.kind!=='shell_membrane')return failure('Element '+eid+' uses an unsupported axial-force recovery definition.');
  const c=term.coefficients;
  if(!Array.isArray(c)||c.length!==3||!c.every(finite)||!positive(term.width_m))return failure('Element '+eid+' has no valid shell-to-column projection or tributary width.');
  const source=[forces.fx,forces.fy,forces.fxy];
  if(!source.every(finite))return failure('Element '+eid+' is missing signed shell membrane resultants.');
  const value=source.reduce((sum,n,i)=>sum+c[i]*n,0)*term.width_m;
  return finite(value)?{value,eid}:failure('Element '+eid+' axial resultant exceeds the numeric range.');
 }
 function axialForce(terms,records){
  if(!Array.isArray(terms)||!terms.length)return failure('The cross-section has no identified axial-force sources.');
  let sum=0,magnitude=0;const beamIDs=new Set();
  for(const term of terms){
   if(term.kind==='beam_axial'){if(beamIDs.has(Number(term.eid)))return failure('The same beam axial force is assigned more than once to this section.');beamIDs.add(Number(term.eid));}
   const value=forceTerm(term,records);if(value.reason)return value;sum+=value.value;magnitude+=Math.abs(value.value);
  }
  if(!finite(sum)||!finite(magnitude))return failure('The combined axial resultant exceeds the numeric range.');
  // Only cancellation-scale roundoff is ignored. A truly small compressive
  // load remains compression: there is deliberately no absolute force floor.
  const tolerance=16*Number.EPSILON*magnitude,compression=sum < -tolerance?-sum:0;
  return{signedForce:sum,compression,tolerance};
 }
 function columnLocations(column){
  const skin=column.skin,bay=Number(column.rib_bay),stringer=Number(column.stringer);
  if(!['upper','lower'].includes(skin)||!Number.isSafeInteger(bay)||bay<=0||!Number.isSafeInteger(stringer)||stringer<=0)return[];
  return[{group:skin,rowKey:'stringer:'+stringer,rowLabel:(skin==='upper'?'U':'L')+stringer,index:bay,columnLabel:'R'+bay+'–R'+(bay+1),key:column.key,cellLabel:'P'+column.panel_id+' · Stringer column',part:'stringer_column',ribs:false,segment:column.segment??1,stringer,panelId:column.panel_id,panelKey:column.key}];
 }
 function assessColumn(column,cases,{endFactor}={}){
  const length=column.length_m,c=endFactor??column.fixity_coefficient??1,stations=Array.isArray(column.stations)?column.stations:[],reasons=[],caseResults=[];
  const baseReason=column.reason||(!positive(c)?'The Euler end-fixity coefficient must be a finite positive number.':'')||(!positive(length)?'A positive full rib-to-rib unbraced length is required.':'')||(!stations.length?'No physical cross-section cuts are available.':'');
  const prepared=stations.map((station,index)=>{const stiffness=section(station.parts),critical=stiffness.reason?stiffness:criticalLoad(stiffness.weakestEI,length,c);return{station,index,stiffness,critical,reason:station.reason||critical.reason||''};});
  let governing=null,recovered=0,maximumCompression=0,allNonCompressive=true;
  for(const item of cases.included){
   const records=recordsOf(item.result),samples=[];let caseGoverning=null;
   for(const p of prepared){
    const force=baseReason||p.reason?failure(baseReason||p.reason):axialForce(p.station.force_terms,records);
    if(force.reason){reasons.push({reason:force.reason,count:1,caseLabel:item.label,station:p.station.id??p.index+1});continue;}
    recovered++;maximumCompression=Math.max(maximumCompression,force.compression);allNonCompressive&&=force.compression===0;
    const rf=force.compression>0?p.critical.value/force.compression:null;
    const sample={station:p.station.id??p.index+1,stationIndex:p.index,criticalLoad:p.critical.value,compressionDemand:force.compression,signedForce:force.signedForce,reserveFactor:finite(rf)?rf:null,weakestEI:p.stiffness.weakestEI,area:p.stiffness.area,centroidY:p.stiffness.centroidY,centroidZ:p.stiffness.centroidZ};
    if(force.compression>0&&!positive(rf)){reasons.push({reason:'The Euler reserve factor exceeds the numeric range.',count:1,caseLabel:item.label,station:sample.station});recovered--;continue;}
    samples.push(sample);if(rf!==null&&(!caseGoverning||rf<caseGoverning.reserveFactor))caseGoverning=sample;
   }
   const result={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total:Math.max(1,stations.length),recovered:samples.length,stations:samples,reserveFactor:caseGoverning?.reserveFactor??null,governingStation:caseGoverning?.station??null};caseResults.push(result);
   if(caseGoverning&&(!governing||caseGoverning.reserveFactor<governing.reserveFactor))governing={...caseGoverning,caseKey:item.caseKey,caseLabel:item.label};
  }
  if(baseReason&&!reasons.length)reasons.push({reason:baseReason,count:1,caseLabel:''});
  const complete=!baseReason&&cases.complete&&caseResults.length>0&&caseResults.every(c=>c.recovered===c.total),noCompression=complete&&allNonCompressive;
  const reserveFactor=complete?(noCompression?99:governing?.reserveFactor??null):null;
  const reserveFactorReason=baseReason||(!complete?'Incomplete case or section-force coverage; Euler reserve factor is not assessed.':reserveFactor===null?'No finite Euler reserve factor is available.':'');
  const selected=governing||caseResults.flatMap(r=>r.stations.map(s=>({...s,caseKey:r.caseKey,caseLabel:r.label}))).reduce((best,s)=>!best||s.criticalLoad<best.criticalLoad?s:best,null);
  const materialIds=[...new Set(prepared.flatMap(p=>p.stiffness.materialIds||[]))],total=Math.max(1,stations.length)*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length);
  return{rowKey:'euler:'+column.key,panelKey:column.key,panelId:column.panel_id,pid:Number(column.pid),label:column.label||('P'+column.panel_id+' · '+(column.skin==='upper'?'Upper':'Lower')+' stringer '+column.stringer+' · R'+column.rib_bay+'–R'+(Number(column.rib_bay)+1)),names:['Euler stringer column'],propertyType:'Stringer + effective skin',materialIds,locations:columnLocations(column),elementCount:new Set(stations.flatMap(s=>(s.force_terms||[]).map(t=>t.eid))).size,
   maxStress:null,maxCaseLabel:'',maxCaseKey:'',maxEid:null,maxFace:null,envelopeStress:null,envelopeCaseLabel:governing?.caseLabel||'',envelopeCaseKey:governing?.caseKey||'',envelopeEid:null,allowableStress:null,
   reserveFactor,reserveFactorReason,complete,status:complete?'complete':recovered?'partial':'unavailable',coverage:{recovered,total},caseResults,reasons,
   euler:{criticalLoad:selected?.criticalLoad??null,compressionDemand:governing?.compressionDemand??(noCompression?0:null),maximumCompression,weakestEI:selected?.weakestEI??null,length,endFactor:c,governingCase:governing?.caseLabel||'',governingStation:governing?.station??null,noCompression,area:selected?.area??null,centroidY:selected?.centroidY??null,centroidZ:selected?.centroidZ??null,stationCount:stations.length,note:noCompression?'RF 99 denotes no compression in any fully recovered included load case; it is not a computed failure load multiplier.':''}};
 }
 const NOTE='Euler stringer-column check: Pcr = c × π² × (EI)min / L², with c = 1 for pinned ends. Each actual mesh cut includes the stringer and half of the neighboring skin panel on each side, using current thickness and section offsets. Isotropic parts use their Young moduli. Validated laminate strip laws retain the rotated membrane/bending coupling: the complete section stiffness is assembled, free axial extension is eliminated by a Schur complement, and the weakest principal bending stiffness is used. Oblique sheets use the stated axial-energy projection approximation. Signed beam axial force and projected shell membrane resultants are combined at the same section; consecutive elements along the span are never summed. The lowest Pcr / compressive resultant across cuts and SOL101/SOL106 load cases governs. Local stiffness with the full rib-to-rib length is an approximate elastic column check for a varying or curved member, not a local plate, crippling or nonlinear buckling solution. Unsupported or nonpositive section laws are unassessed. RF 99 means every included case was fully recovered and none was compressive; missing or stale results never receive 99. This mode does not apply stress averaging or percentile trimming.';
 function build(input,cases){
  const columns=Array.isArray(input.eulerColumns)?input.eulerColumns:[],rows=columns.map(column=>assessColumn(column,cases,{endFactor:input.eulerFixityCoefficient??input.eulerEndFactor}));
  return{failureMode:'euler_column',rows,includedCases:cases.included.map(({result,...item})=>item),excludedCases:cases.excluded.map(({result,...item})=>item),missingCases:cases.missing,method:'maximum',percentile:100,stressUnit:input.sourceUnits?'source stress units':'MPa',stressFactor:input.sourceUnits?1:1e-6,forceUnit:input.sourceUnits?'source force units':'N',forceFactor:1,lengthUnit:input.sourceUnits?'source length units':'m',complete:cases.complete&&rows.length>0&&rows.every(row=>row.complete),coverage:{recovered:rows.reduce((a,r)=>a+r.coverage.recovered,0),total:rows.reduce((a,r)=>a+r.coverage.total,0),properties:rows.length},note:NOTE+(!columns.length?' No generated stringer-column geometry is available for the current model.':'')};
 }
 return{matrixPart,section,criticalLoad,forceTerm,axialForce,columnLocations,assessColumn,build,NOTE};
});
