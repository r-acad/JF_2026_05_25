'use strict';
const assert=require('node:assert/strict'),S=require('../web/movable_structure.js');let checks=0;
const geometry=[{name:'Flap',eta_start:.2,eta_end:.8}],row={...S.defaults,surface:'Flap'},a={...S.attachmentDefaults,surface:'Flap',eta:.4};
assert.equal(S.normalize([row],[a],geometry).surfaces.length,1);checks++;
assert.equal(S.normalize([{...row,enabled:false}],[],[]).surfaces.length,1);checks++;
for(const delta of [{span_bays:0},{span_elements:101},{height_elements:1.5},{upper_thickness:0},{skin_material:null},{mesh_deflected:0},{secondary_spar:1},{secondary_spar:-.1},{enabled:'yes'},{unexpected:1}]){assert.throws(()=>S.normalize([{...row,...delta}],[a],geometry));checks++;}
for(const delta of [{eta:.9},{eta:null},{kind:'pinned'},{rib:0},{translation_stiffness:0},{tilt_stiffness:Infinity},{hinge_stiffness:-1},{unexpected:1}]){assert.throws(()=>S.normalize([row],[{...a,...delta}],geometry));checks++;}
assert.throws(()=>S.normalize([row],[],geometry));checks++;
assert.throws(()=>S.normalize([row],[a],[]));checks++;
assert.throws(()=>S.normalize([row,row],[a],geometry));checks++;
assert.throws(()=>S.normalize([row],[a,a],geometry));checks++;
assert.equal(S.normalize([row],[{...a,kind:'rigid'}],geometry).attachments[0].kind,'rigid');checks++;
assert.equal(S.normalize([row],[{...a,hinge_stiffness:0}],geometry).attachments[0].hinge_stiffness,0);checks++;
console.log(JSON.stringify({passed:true,checks,scope:'Structure bounds, optional legacy-empty state, separate attachments, rigid and free/elastic hinge definitions'}));
