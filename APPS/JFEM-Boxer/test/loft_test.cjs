'use strict';
const assert=require('node:assert/strict'),L=require('../web/loft.js');let checks=0;
const near=(a,b)=>{assert(Math.abs(a-b)<1e-12,a+' != '+b);checks++;};
const rows=[{eta:.8,tc:.3},{eta:.2,tc:.1}],snapshot=JSON.stringify(rows);
assert.deepEqual(L.normalizeSchedule(rows,'thickness'),[{eta:.2,tc:.1},{eta:.8,tc:.3}]);checks++;
assert.equal(JSON.stringify(rows),snapshot);checks++;
near(L.interpolateSchedule(rows,.35),.15);near(L.interpolateSchedule(rows,.35,{method:'cosine'}),.1+.2*(1-Math.cos(Math.PI/4))/2);
for(const method of['linear','cosine']){near(L.interpolateSchedule(rows,-1,{method}),.1);near(L.interpolateSchedule(rows,2,{method}),.3);near(L.interpolateSchedule([{eta:.4,tc:.18}],0,{method}),.18);near(L.interpolateSchedule([{eta:.4,tc:.18}],1,{method}),.18);}
assert.equal(L.interpolateSchedule([],0),null);checks++;
near(L.interpolateSchedule([{eta:0,twist:10},{eta:.5,twist:-5},{eta:1,twist:-20}],.25,{kind:'twist'}),2.5);
near(L.interpolateSchedule([{eta:0,twist:44.99},{eta:1,twist:-44.99}],.5,{kind:'twist',method:'cosine'}),0);
near(L.normalizeSchedule([{eta:1,tc:1}],'thickness')[0].tc,1);
for(const [value,kind]of[[null,'thickness'],[[{eta:.1,tc:0}],'thickness'],[[{eta:.1,tc:1.01}],'thickness'],[[{eta:-.1,tc:.1}],'thickness'],[[{eta:.2,tc:.1},{eta:.2,tc:.2}],'thickness'],[[{eta:.2,tc:.1,extra:1}],'thickness'],[[{eta:.2,twist:45}],'twist'],[[{eta:.2,twist:-45}],'twist'],[[{eta:.2,twist:Infinity}],'twist'],[[{eta:null,twist:0}],'twist'],[Array.from({length:101},(_,i)=>({eta:i/101,tc:.1})),'thickness']]){assert.throws(()=>L.normalizeSchedule(value,kind));checks++;}
assert.throws(()=>L.interpolateSchedule(rows,.5,{method:'spline'}));checks++;
assert.throws(()=>L.interpolateSchedule(rows,NaN));checks++;
console.log(JSON.stringify({passed:true,checks,scope:'Schedule bounds, pure sorting, clamped endpoints, independent linear/cosine formula and legacy-empty sentinel'}));
