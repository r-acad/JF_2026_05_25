'use strict';
const assert=require('node:assert/strict'),gauge=require('../web/minimum_gauge_inputs.js'),panels=require('../web/panel_table_data.js'),components=require('../web/component_table_data.js');
let count=0;const test=(name,fn)=>{fn();count++;console.log('PASS '+name);};
const p={'material.name':'Al','materials.library':[{id:3,name:'Core'}],'materials.shells':[], 'properties.t_skin_upper':.0025,'properties.t_skin_lower':.0022,'properties.t_spar_web':.003,'properties.t_rib_web':.002,'properties.spar_cap_side':.02,'properties.stringer_flange_width':.03,'properties.stringer_height':.032,'properties.stringer_flange_thickness':.002,'properties.stringer_web_thickness':.002,'properties.rib_stiffeners_enabled':true,'properties.rib_stiffener_flange_width':.03,'properties.rib_stiffener_height':.032,'properties.rib_stiffener_flange_thickness':.002,'properties.rib_stiffener_web_thickness':.002,'leading_edge.t_skin':.0015,'leading_edge.t_rib':.0015,'properties.panels':[],'properties.components':[],'stringers.model':'beam'};
const section={flange_width:.03,height:.032,flange_thickness:.002,web_thickness:.002,material:1};
const s=()=>({parameters:structuredClone(p),layout_token:'layout',panels:[{key:'upper:bay1:stringer1:segment1',id:1,skin:'upper',stringer:1,rib_bay:1,segment:1}]});
test('Active local monolithic dimensions cannot undercut any family minimum',()=>{for(const[name,key]of Object.entries({upper_skin:'properties.t_skin_upper',lower_skin:'properties.t_skin_lower',spar_web:'properties.t_spar_web',rib_web:'properties.t_rib_web',leading_edge_skin:'leading_edge.t_skin',leading_edge_rib:'leading_edge.t_rib'})){gauge.validate(p,name,{kind:'monolithic',thickness:p[key]});assert.throws(()=>gauge.validate(p,name,{kind:'monolithic',thickness:p[key]*.99}),/minimum gauge/);}});
test('Panel table rejects smaller thickness atomically and permits larger then inherited values',()=>{const snap=s(),before=JSON.stringify(snap);assert.throws(()=>panels.update(snap,'skins',snap.panels[0].key,'thickness','2.4'),/minimum gauge/);assert.equal(JSON.stringify(snap),before);snap.parameters['properties.panels']=panels.update(snap,'skins',snap.panels[0].key,'thickness','3');assert.equal(panels.effective(snap,snap.panels[0],'skins').thickness,.003);snap.parameters['properties.panels']=panels.update(snap,'skins',snap.panels[0].key,'thickness','');assert.deepEqual(snap.parameters['properties.panels'],[]);});
test('Editing a family minimum deliberately changes the local floor',()=>{const snap=s();snap.parameters['properties.t_skin_upper']=.001;assert.equal(panels.update(snap,'skins',snap.panels[0].key,'thickness','1.5')[0].skin.thickness,.0015);});
test('All four T dimensions and cap side are independently constrained',()=>{for(const field of Object.keys(section).filter(k=>k!=='material'))assert.throws(()=>gauge.validate(p,'stringer',{...section,[field]:section[field]*.9}),/minimum gauge/);assert.throws(()=>gauge.validate(p,'spar_cap',{side:.019}),/minimum gauge/);gauge.validate(p,'spar_cap',{side:.021});});
test('Shared runout minimum constrains its side and reconciles only the P13 override',()=>{
 assert(gauge.isMinimumKey('properties.runout_side'));assert.throws(()=>gauge.validate(p,'runout',{side:.002}),/minimum gauge/);
 const q={...p,'properties.runout_side':.004,'properties.components':[{key:'stringer_runout:1',side:.003,material:2},{key:'front_upper_cap:1',side:.025}]},before=JSON.stringify(q),r=gauge.reconcileMinimumEdit(q,'properties.runout_side');
 assert.equal(JSON.stringify(q),before);assert.deepEqual(r.patches['properties.components'],[{key:'stringer_runout:1',side:.004,material:2},{key:'front_upper_cap:1',side:.025}]);assert.equal(r.changes.length,1);assert.deepEqual(gauge.reconcileMinimumEdit({...q,...r.patches},'properties.runout_side').patches,{});
});
test('Zero-width shell blade excludes inactive flange thickness but retains width floor',()=>{const blade={...section,flange_width:0,flange_thickness:0};assert.throws(()=>gauge.validate({...p,'stringers.model':'shell'},'stringer',blade),/minimum gauge/);gauge.validate({...p,'stringers.model':'shell','properties.stringer_flange_width':0},'stringer',blade);});
test('Sandwich global gauges constrain active face/core and total, not dormant monolithic thickness',()=>{const q={...p,'materials.shells':[{component:'upper_skin',kind:'sandwich',face_thickness:.0005,core_thickness:.003}]},v={kind:'sandwich',face_thickness:.0005,core_thickness:.003,thickness:.0001};gauge.validate(q,'upper_skin',v);assert.throws(()=>gauge.validate(q,'upper_skin',{...v,face_thickness:.0004,core_thickness:.004}),/minimum gauge/);assert.throws(()=>gauge.validate(q,'upper_skin',{...v,face_thickness:.001,core_thickness:.002}),/minimum gauge/);assert.equal(gauge.fieldMinimum(q,'upper_skin',v,'core_thickness'),.003);});
test('Local sandwich under a monolithic family enforces total without dormant layer floors',()=>{gauge.validate(p,'upper_skin',{kind:'sandwich',face_thickness:.0001,core_thickness:.0023});assert.throws(()=>gauge.validate(p,'upper_skin',{kind:'sandwich',face_thickness:.0001,core_thickness:.002}),/minimum gauge/);});
test('Spar override floors refer to global minimum rather than a larger legacy default',()=>{const snap=components.compact({parameters:{...p,'properties.spar_bays':[{bay:1,front_thickness:.005}]},rib_count:2,layout_token:'layout'},'sparwebs');assert.equal(components.update(snap,'sparwebs','front_web:1','thickness','4')[0].thickness,.004);assert.throws(()=>components.update(snap,'sparwebs','front_web:1','thickness','2.9'),/minimum gauge/);assert.equal(components.minimum(snap,snap.panels[0],'sparwebs','thickness'),.003);});
test('Component tables enforce spar-cap, rib-stiffener and leading-edge floors',()=>{for(const[kind,key,field,value]of[['sparcaps','front_upper_cap:1','side','19'],['ribstiffeners','rib_stiffener:1','height','31'],['leskins','leading_upper_skin:1','thickness','1.4']]){const snap=components.compact({parameters:{...p,'leading_edge.enabled':true},rib_count:2,layout_token:'layout'},kind);assert.throws(()=>components.update(snap,kind,key,field,value),/minimum gauge/);}});
test('Disabled stiffeners do not require inactive minimum dimensions',()=>gauge.validate(p,'rib_stiffener',{...section,height:.02,enabled:false}));
test('Floating roundoff at the minimum does not reject an equal intended value',()=>gauge.validate(p,'upper_skin',{kind:'monolithic',thickness:.0025*(1-2e-15)}));
test('Unsupported or unrecorded families never invent a minimum',()=>{assert.deepEqual(gauge.dimensions(p,'external_property',{thickness:.0001}),[]);assert.equal(gauge.fieldMinimum(p,'external_property',{},'thickness'),null);});
test('An explicit global spar-web increase raises both override systems and preserves thicker values',()=>{
 const q={...p,'properties.t_spar_web':.004,'properties.spar_bays':[{bay:1,front_thickness:.003,rear_thickness:.006}],
  'properties.components':[{key:'front_web:1',thickness:.003},{key:'rear_web:1',thickness:.006},{key:'rib_web:1',thickness:.002}]},before=JSON.stringify(q),r=gauge.reconcileMinimumEdit(q,'properties.t_spar_web');
 assert.equal(JSON.stringify(q),before,'pure edit reconciliation');assert.equal(r.patches['properties.spar_bays'][0].front_thickness,.004);assert.equal(r.patches['properties.spar_bays'][0].rear_thickness,.006);
 assert.equal(r.patches['properties.components'][0].thickness,.004);assert.equal(r.patches['properties.components'][1].thickness,.006);assert.equal(r.patches['properties.components'][2].thickness,.002);
 assert.equal(r.changes.length,2);assert.deepEqual(gauge.reconcileMinimumEdit({...q,...r.patches},'properties.t_spar_web').patches,{},'idempotent');
});
test('Skin and stringer minima reconcile shared physical panels independently',()=>{
 const q={...p,'properties.panels':[{key:'upper:bay1:stringer1:segment1',skin:{thickness:.0015,material:2},stringer:{height:.02,web_thickness:.003}},{key:'lower:bay1:stringer1:segment1',skin:{thickness:.0015}}]};
 const skins=gauge.reconcileMinimumEdit(q,'properties.t_skin_upper').patches['properties.panels'];assert.equal(skins[0].skin.thickness,.0025);assert.equal(skins[0].skin.material,2);assert.equal(skins[1].skin.thickness,.0015);
 const bars=gauge.reconcileMinimumEdit(q,'properties.stringer_height').patches['properties.panels'];assert.equal(bars[0].stringer.height,.032);assert.equal(bars[0].stringer.web_thickness,.003);
});
test('Cap, rib-web and rib-stiffener minimum increases preserve IDs and unrelated fields',()=>{
 const q={...p,'properties.ribs':[{rib:3,thickness:.001,flange_width:.02,stiffener_enabled:false}],'properties.components':[{key:'front_upper_cap:1',side:.01},{key:'rib_stiffener:3',flange_width:.02,material:7}]};
 assert.equal(gauge.reconcileMinimumEdit(q,'properties.spar_cap_side').patches['properties.components'][0].side,.02);
 assert.equal(gauge.reconcileMinimumEdit(q,'properties.t_rib_web').patches['properties.ribs'][0].thickness,.002);
 const r=gauge.reconcileMinimumEdit(q,'properties.rib_stiffener_flange_width');assert.equal(r.patches['properties.ribs'][0].flange_width,.03);assert.equal(r.patches['properties.ribs'][0].stiffener_enabled,false);assert.equal(r.patches['properties.components'][1].material,7);
});
test('Sandwich total minima increase the core without erasing materials or larger local stacks',()=>{
 const q={...p,'properties.t_skin_upper':.012,'materials.shells':[{component:'upper_skin',kind:'sandwich',face_thickness:.001,core_thickness:.008}],
  'properties.panels':[{key:'upper:bay1:stringer1:segment1',skin:{core_thickness:.007,core_material:3}},{key:'upper:bay1:stringer2:segment1',skin:{core_thickness:.02}}]};
 const r=gauge.reconcileMinimumEdit(q,'properties.t_skin_upper');assert.equal(r.patches['materials.shells'][0].core_thickness,.01);assert.equal(r.patches['properties.panels'][0].skin.core_thickness,.01);assert.equal(r.patches['properties.panels'][0].skin.core_material,3);assert.equal(r.patches['properties.panels'][1].skin.core_thickness,.02);
});
test('Unrelated edits, reducing minima, absent dimensions and invalid drafts are not repaired',()=>{
 const q={...p,'properties.t_spar_web':.001,'properties.components':[{key:'front_web:1',thickness:.003},{key:'rear_web:1',thickness:-.001},{key:'front_web:2',material:2}]};
 assert.deepEqual(gauge.reconcileMinimumEdit(q,'properties.t_spar_web').patches,{});assert.deepEqual(gauge.reconcileMinimumEdit(q,'properties.components').patches,{});
 assert.deepEqual(gauge.reconcileMinimumEdit({...q,'properties.t_spar_web':NaN},'properties.t_spar_web').patches,{});
});
test('A raised sandwich core floor overrides a thinner local core even when thicker faces already satisfy the total',()=>{
 const q={...p,'properties.t_skin_upper':.012,'materials.shells':[{component:'upper_skin',kind:'sandwich',face_thickness:.001,core_thickness:.008,face_material:2,core_material:3}],
  'properties.panels':[{key:'upper:bay1:stringer1:segment1',skin:{face_thickness:.002,core_thickness:.009,face_material:7}},{key:'upper:bay1:stringer2:segment1',skin:{face_thickness:.0025,core_thickness:.02}}]};
 const r=gauge.reconcileMinimumEdit(q,'properties.t_skin_upper'),skin=r.patches['properties.panels'][0].skin;
 assert.equal(skin.face_thickness,.002);assert.equal(skin.core_thickness,.01);assert.equal(skin.face_material,7);assert.equal(r.patches['properties.panels'][1].skin.core_thickness,.02);
 gauge.validate({...q,...r.patches},'upper_skin',{...r.patches['materials.shells'][0],...skin});
});
test('Legacy sandwich rib and spar totals preserve the new core floor under thicker local faces',()=>{
 for(const [component,key,legacy,part]of [['rib_web','properties.t_rib_web','properties.ribs','rib_web'],['spar_web','properties.t_spar_web','properties.spar_bays','front_web']]){
  const q={...p,[key]:.012,'materials.shells':[{component,kind:'sandwich',face_thickness:.001,core_thickness:.008}],
   [legacy]:[component==='rib_web'?{rib:1,thickness:.013}:{bay:1,front_thickness:.013,rear_thickness:.02}],
   'properties.components':[{key:part+':1',face_thickness:.003,face_material:2}]};
  const r=gauge.reconcileMinimumEdit(q,key),row=r.patches[legacy][0],total=row[component==='rib_web'?'thickness':'front_thickness'];
  assert.equal(total,.016);assert.equal(r.patches['materials.shells'][0].core_thickness,.01);assert.equal(q['properties.components'][0].face_material,2);
 }
});
test('Committed sandwich layer minima raise local layers and compensate legacy totals without reducing larger gauges',()=>{
 const q={...p,'materials.shells':[{component:'spar_web',kind:'sandwich',face_thickness:.002,core_thickness:.006,face_material:1,core_material:3}],
  'properties.spar_bays':[{bay:1,front_thickness:.009,rear_thickness:.03}],
  'properties.components':[{key:'front_web:1',face_thickness:.001,face_material:7},{key:'rear_web:1',face_thickness:.003,core_thickness:.02,core_material:8}]},before=JSON.stringify(q);
 const r=gauge.reconcileMaterialMinimumEdit(q,'spar_web');assert.equal(JSON.stringify(q),before);
 assert.equal(r.patches['properties.components'][0].face_thickness,.002);assert.equal(r.patches['properties.components'][0].face_material,7);
 assert.equal(r.patches['properties.components'][1].core_thickness,.02);assert.equal(r.patches['properties.components'][1].core_material,8);
 assert.equal(r.patches['properties.spar_bays'][0].front_thickness,.01);assert.equal(r.patches['properties.spar_bays'][0].rear_thickness,.03);
 assert.deepEqual(r.patches['materials.shells'],q['materials.shells']);assert.equal(gauge.shellMinimumKey('spar_web'),'properties.t_spar_web');
});
test('Layer minima reject partial invalid candidates rather than treating a typed mantissa as an accepted assignment',()=>{
 const q={...p,'materials.shells':[{component:'upper_skin',kind:'sandwich',face_thickness:{raw:'1e-'},core_thickness:.006}]};
 assert.deepEqual(gauge.reconcileMaterialMinimumEdit(q,'upper_skin'),{patches:{},changes:[]});
 assert.deepEqual(gauge.reconcileMaterialMinimumEdit({...q,'materials.shells':[{component:'upper_skin',kind:'monolithic',face_thickness:.002,core_thickness:.006}]},'upper_skin'),{patches:{},changes:[]});
});
console.log(count+' minimum-gauge input tests passed.');
