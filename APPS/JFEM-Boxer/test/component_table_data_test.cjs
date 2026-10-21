'use strict';
const assert=require('node:assert/strict'),api=require('../web/component_table_data.js');
const parameters={'material.name':'Aluminium','materials.library':[{id:2,name:'Steel'},{id:3,name:'Core'}],'properties.components':[],
 'properties.t_spar_web':.003,'properties.t_rib_web':.002,'properties.spar_cap_side':.02,'properties.rib_stiffeners_enabled':true,
 'properties.rib_stiffener_flange_width':.03,'properties.rib_stiffener_height':.032,'properties.rib_stiffener_flange_thickness':.002,'properties.rib_stiffener_web_thickness':.002,
 'properties.ribs':[{rib:2,thickness:.004,height:.04}],'properties.spar_bays':[{bay:1,front_thickness:.005}],
 'leading_edge.enabled':true,'leading_edge.t_skin':.0015,'leading_edge.t_rib':.002,'leading_edge.start_rib':1,'leading_edge.end_rib':4,'leading_edge.disabled_bays':'2'};
const snapshot=kind=>api.compact({parameters,ribs:[{},{},{},{}],layout_token:'layout'},kind);
let s=snapshot('sparwebs');assert.equal(s.panels.length,6);assert.equal(api.inherited(s,s.panels[0],'sparwebs').thickness,.005);
s.parameters[api.PARAMETER]=api.update(s,'sparwebs','front_web:1','thickness','6');assert.equal(api.effective(s,s.panels[0],'sparwebs').thickness,.006);
s.parameters[api.PARAMETER]=api.update(s,'sparwebs','front_web:1','material','2');assert.equal(s.parameters[api.PARAMETER][0].material,2);
s.parameters[api.PARAMETER]=api.update(s,'sparwebs','front_web:1','thickness','');assert.equal(api.effective(s,s.panels[0],'sparwebs').thickness,.005);assert.equal(s.parameters[api.PARAMETER][0].material,2);
assert.throws(()=>api.update(s,'sparwebs','front_web:1','material','99'),/material/i);
s=snapshot('sparcaps');assert.equal(s.panels.length,12);assert.equal(api.update(s,'sparcaps','front_upper_cap:1','side','25')[0].side,.025);
s=snapshot('ribwebs');assert.equal(s.panels.length,4);assert.equal(api.inherited(s,s.panels[1],'ribwebs').thickness,.004);
s=snapshot('ribstiffeners');assert.equal(api.inherited(s,s.panels[1],'ribstiffeners').height,.04);assert.equal(api.update(s,'ribstiffeners','rib_stiffener:2','enabled','false')[0].enabled,false);assert.throws(()=>api.update(s,'ribstiffeners','rib_stiffener:2','height','1'),/flange thickness/i);
s=snapshot('leskins');assert.deepEqual(api.matrix(s).bays,[1,3]);assert.equal(s.panels.length,4);
s=snapshot('leribs');assert.deepEqual(api.matrix(s).bays,[1,2,3,4]);assert.deepEqual(api.compact(s,'leribs'),s);
assert.equal(api.compact({parameters,ribs:[{},{}],readOnly:true},'ribwebs').panels.length,0);
console.log('Component tables: physical indices, sparse inheritance, materials, sections, disabled LE bays, and snapshot round trips passed');
