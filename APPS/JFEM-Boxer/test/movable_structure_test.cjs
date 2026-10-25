'use strict';
const assert=require('node:assert/strict'),S=require('../web/movable_structure.js');let checks=0;
const geometry=[{name:'Flap',eta_start:.2,eta_end:.8}],row={...S.defaults,surface:'Flap'},a={...S.attachmentDefaults,surface:'Flap',eta:.4};
assert.equal(S.normalize([row],[a],geometry).surfaces.length,1);checks++;
assert.equal(S.normalize([{...row,enabled:false}],[],[]).surfaces.length,1);checks++;
for(const delta of [{span_bays:0},{span_elements:101},{height_elements:1.5},{upper_thickness:0},{skin_material:null},{mesh_deflected:0},{secondary_spar:1},{secondary_spar:-.1},{enabled:'yes'},{unexpected:1},{end_eta:.1},{end_eta:.9},{end_eta:null},{max_rib_pitch_ratio:0.9},{max_rib_pitch_ratio:NaN},{max_rib_pitch_ratio:null}]){assert.throws(()=>S.normalize([{...row,...delta}],[a],geometry));checks++;}
for(const delta of [{eta:.9},{eta:null},{kind:'pinned'},{rib:0},{translation_stiffness:0},{tilt_stiffness:Infinity},{hinge_stiffness:-1},{unexpected:1},{fitting:'wrong'},{lug_thickness:0},{lug_material:0},{actuator:1},{lateral_stay:null},{actuator_stiffness:-1},{actuator_stiffness:null},{actuator_stiffness:Infinity}]){assert.throws(()=>S.normalize([row],[{...a,...delta}],geometry));checks++;}
assert.throws(()=>S.normalize([row],[],geometry));checks++;
assert.throws(()=>S.normalize([row],[a],[]));checks++;
assert.throws(()=>S.normalize([row,row],[a],geometry));checks++;
assert.throws(()=>S.normalize([row],[a,a],geometry));checks++;
assert.equal(S.normalize([row],[{...a,kind:'rigid'}],geometry).attachments[0].kind,'rigid');checks++;
assert.equal(S.normalize([row],[{...a,hinge_stiffness:0}],geometry).attachments[0].hinge_stiffness,0);checks++;
assert.equal(S.normalize([{...row,end_eta:.6}],[{...a,fitting:'shell_lugs',actuator:true,lateral_stay:true}],geometry).surfaces[0].end_eta,.6);checks++;
assert.throws(()=>S.normalize([row],[{...a,fitting:'shell_lugs',kind:'rigid',actuator:true,lateral_stay:false}],geometry));checks++;
assert.equal(S.normalize([row],[{...a,fitting:'shell_lugs',kind:'hinge',actuator:true,lateral_stay:false}],geometry).attachments[0].actuator_stiffness,1e7);checks++;
assert.equal(S.normalize([{...row,max_rib_pitch_ratio:1}],[{...a,actuator_stiffness:0}],geometry).surfaces[0].max_rib_pitch_ratio,1);checks++;
assert.equal(S.normalize([row],[{...a,fitting:'shell_lugs',actuator:false,lateral_stay:false}],geometry).attachments[0].actuator,false);checks++;
const ribs=[{index:3,eta:.6},{index:1,eta:.2},{index:2,eta:.4},{index:4,eta:.8}];
for(const [eta,start,end,excluded,expected]of [[.51,.2,.8,[],3],[.5,.2,.8,[],2],[.1,.4,.8,[],2],[.8,.2,.6,[],3],[.41,.2,.8,[2],3],[.5,.45,.55,[],null],[NaN,0,1,[],null]]){assert.equal(S.nearestAttachmentRib(eta,ribs,start,end,excluded)?.index??null,expected);checks++;}
const unordered=[{...a,eta:.7},{...a,surface:'Aileron',eta:.5},{...a,eta:.3}],before=JSON.stringify(unordered);
assert.deepEqual(S.normalize([row,{...row,surface:'Aileron'}],unordered,[...geometry,{...geometry[0],name:'Aileron'}]).attachments.map(r=>[r.surface,r.eta]),[['Aileron',.5],['Flap',.3],['Flap',.7]]);checks++;
assert.equal(JSON.stringify(unordered),before);checks++;
assert.deepEqual(S.orderAttachments([{surface:'Flap',eta:.4,id:1},{surface:'Flap',eta:null,id:2},{surface:'Flap',eta:.4,id:3}]).map(r=>r.id),[1,3,2]);checks++;
console.log(JSON.stringify({passed:true,checks,scope:'Structure bounds, optional legacy-empty state, separate attachments, rigid and free/elastic hinge definitions'}));
