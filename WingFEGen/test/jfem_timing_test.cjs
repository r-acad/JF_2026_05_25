'use strict';
const assert=require('node:assert/strict'),T=require('../web/jfem_timing.js');
const timing={available:true,solution_seconds:12.1,compilation_seconds:300,preparation_seconds:4,export_seconds:8,startup_overhead_seconds:36,total_seconds:360.1};
const messages=T.completion({seconds:360.1,timings:timing});
assert.match(messages[0],/12\.1 s \(compilation excluded\)/);
assert(!messages[0].includes('360.1'));
assert.match(messages[1],/compilation within analysis stages 300\.0 s/);
assert.match(messages[1],/deck preparation 4\.0 s/);
assert.match(messages[1],/result export 8\.0 s/);
assert.match(messages[1],/total elapsed 360\.1 s/);
assert.match(T.completion({timings:{...timing,solution_seconds:.024117}})[0],/0\.0241 s/);
assert.match(T.completion({timings:{...timing,preparation_seconds:null,adjoint_seconds:2}})[1],/deck preparation unavailable.*optional adjoint stage 2\.0 s/);
for(const timings of [undefined,{available:false}, {...timing,solution_seconds:null}]){
 const lines=T.completion({seconds:360.1,timings});
 assert.match(lines[0],/solution time is unavailable/);
 assert(!lines[0].includes('solution completed in'));
}
console.log('JFEM timing messages: solve time and preparation separated; unavailable timing stays explicit.');
