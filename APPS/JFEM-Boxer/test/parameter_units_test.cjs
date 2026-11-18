'use strict';
const assert=require('node:assert/strict'),U=require('../web/parameter_units.js');
let checks=0;const test=(name,fn)=>{fn();checks++;console.log('PASS '+name);};
test('Component gauges, section dimensions and movable attachment thicknesses use mm',()=>{
 assert.equal(U.DIMENSION_KEYS.length,21);assert.equal(new Set(U.DIMENSION_KEYS).size,21);
 for(const key of U.DIMENSION_KEYS){assert(U.isMillimetreKey(key));assert.equal(U.displayUnit(key,'m'),'mm');assert.equal(U.toDisplay(key,.0015),1.5);assert.equal(U.toModel(key,1.5),.0015);assert.equal(U.displayStep(key),'0.1');}
});
test('Geometry, mass densities and stiffness units remain unchanged',()=>{
 for(const key of['planform.span','planform.root_chord','stringers.pitch','planform.x0','engine.length','movable_surfaces.items#clearance_inboard_m','nsm.upper_skin','nsm.stringers','movable_structure.attachments#actuator_stiffness']){
  assert(!U.isMillimetreKey(key));assert.equal(U.toDisplay(key,.123),.123);assert.equal(U.toModel(key,.123),.123);assert.equal(U.displayUnit(key,'m'),'m');assert.equal(U.displayStep(key,'any'),'any');}
 assert.equal(U.displayUnit('material.E','Pa'),'GPa');assert.equal(U.toDisplay('material.E',71e9),71);assert.equal(U.toModel('material.E',71),71e9);
 assert.match(U.displayHelp('properties.t_skin_upper','Monolithic thickness in metres.'),/thickness in millimetres/);
 assert.match(U.displayHelp('properties.t_skin_upper',''),/Saved Studies.*retain metres/);
 assert.equal(U.displayHelp('planform.span','Span in metres.'),'Span in metres.');
});
test('Clean untouched mm labels preserve the exact SI value from an older Study',()=>{
 const input={dataset:{},id:'p-properties.runout_side',value:''},exact=Math.sqrt(5e-6);
 U.writeModel(input,'properties.runout_side',exact);assert.equal(input.value,'2.236');assert.equal(U.readModel(input),exact);
 input.value='3';assert.equal(U.readModel(input),.003);
 U.writeModel(input,'properties.runout_side',exact);assert.equal(U.readModel(input),exact);
});
test('Real edits replace the retained SI value, including retyping a rounded label',()=>{
 const handlers={},doc={addEventListener:(type,fn)=>{handlers[type]=fn;}},input={dataset:{},id:'p-properties.runout_side',value:''};
 U.install(doc);U.writeModel(input,'properties.runout_side',Math.sqrt(5e-6));handlers.input({target:input});assert.equal(U.readModel(input),.002236);
 input.value='2.5';assert.equal(U.readModel(input),.0025);input.value='';assert(Number.isNaN(U.readModel(input)));input.value='invalid';assert(Number.isNaN(U.readModel(input)));
});
test('Unmarked standalone SI controls and nonconverted large identifiers stay exact',()=>{
 const input={dataset:{},id:'p-properties.t_skin_upper',value:'.0015'};assert.equal(U.readModel(input),.0015);
 U.writeModel(input,'mesh.elements_between_ribs',123456789);assert.equal(input.value,'123456789');assert.equal(U.readModel(input),123456789);
});
console.log(JSON.stringify({passed:true,checks}));
