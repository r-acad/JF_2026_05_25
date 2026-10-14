'use strict';
const assert=require('node:assert/strict'),M=require('../web/material_axes.js');
const close=(a,b)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<1e-6,JSON.stringify({a,b})));
const z=[0,0,1],base={x:[1,0,0],y:[0,1,0],z,edge:[2,0,0]};
close(M.frame({...base,theta:90}).x,[0,1,0]);
// Material THETA follows G1-G2 even if the solver's geometric Q4 frame differs.
close(M.frame({...base,x:[Math.SQRT1_2,Math.SQRT1_2,0],edge:[1,0,0],theta:30}).x,[Math.sqrt(3)/2,.5,0]);
// MCID projection takes precedence over THETA and falls back to its y axis
// when its x axis is parallel to the shell normal (native solver convention).
close(M.frame({...base,coordinate:{x:[1,0,2],y:[0,1,0]},theta:90}).x,[1,0,0]);
close(M.frame({...base,coordinate:{x:z,y:[0,1,0]}}).x,[0,1,0]);
const f=M.frame({...base,z:[0,1,0],edge:[1,0,1],theta:45});
close(f.x,[1,0,0]);close(f.y,[0,0,-1]);
const helpers={asF32:x=>x,asI32:x=>x,groupIds:g=>g.eids};
const g={kind:'tria',count:1,eids:[77],conn:[0,1,2],axes:{x:[1,0,0],y:[0,1,0],z,centers:[.3,.3,0]},material_orientation:{mcid:[42],theta:[0]}};
const state={data:{imported_deck:{},nodes:{xyz:[0,0,0,1,0,0,0,1,0]},coordinate_systems:{systems:[{id:42,x:[0,1,0],y:[-1,0,0]}]}}};
const axes=M.axes(state,g,helpers);close([...axes.x],[0,1,0]);assert.match(axes.labels[0],/E 77 · MCID 42/);
g.material_orientation={mcid:[0],theta:[45]};const rotated=M.axes(state,g,helpers);close([...rotated.x],[Math.SQRT1_2,Math.SQRT1_2,0]);assert.match(rotated.labels[0],/θ 45° · element G1/);
delete state.data.imported_deck;assert.match(M.axes(state,g,helpers).labels[0],/MCID 77/);
console.log('Material axes PASS: THETA, skew Q4 frame, MCID projection/fallback, tilted plane and truthful labels.');
