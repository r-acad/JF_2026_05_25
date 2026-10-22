/* Retained table assessments keep their solved model and recovery together. */
(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory(require('./stress_report_data.js'));
 else root.WingStressReportSnapshot=factory(root.WingStressReportData);
})(globalThis,function(data){
 'use strict';
 const entries=value=>value instanceof Map?[...value]:Array.isArray(value)?value.map((item,index)=>[item?.id??index,item]):Object.entries(value||{});
 function copy(value){
  if(value instanceof Map)return new Map([...value].map(([key,item])=>[key,copy(item)]));
  if(Array.isArray(value))return value.map(copy);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,copy(item)]));
  return value;
 }
 function copyCases(value){
  const seen=new Map();
  function record(item){
   if(!item||typeof item!=='object')return item;
   if(seen.has(item))return seen.get(item);
   const result={...item};seen.set(item,result);
   // Recovery arrays and displacements are immutable once published. Case
   // eligibility is mutable: buildModel updates matches on the live records.
   if(item.convergence)result.convergence=copy(item.convergence);
   if(item.validationIssues)result.validationIssues=copy(item.validationIssues);
   if(item.variants)result.variants=new Map(entries(item.variants).map(([key,variant])=>[key,record(variant)]));
   return result;
  }
  return new Map(entries(value).map(([key,item])=>[key,record(item)]));
 }
 function copyElements(value){
  const groups=new Map();
  function group(item){
   if(!item||typeof item!=='object')return item;
   if(!groups.has(item))groups.set(item,{...item,properties:copy(item.properties)});
   return groups.get(item);
  }
  // disposeModel clears the live Map in place. Keep a separate registry and
  // property descriptions; large connectivity buffers can remain shared.
  return new Map(entries(value).map(([key,item])=>[key,{...item,group:group(item?.group)}]));
 }
 function snapshot(context){
  const result={...context,elements:copyElements(context.elements),cases:copyCases(context.cases),modelDirty:false,pendingDrafts:false,running:false};
  for(const key of ['allowables','componentFixities','expectedCases','caseLabels'])result[key]=copy(context[key]);
  // Generated panel/column metadata are replaced, not edited, during mesh
  // generation. Retain those immutable objects to avoid duplicating the mesh.
  return result;
 }
 const same=(a,b)=>!!a&&a.length===b.length&&a.every((item,index)=>Object.is(item,b[index]));
 function stamp(context){
  const small=JSON.stringify({allowables:context.allowables,componentFixities:context.componentFixities,expectedCases:context.expectedCases,
   caseLabels:entries(context.caseLabels),eulerFixity:context.eulerFixityCoefficient,eulerEndFactor:context.eulerEndFactor,skinFixity:context.skinFixityCoefficient,
   generated:context.generated,sourceUnits:context.sourceUnits,layoutToken:context.layoutToken??context.layout_token},(_,value)=>typeof value==='number'&&!Number.isFinite(value)?String(value):value);
  const values=[context.studyEpoch,context.signature,context.meshIdentity,context.elements,context.cases,context.panels,context.componentGroups,
   context.eulerColumns,context.stringerBlades,context.skinBucklingPanels,context.componentBuckling,small];
  for(const[id,parent]of entries(context.cases)){
   values.push(id,parent,parent?.analysis,parent?.analysis_type,parent?.solution,parent?.modeKind);
   const variants=entries(parent?.variants);
   for(const[key,result]of variants.length?variants:[['default',parent]])values.push(key,result,result?.elementResults,result?.element_results,
    result?.analysis,result?.analysis_type,result?.solution,result?.available,result?.status,result?.matches,result?.historical,result?.static,
    result?.signature,result?.meshIdentity,result?.loadScale,JSON.stringify(result?.convergence),JSON.stringify(result?.validationIssues));
  }
  return values;
 }
 function create(){
  let retained=null,source=null,previous=null,epoch,initialized=false;
  function reset(){retained=null;source=null;previous=null;epoch=undefined;initialized=false;}
  function select(current={}){
   if(!initialized||!Object.is(epoch,current.studyEpoch)){reset();epoch=current.studyEpoch;initialized=true;}
   const eligible=!current.modelDirty&&!current.pendingDrafts&&!current.running&&data?.caseList({...current,caseId:'all'}).included.length>0;
   if(eligible){
    const next=stamp(current);
    if(!same(previous,next)){
     retained=snapshot(current);previous=next;
     source={studyEpoch:current.studyEpoch,signature:current.signature,meshIdentity:current.meshIdentity,capturedAt:new Date().toISOString(),
      layoutToken:current.layoutToken??current.layout_token,panels:retained.panels||[],componentGroups:retained.componentGroups||[],generated:retained.generated===true};
    }
    // Live reports must keep the original geometry references so the strict
    // currentContext check remains valid for current 3D field requests.
    return{context:current,stale:false,message:'',source};
   }
   const mismatch=retained&&(current.modelDirty||current.pendingDrafts||current.running||current.signature!==source.signature||current.meshIdentity!==source.meshIdentity);
   // An unsuccessful or missing current case is a real coverage gap. Do not
   // replace that gap with an older passing result from the same solved model.
   if(!mismatch)return{context:current,stale:false,message:'',source:null};
   const reason=current.running?'An analysis is running.':current.pendingDrafts?'The Study has an unfinished property edit.':
    current.modelDirty||current.signature!==source.signature||current.meshIdentity!==source.meshIdentity?'Previous analysis retained.':
    'No current completed analysis is available.';
   return{context:retained,stale:true,source,message:'Model and results are not in sync. '+reason+' You can continue editing properties. These tables retain the previous assessment, including its model properties, load cases, material allowables and fixity coefficients. They do not describe the edited model. Rerun the analysis for updated reserve factors.'};
  }
  return{select,reset};
 }
 return{create};
});
