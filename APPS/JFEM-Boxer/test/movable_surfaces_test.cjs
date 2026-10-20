'use strict';
const assert=require('node:assert/strict'),M=require('../web/movable_surfaces.js');let checks=0;
const row=(overrides={})=>({name:'Flap',kind:'flap',edge:'trailing',eta_start:.2,eta_end:.7,hinge_start:.7,hinge_end:.8,deflection:15,color:'#29B6D1',...overrides});
const input=[row({name:'  Flap  '})],before=JSON.stringify(input);
assert.deepEqual(M.normalize(input),[row({color:'#29b6d1'})]);assert.equal(JSON.stringify(input),before);checks+=2;
assert.deepEqual(M.normalize([]),[]);checks++;
for(const changes of [{eta_start:-.1},{eta_end:1.01},{eta_start:.7},{hinge_start:0},{hinge_end:1},{eta_start:NaN},{deflection:91},{deflection:Infinity},{name:''},{name:'x\n'+'y'},{name:'x'.repeat(81)},{color:'red'},{kind:'spoiler'},{edge:'upper'},{hinge_start:true},{eta_end:null},{extra:1}]){assert.throws(()=>M.normalize([row(changes)]));checks++;}
assert.throws(()=>M.normalize([row(),row({name:'FLAP',eta_start:.7,eta_end:1})]));checks++;
assert.throws(()=>M.normalize([row(),row({name:'Aileron',eta_start:.6,eta_end:1})]));checks++;
assert.equal(M.normalize([row(),row({name:'Aileron',eta_start:.7,eta_end:1})]).length,2);checks++;
assert.equal(M.normalize([row(),row({name:'Slat',kind:'slat',edge:'leading',hinge_start:.1,hinge_end:.2})]).length,2);checks++;
assert.throws(()=>M.normalize([row(),row({name:'Slat',kind:'slat',edge:'leading',hinge_start:.1,hinge_end:.9})]));checks++;
assert.throws(()=>M.normalize(Array.from({length:101},(_,i)=>row({name:String(i)}))));checks++;
let added=[];for(let i=0;i<4;i++){const next=M.nextSurface(added);assert(next);added=M.normalize([...added,next]);checks++;}assert.equal(M.nextSurface(added),null);checks++;
for(const angle of [-90,0,90]){assert.equal(M.normalize([row({deflection:angle})])[0].deflection,angle);checks++;}
console.log(JSON.stringify({passed:true,checks,scope:'Strict fields, finite bounds, unique names, adjacent and overlapping footprints, crossed hinges, safe new surface placement'}));
