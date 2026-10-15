'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const B=require('../web/vendor/babylon.js'),Mass=require('../web/mass_properties.js');
const engine=new B.NullEngine(),scene=new B.Scene(engine),parent=new B.TransformNode('model',scene);
const close=(a,b)=>a.forEach((x,i)=>assert(Math.abs(x-b[i])<1e-9,`${x} != ${b[i]}`));
const bay={kind:'structural',index:2,start_rib:2,end_rib:3,reference_node:9,reference_grid:110,mass_kg:12,
 reference_m:[2,3,4],center_of_gravity_m:[2.2,3.4,3.9],inertia_kg_m2:[[2,.1,0],[.1,3,.2],[0,.2,4]]};
const checks=[];
try{
 const display=Mass.create({BABYLON:B,scene,parent,kind:'structural'});
 const first=display.update({enabled:true,fuel:{bays:[bay]},showCG:true});assert.equal(first.errors.length,0);
 for(const suffix of ['ellipsoid','principal-axes','principal-ellipses','reference']){
  const mesh=display.meshes.find(m=>m.name===`structural-mass-${suffix}-2`);assert(mesh.isEnabled());close(mesh.position.asArray(),Mass.toView(bay.reference_m));
  assert.equal(mesh.metadata.rib_bay,2);assert.equal(mesh.metadata.inertia_origin,'bay_reference');assert.equal(mesh.metadata.reference_grid,110);
  assert.match(mesh.metadata.label,/bay reference GRID 110/);assert.match(mesh.metadata.label,/True CG:/);assert.equal(mesh.metadata.fuelMassGlyph,false);
 }
 close(display.meshes.find(m=>m.name==='structural-mass-cg-2').position.asArray(),Mass.toView(bay.center_of_gravity_m));
 assert(display.meshes.find(m=>m.name==='structural-mass-offset-2').isEnabled());
 checks.push('Real Babylon meshes are anchored to the bay GRID, with a separate true-CG marker and explicit structural metadata');
 const r=bay.center_of_gravity_m.map((v,i)=>v-bay.reference_m[i]),r2=r.reduce((s,v)=>s+v*v,0);
 for(let i=0;i<3;i++)for(let j=0;j<3;j++)assert(Math.abs(first.bays[0].inertia[i][j]-bay.inertia_kg_m2[i][j]-bay.mass_kg*((i===j?r2:0)-r[i]*r[j]))<1e-12);
 checks.push('Displayed inertia uses the parallel-axis theorem from the conserved central tensor');
 const count=scene.meshes.length,delta=[11,-7,2],moved={...bay,reference_grid:null,reference_m:bay.reference_m.map((v,i)=>v+delta[i]),center_of_gravity_m:bay.center_of_gravity_m.map((v,i)=>v+delta[i])};
 const second=display.update({fuel:{bays:[moved]},scale:2});assert.equal(scene.meshes.length,count);close(second.bays[0].radii,first.bays[0].radii);
 assert.match(second.bays[0].label,/computed bay reference \(no GRID\)/);assert(!second.bays[0].label.includes('fuel node'));
 close(display.meshes.find(m=>m.name==='structural-mass-ellipsoid-2').position.asArray(),Mass.toView(moved.reference_m));
 display.setEnabled(false);assert(display.meshes.every(m=>!m.isEnabled()));display.setEnabled(true);assert(display.meshes.some(m=>m.isEnabled()));
 checks.push('Translation, scale and hide/show preserve mass properties, reuse meshes and label a computed anchor honestly');
 const app=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),start=app.indexOf('function refreshStructuralMassProperties(){'),end=app.indexOf('\nfunction modelEntityGroups()',start);
 const controls=new Map([['show-structural-inertia',{checked:true}],['structural-inertia-scale',{value:'1'}],['structural-mass-status',{}]]);
 const state={structuralMassDisplay:display,data:{weights:{structural_inertia:[bay]}},layers:new Map(),diag:10};
 const context=vm.createContext({state,document:{getElementById:id=>controls.get(id)},markerRadius:()=>.01,eng:String});
 vm.runInContext(app.slice(start,end)+'\nrefreshStructuralMassProperties()',context);
 assert.match(controls.get('structural-mass-status').textContent,/1 structural rib bays; 12 kg/);assert.match(controls.get('structural-mass-status').title,/True CG:/);
 assert.equal(state.layers.get('STRUCTURAL_INERTIA').count,'1 rib bays');assert(display.meshes.find(m=>m.name==='structural-mass-cg-2').isEnabled());
 state.importedDeck={};state.data={};vm.runInContext('refreshStructuralMassProperties()',context);
 assert(controls.get('show-structural-inertia').disabled);assert.match(controls.get('structural-mass-status').textContent,/unavailable for imported/);assert(display.meshes.every(m=>!m.isEnabled()));
 checks.push('Actual app refresh reports bay totals/CG tooltip and safely disables unavailable imported-model aggregation');
 display.dispose();assert.equal(scene.meshes.length,0);
 const fuel=Mass.ellipsoidData({...bay,kind:'fuel'});assert.match(fuel.label,/About fuel node/);
 checks.push('Disposal releases all glyph resources and existing fuel labels remain compatible');
 console.log(`Structural mass display passed ${checks.length} groups.`);
 if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});fs.writeFileSync(path.join(process.argv[2],'structural-mass-display-summary.json'),JSON.stringify({passed:true,checks},null,2));}
}finally{scene.dispose();engine.dispose();}
