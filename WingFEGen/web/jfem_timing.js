(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRunTimings=api;})(globalThis,function(){
 'use strict';
 const duration=value=>Number.isFinite(value)&&value>=0?(value>0&&value<0.1?value.toPrecision(3):value.toFixed(1))+' s':'unavailable';
 function completion(job){
  const timing=job.timings;
  if(!timing?.available||!Number.isFinite(timing.solution_seconds))return[
   'JFEM finished; measured solution time is unavailable. Total elapsed: '+duration(job.seconds)+'. Reading available results…',
   'This run did not report separate solution and compilation timings. Total elapsed is not a solution-time measurement.'
  ];
  return[
   (job.state&&job.state!=='done'?'JFEM '+job.state+'; measured numerical execution ': 'JFEM solution completed in ')+duration(timing.solution_seconds)+' (compilation excluded); reading available results…',
   'JFEM timings: Julia compilation within measured phases '+duration(timing.compilation_seconds)+
    '; deck preparation '+duration(timing.preparation_seconds)+'; result export '+duration(timing.export_seconds)+
    (timing.adjoint_seconds===null||timing.adjoint_seconds>0?'; optional adjoint stage '+duration(timing.adjoint_seconds):'')+
    '; startup, package loading and unclassified process overhead '+duration(timing.startup_overhead_seconds)+' (may include precompilation)'+
    '; total elapsed '+duration(timing.total_seconds)+'.'
  ];
 }
 function stageEntries(stages,label){
  const result=[];
  if(stages?.length)result.push({kind:'info',text:label+' timing detail: inclusive parent and child times overlap; do not add them. Category totals use exclusive execution only. Recompilation is part of compilation; garbage collection is part of wall time.'});
  for(const stage of stages||[]){
   const title=stage.label||stage.phase||'Unnamed phase',inclusive=stage.inclusive||{},exclusive=stage.exclusive||{},prefix=label+(stage.case_id!==undefined?' case '+stage.case_id:'')+(stage.solution?' SOL'+stage.solution:'')+' phase · '+title;
   result.push({kind:'info',text:prefix+' — '+(stage.calls??1)+' call(s); inclusive wall '+duration(inclusive.wall_seconds??stage.wall_seconds)+
    (stage.parent?'; within '+stage.parent:'')+'.'});
   result.push({kind:stage.category==='numerical'?'numerical':'preparation',text:'  exclusive '+(stage.category==='numerical'?'numerical execution':'execution')+' '+duration(exclusive.execution_seconds)+
    ' (child phases and measured compilation excluded); exclusive wall '+duration(exclusive.wall_seconds)+'.'});
   result.push({kind:'compilation',text:'  exclusive Julia compilation '+duration(exclusive.compilation_seconds)+
    '; recompilation '+duration(exclusive.recompilation_seconds)+'; garbage collection '+duration(exclusive.gc_seconds)+'.'});
  }
  return result;
 }
 function entries(job,{label='JFEM'}={}){
  const result=completion(job).map((text,index)=>({text:text.replaceAll('JFEM',label),kind:index===0&&job.timings?.available&&Number.isFinite(job.timings.solution_seconds)?'numerical':'preparation'}));
  result.push(...stageEntries(job.timings?.stages,label));
  // Older sensitivity workers expose measured startup stages independently.
  // Their nested native_analysis aggregate must never be summed with its parent.
  const worker=job.worker_timings||job.progress?.worker_timings;
  if(worker&&!job.timings?.stages?.length)for(const [name,value]of Object.entries(worker)){
   if(!Number.isFinite(value?.seconds))continue;
   const compile=value.compilation_seconds??value.compile_seconds,execution=Object.hasOwn(value,'execution_seconds')?value.execution_seconds:Number.isFinite(compile)&&compile<=value.seconds?value.seconds-compile:null;
   result.push({kind:'preparation',text:label+' worker phase · '+name.replaceAll('_',' ')+': wall '+duration(value.seconds)+
    '; measured Julia compilation '+duration(compile)+'; execution excluding compilation '+duration(execution)+
    '; garbage collection '+duration(value.gc_seconds)+'. Phase scopes may overlap; these rows are not an additive total.'});
  }
  if(worker?.native_analysis?.stages?.length&&!job.timings?.stages?.length)result.push(...stageEntries(worker.native_analysis.stages,label+' baseline'));
  const unseparated=job.result?.timings_seconds||job.progress?.timings_seconds;
  if(unseparated){
   result.push({kind:'preparation',text:label+' compute wall timings: compilation is not separately measured for these scopes. Nested operator and baseline detail overlaps its parent; do not sum these rows or add them to worker timings.'});
   for(const [name,value]of Object.entries(unseparated))if(Number.isFinite(value))result.push({kind:'preparation',text:label+' · '+name.replaceAll('_',' ')+': '+duration(value)+' wall, including any compilation.'});
  }
  return result;
 }
 return{completion,entries,stageEntries,duration};
});
