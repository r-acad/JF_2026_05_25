"use strict";
const assert=require("node:assert/strict"),P=require("../web/view_planes.js"),W=require("../web/workspace.js");
for(const size of [0.001,1,1e6]){
 const min=[2,-1.25,-.4],max=min.map((v,i)=>v+size*(i+1)),data={bbox:{min,max},model_params:{"planform.root_ref_x":2,"planform.root_ref_y":-1.25,"planform.root_ref_z":-.4}},g=P.layout(data);
 assert.equal(g.spacing,5);assert(g.ground.every(p=>p[2]===0));assert(g.symmetry.every(p=>p[1]===-1.25));
 assert.equal(g.ground.length,4,"plane complexity must not scale with wing size");
 for(const p of g.ground)assert(p[0]%5===0&&p[1]%5===0,"grid bounds stay aligned to global 5 m coordinates");
 assert(g.ground[0][0]<min[0]&&g.ground[2][0]>max[0]);assert(g.ground[0][1]<min[1]&&g.ground[2][1]>max[1]);
 assert(g.symmetry[0][2]<min[2]&&g.symmetry[2][2]>max[2]);
}
for(const id of ["show-ground-plane","show-symmetry-plane"])assert(W.CONTROL_IDS.includes(id));
for(const scale of [.001,1,1000]){
 const min=[50000,-250,2500].map(v=>v*scale),max=[54000,250,7500].map(v=>v*scale),data={bbox:{min,max},imported_deck:{name:'offset.bdf'},model_params:{'planform.root_ref_x':0}},g=P.layout(data),diag=Math.hypot(...max.map((v,i)=>v-min[i]));
 assert.equal(g.symmetry[0][1],0);assert(g.ground[0][0]>40000*scale);assert(Math.abs((g.ground[2][0]-g.ground[0][0])-(max[0]-min[0]+.3*diag))<diag*1e-12);
 assert.equal(g.ground.length,4);assert(g.ground.flat().every(Number.isFinite));
}
const model={bbox:{min:[2,-1.25,-.4],max:[4,6,2]},model_params:{"planform.root_ref_y":-1.25}},baseline=P.layout(model);
for(const z of [-17.25,0,3.125,1e300])for(const spacing of [Number.MIN_VALUE,.125,5,1e300]){
 const adjusted=P.layout(model,{z,spacing});assert.equal(adjusted.z,z);assert.equal(adjusted.spacing,spacing);
 assert(adjusted.ground.every(p=>p[2]===z));assert.equal(adjusted.ground.length,4);assert.deepEqual(adjusted.symmetry,baseline.symmetry);
}
for(const z of [NaN,Infinity,-Infinity,"",null])assert.throws(()=>P.settings({z}),/finite/);
for(const spacing of [NaN,Infinity,-Infinity,0,-1,"",null])assert.throws(()=>P.settings({spacing}),/greater than zero/);
const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},activeCase:1,workspace:{activeTab:"display",width:360,collapsed:false,maximizedTab:null}};
for(const [id,valid,invalid]of [["ground-plane-z",["-2.75","0","1e300"],["","NaN","Infinity","1e309"]],["ground-grid-spacing",["0.125","5","5e-324","1e300"],["","0","-1","NaN","Infinity","1e309"]]]){
 assert(W.CONTROL_IDS.includes(id));for(const value of valid){view.controls={[id]:value};assert.equal(W.validateView(view),view);}
 for(const value of invalid){view.controls={[id]:value};assert.throws(()=>W.validateView(view),/Ground/);}
}
console.log("Context planes passed: adjustable global height/spacing, unchanged symmetry, bounded geometry, extreme finite settings and Study validation.");
