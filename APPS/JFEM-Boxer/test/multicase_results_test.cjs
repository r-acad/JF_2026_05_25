'use strict';
// Exercise the actual result decoder, result loader and polling lifecycle.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const study={'loads.cases':'[{"id":2,"label":"Same loads"}]','loads.fuel_fill_fraction':0.7};
const signature=JSON.stringify(study),state={data:{nodes:{count:1}},modelSignature:signature,jobSignature:signature,values:study,activeCase:1,jobId:'job-a',polling:true,pollTimer:null,logCursor:0};
const logs=[],announcements=[],controls=new Map(),timers=[];
const context={state,performance,console,Map,Float32Array,Int32Array,Number,
  formSignature:JSON.stringify,asF32:Float32Array.from.bind(Float32Array),asI32:Int32Array.from.bind(Int32Array),permute:v=>v,
  WingImportedAnalysis:require('../web/imported_analysis.js'),WingRunTimings:{entries:()=>[]},
  document:{getElementById:id=>{if(!controls.has(id))controls.set(id,{});return controls.get(id);}},
  activity:()=>({begin(){},update(){},end(){},announce:(title,options)=>announcements.push({title,...options})}),
  log:(text,kind)=>logs.push({text,kind}),logBatch:entries=>logs.push(...entries),paintActivity:async()=>{},
  selectLoadCase:id=>{state.activeCase=id;const record=state.resultCases.get(id);state.results=record?.variants?record.variants.values().next().value:record;},
  badge(){},solverActivity(){},meshStatus(){},setBusy(){},activateWorkspaceTab(){},
  clearTimeout(){},setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length;},readError:async res=>res.message,
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('async function pollJfem()'),source.indexOf('/* --- Babylon scene')),context);
const effective=fill=>({...study,'loads.cases':'[]','loads.fuel_fill_fraction':fill});
const row=(id,fill=0.7)=>({id,label:'Case '+id,node_count:1,analysis_type:'SOL101_STATIC',source_model_params:study,model_params:effective(fill),static:{disp:[0,0,typeof id==='number'?id:1],max_disp:1},modes:[]});
const envelope=(rows=[row(1),row(2)])=>({node_count:1,source_model_params:study,model_params:study,load_cases:rows});
let payload=envelope(),checks=0;
context.decodePayload=async()=>payload;
const response=()=>({ok:true,arrayBuffer:async()=>new ArrayBuffer(8)});
context.fetch=async()=>response();
(async()=>{
  // Full Study provenance, rather than effective case loads, identifies the
  // mesh. Repeating identical cases must preserve both result records.
  for(let run=0;run<2;run++){
    assert.equal(await context.loadJfemResults(),true);assert.equal(state.resultCases.size,2);
    for(const id of [1,2])assert(state.resultCases.get(id).matches);
    assert.deepEqual(Array.from(state.resultCases.get(2).static.disp),[0,0,2]);checks++;
  }
  payload=envelope([row(1),{...row(2,0.2),variants:[{...row('sol101',0.2),variant_id:'sol101'},{...row('sol106',0.2),variant_id:'sol106'}]}]);
  assert(await context.loadJfemResults());assert(state.resultCases.get(2).variants.get('sol106').matches);
  assert.equal(state.resultCases.get(2).modelParams['loads.fuel_fill_fraction'],0.2);checks++;
  // Neither an envelope nor a child may claim a different Study, even if
  // node counts match. Imported decks retain their independent identity.
  for(const [child,parent] of [[{source_model_params:{other:1}},{}],[{},{source_model_params:{other:1}}],[{imported_signature:'foreign'},{}]]){
    const result=context.decodeResultCase({...row(1),...child},{...envelope(),...parent},signature);
    assert(!result.matches);assert(result.validationIssues.some(reason=>/source parameters/.test(reason)));checks++;
  }
  assert(!context.decodeResultCase(row(1),envelope(),'old study').matches);checks++;
  assert(!context.decodeResultCase({...row(1),node_count:2,static:null},envelope(),signature).matches);checks++;
  const legacy={...row(1),model_params:study};delete legacy.source_model_params;
  assert(context.decodeResultCase(legacy,{node_count:1,model_params:study},signature).matches);
  assert(!context.decodeResultCase({...legacy,model_params:effective(0.2)},{node_count:1,model_params:study},signature).matches);checks++;
  state.importedDeck={signature:'deck-a',solution:'101',cases:[{id:1}]};
  assert(context.decodeResultCase({...row(1),imported_signature:'deck-a'},{node_count:1,imported_signature:'deck-a'},signature).matches);
  assert(!context.decodeResultCase({...row(1),imported_signature:'deck-b'},{node_count:1,imported_signature:'deck-a'},signature).matches);state.importedDeck=null;checks++;
  payload=envelope([{...row(1),source_model_params:{stale:1}}]);logs.length=0;
  assert.equal(await context.loadJfemResults(),false);assert.match(state.resultReadError,/no results compatible/);
  assert(logs.some(entry=>/Case 1.*source parameters/.test(entry.text)));assert(!logs.some(entry=>entry.kind==='good'));checks++;
  payload=envelope([{...row(1),available:false,message:'Matrix factorization failed: unconstrained node 42.'}]);logs.length=0;
  assert.equal(await context.loadJfemResults(),false);assert(logs.some(entry=>/unconstrained node 42/.test(entry.text)));checks++;
  payload=envelope([{...row(1),static:null}]);assert.equal(await context.loadJfemResults(),false);assert(logs.some(entry=>/No static displacement/.test(entry.text)));checks++;
  // A terminal status must drain the worker's final log before results load.
  let status={state:'done',seconds:1,next_line:1,lines:['worker output'],has_more:false,log_done:false};
  context.fetch=async url=>String(url).includes('jfem_status')?{ok:true,json:async()=>status}:response();
  state.polling=true;await context.pollJfem();assert(state.polling);assert.equal(timers.length,1);checks++;
  status={...status,log_done:true};payload=envelope();await context.pollJfem();assert(!state.polling);assert.equal(announcements.at(-1).title,'JFEM results ready');checks++;
  state.polling=true;payload=envelope([{...row(1),source_model_params:{stale:1}}]);await context.pollJfem();
  assert.equal(announcements.at(-1).title,'JFEM results could not be displayed');assert.match(announcements.at(-1).detail,/no results compatible/);checks++;
  state.polling=true;status={...status,state:'failed',results_available:false,message:'Worker exception: singular factorization at grid 42.'};await context.pollJfem();
  assert.match(announcements.at(-1).detail,/grid 42/);assert(logs.some(entry=>/JFEM failed.*grid 42/.test(entry.text)));checks++;
  // Ignore an old job's in-flight response after a new job becomes current.
  state.polling=true;context.fetch=async()=>{state.jobId='job-b';return{ok:true,json:async()=>status};};
  const before=announcements.length;await context.pollJfem();assert(state.polling);assert.equal(announcements.length,before);checks++;
  console.log('Multiple-case provenance, repeated loads, explicit diagnostics and terminal log draining: '+checks+' checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
