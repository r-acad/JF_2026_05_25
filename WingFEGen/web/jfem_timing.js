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
   'JFEM solution completed in '+duration(timing.solution_seconds)+' (compilation excluded); reading available results…',
   'JFEM timings: Julia compilation within analysis stages '+duration(timing.compilation_seconds)+
    '; deck preparation '+duration(timing.preparation_seconds)+'; result export '+duration(timing.export_seconds)+
    (timing.adjoint_seconds===null||timing.adjoint_seconds>0?'; optional adjoint stage '+duration(timing.adjoint_seconds):'')+
    '; startup, package loading/precompilation and other process overhead '+duration(timing.startup_overhead_seconds)+
    '; total elapsed '+duration(timing.total_seconds)+'.'
  ];
 }
 return{completion};
});
