/* Compact buckling results are complete scalar results, with no shape vectors. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingBucklingOutputs=api;})(globalThis,function(){
 'use strict';
 function listText(values,empty){return values.length?values.slice(0,8).join(', ')+(values.length>8?' … ('+values.length+' total)':''):empty;}
 function render(host,result,{format=String}={}){
  host.replaceChildren();host.hidden=!result?.compactBuckling;if(host.hidden)return;
  const doc=host.ownerDocument,heading=doc.createElement('h3');heading.textContent='Buckling eigenvalues and peak-node properties';host.append(heading);
  if(typeof WingResultDisplay!=='undefined'&&WingResultDisplay.bucklingHelp){heading.textContent+=' ⓘ';heading.title=WingResultDisplay.bucklingHelp();}
  const note=doc.createElement('p');note.className='pick-note';note.textContent=result.message||'Compact SOL105 output intentionally omits mode vectors and preload fields. Disable compact output and rerun to view deformations and contours.';host.append(note);
  const table=doc.createElement('table'),head=doc.createElement('tr');
  for(const title of ['Root','Load factor λ','Peak GRID IDs','Incident property IDs']){const cell=doc.createElement('th');cell.textContent=title;head.append(cell);}table.append(head);
  for(const row of result.bucklingRoots||[]){
   const peak=row.peak_translation,nodes=peak?.nodes||[],properties=peak?.property_ids||[...new Set(nodes.flatMap(node=>node.property_ids||[]))];
   const tr=doc.createElement('tr');
   const nodeIds=nodes.map(node=>node.node_id);
   for(const [value,full] of [[row.mode,''],[format(row.load_factor??row.eigenvalue),''],[listText(nodeIds,'Not reported'),nodeIds.join(', ')],[listText(properties,'None reported'),properties.join(', ')]]){const cell=doc.createElement('td');cell.textContent=String(value);if(full)cell.title=full;tr.append(cell);}
   tr.title='Preload subcase '+row.static_subcase_id+'; buckling subcase '+row.buckling_subcase_id+'. Peak uses Euclidean translation only. PIDs belong to elements directly attached to every tied maximum GRID; relative tie tolerance '+(peak?.relative_tolerance??'not reported')+'. '+(peak?.normalization||'Eigenvector amplitude is arbitrary.');table.append(tr);
  }
  host.append(table);
  if(!result.bucklingRoots?.length){const empty=doc.createElement('p');empty.textContent='No buckling roots were exported in the requested search interval.';host.append(empty);}
 }
 return {render};
});
