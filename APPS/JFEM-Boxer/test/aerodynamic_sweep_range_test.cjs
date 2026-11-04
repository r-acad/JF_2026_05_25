'use strict';
const assert=require('node:assert/strict'),A=require('../web/aerodynamic_study.js');
const cases=[
 [{start:0,stop:1,step:.3},5,1.2],
 [{start:-5,stop:10,step:2.5},7,10],
 [{start:1,stop:0,step:-.3},5,-.2],
 [{start:0,stop:.3,step:.1},4,.3],
 [{start:0,stop:1,step:3},2,3],
 [{start:2,stop:2,step:1},1,2],
 [{start:0,stop:1e-16,step:1},2,1],
 [{start:0,stop:1,count:4},4,1]
];
for(const[input,count,last]of cases){const range=A.sweepDefinition(input);assert.equal(range.count,count);assert(Math.abs(range.last-last)<1e-14);}
for(const input of [{start:0,stop:1,step:0},{start:1,stop:0,step:1},{start:0,stop:1,step:-1},{start:0,stop:1,step:NaN},{start:0,stop:Infinity,step:1},{start:0,stop:1,step:Number.MIN_VALUE},{start:0,stop:1,count:1},{start:0,stop:1,step:.5,count:3}])assert.throws(()=>A.sweepDefinition(input));
const settings={...A.DEFAULTS,mode:'sweep',derivatives:true,sweeps:[{variable:'alpha',start:0,stop:1,step:.3},{variable:'beta',start:1,stop:0,step:-.3}]};
assert.deepEqual(A.workEstimate(settings),{valid:true,conditions:25,derivativeVariables:7,baseEvaluations:25,additionalEvaluations:350,maximumEvaluations:375});
assert.deepEqual(A.validateState({settings}).settings.sweeps,settings.sweeps,'Step-based saved sweeps survive persistence without a second count definition.');
const legacy=[{variable:'alpha',start:-5,stop:10,count:15},{variable:'beta',start:-2,stop:2,count:10}];
assert.deepEqual(A.validateState({settings:{mode:'sweep',sweeps:legacy}}).settings.sweeps,legacy,'Legacy sweeps retain exact endpoints and counts.');
assert.equal(A.workEstimate({...settings,sweeps:[{variable:'alpha',start:1,stop:0,step:1}]}).valid,false);
console.log('PASS Sweep range direction, endpoint overshoot, floating-point boundaries, Cartesian work and legacy Study compatibility.');
