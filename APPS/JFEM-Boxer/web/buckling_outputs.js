/* Compact buckling results are complete scalar results, with no shape vectors. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./assessment_load_policy.js'):root.WingAssessmentLoadPolicy);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingBucklingOutputs=api;})(globalThis,function(policy){
 'use strict';
 function policyReserveFactor(multiplier,input={}){
  const p=policy.read(input);
  return Number.isFinite(multiplier)&&multiplier>0?multiplier/p.bucklingPolicyFactor:null;
 }
 function listText(values,empty){return values.length?values.slice(0,8).join(', ')+(values.length>8?' … ('+values.length+' total)':''):empty;}
 function render(host,result,{format=String,assessmentPolicy}={}){
  const full=result?.modeKind==='buckling'&&result.modes?.length;
  host.replaceChildren();host.hidden=!result?.compactBuckling&&!full;if(host.hidden)return;
  host.classList.add('buckling-policy-results');
  let policyValue,policyError='';try{policyValue=policy.read({assessmentPolicy});}catch(error){policyError=error.message;}
  const doc=host.ownerDocument,heading=doc.createElement('h3');heading.textContent=result.compactBuckling?'Buckling eigenvalues, policy RFs and peak-node properties':'Buckling eigenvalues and policy RFs';host.append(heading);
  if(typeof WingResultDisplay!=='undefined'&&WingResultDisplay.bucklingHelp){heading.textContent+=' ⓘ';heading.title=WingResultDisplay.bucklingHelp();}
  const note=doc.createElement('p');note.className='pick-note';note.textContent=(result.compactBuckling?(result.message||'Compact SOL105 output omits mode vectors and preload fields. Disable compact output and rerun to view shapes.')+' ':'')+(policyError||'The analyzed complete preload is the LIMIT basis, including its case multiplier. Buckling-policy RF = λ / '+policyValue.bucklingPolicyFactor+'. Raw eigenvalues are unchanged; the strength safety factor does not enter this check. RF values above 999 display as 999.');host.append(note);
  const table=doc.createElement('table'),head=doc.createElement('tr');table.className='buckling-policy-table'+(result.compactBuckling?' compact':'');
  for(const title of ['Root','Load factor λ','Buckling-policy RF',...(result.compactBuckling?['Peak GRID IDs','Incident property IDs']:[])]){const cell=doc.createElement('th');cell.textContent=title;head.append(cell);}table.append(head);
  const roots=result.compactBuckling?result.bucklingRoots||[]:result.modes.map(row=>({...row,load_factor:row.loadFactor}));
  for(const row of roots){
   const peak=row.peak_translation,nodes=peak?.nodes||[],properties=peak?.property_ids||[...new Set(nodes.flatMap(node=>node.property_ids||[]))];
   const tr=doc.createElement('tr');
   const nodeIds=nodes.map(node=>node.node_id);
   const factor=row.load_factor??row.eigenvalue,rf=policyError?null:policyReserveFactor(factor,{assessmentPolicy:policyValue});
   const cells=[[row.mode,''],[format(factor),''],[rf===null?'Unavailable':format(Math.min(999,rf)),rf===null?policyError:'Critical load / (LIMIT load × buckling policy factor). Uncapped RF: '+rf],...(result.compactBuckling?[[listText(nodeIds,'Not reported'),nodeIds.join(', ')],[listText(properties,'None reported'),properties.join(', ')]]:[])];
   for(const [value,full] of cells){const cell=doc.createElement('td');cell.textContent=String(value);if(full)cell.title=full;tr.append(cell);}
   tr.title=result.compactBuckling?'Preload subcase '+row.static_subcase_id+'; buckling subcase '+row.buckling_subcase_id+'. Peak uses Euclidean translation only. PIDs belong to elements directly attached to every tied maximum GRID; relative tie tolerance '+(peak?.relative_tolerance??'not reported')+'. '+(peak?.normalization||'Eigenvector amplitude is arbitrary.'):'The raw eigenvalue multiplies the complete solved LIMIT preload. Mode amplitude is arbitrary; policy RF is a separate assessment.';table.append(tr);
  }
  host.append(table);
  if(!roots.length){const empty=doc.createElement('p');empty.textContent='No buckling roots were exported in the requested search interval.';host.append(empty);}
 }
 return {render,policyReserveFactor};
});
