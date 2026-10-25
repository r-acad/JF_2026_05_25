'use strict';
const assert=require('node:assert/strict'),M=require('../web/geometry_tools.js');let checks=0;
const close=(a,b)=>{assert(Math.abs(a-b)<1e-11,`${a} != ${b}`);checks++;};
const a=M.toView([1,2,3]),b=M.toView([4,6,15]);
close(M.distance(a,b).length,13);
for(const [axis,expected]of [[[1,0,0],3],[[0,1,0],4],[[0,0,1],12],[[-2,0,0],-3],[[3,4,0],5]]){
 const d=M.axisDistance(a,b,axis);close(d.signed,expected);close(d.along,Math.abs(expected));
 const projection=M.toFE(d.projection),v=projection.map((x,i)=>x-[1,2,3][i]);close(Math.hypot(...v),Math.abs(expected));
 close(d.delta.reduce((sum,x,i)=>sum+(x-v[i])*d.direction[i],0),0);
}
close(M.axisDistance(a,a,[0,1,0]).along,0);
for(const axis of [[0,0,0],[1,2],[1,2,NaN]]){assert.throws(()=>M.axisDistance(a,b,axis));checks++;}
const frames=M.measurementFrames([{id:0,type:'RECTANGULAR',x:[1,0,0],y:[0,1,0],z:[0,0,1]},{id:7,type:'RECTANGULAR',x:[.6,.8,0],y:[-.8,.6,0],z:[0,0,1]},{id:9,type:'CYLINDRICAL',x:[1,0,0],y:[0,1,0],z:[0,0,1]},{id:10,type:'RECTANGULAR',x:[0,0,0],y:[0,1,0],z:[0,0,1]}]);
assert.deepEqual(frames.map(f=>f.id),['0','7','9']);checks++;close(M.axisDistance(a,b,frames[1].x).along,5);assert.match(frames[2].label,/defining axes/);checks++;
console.log(JSON.stringify({passed:true,checks,scope:'Euclidean distance, signed and absolute projections, rotated defining axes, invalid frame rejection'}));
