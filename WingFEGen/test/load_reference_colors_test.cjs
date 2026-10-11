'use strict';
// Exercise the actual app attachment/marker/deformation code with Babylon,
// using a small explicit reference-role fixture (no solver or private deck).
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const B=require('../web/vendor/babylon.js'),Export=require('../web/geometry_export.js'),Annotations=require('../web/annotations.js'),Mass=require('../web/mass_properties.js');
const app=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
function section(start,end){const a=app.indexOf(start),b=app.indexOf(end,a);assert(a>=0&&b>a,`Missing production section ${start}`);return app.slice(a,b);}
const colors={aero:'#e45ad4',mass:'#146b3a',imported:'#f8cee2',spider:'#f4b8d6',structural:'#ecf4ff'};
const engine=new B.NullEngine(),scene=new B.Scene(engine),checks=[];
const xyz=Float32Array.of(0,0,0, 2,0,0, 0,2,0, 2,2,0, 1,0,.3, 1,1,.1, 1,2,.3, 1,1.6,.1),ids=Int32Array.from({length:8},(_,i)=>101+i);
const spider=(refs,eids,role)=>({count:refs.length,refs:Int32Array.from(refs),eids:Int32Array.from(eids),lines:Int32Array.from(refs.flatMap(ref=>[ref,0,ref,1,ref,2,ref,3])),elements:refs.map((ref,i)=>({ref,eid:eids[i],reference_grid:ids[ref],connected_grids:Array.from(ids.slice(0,4)),reference_components:'123456',...(role?{reference_role:role[i],massless:role[i]==='massless_inertia'}:{})}))});
const fixture={nodes:{count:8,n_structural:4,xyz,ids},groups:[],rbe3:spider([4,6],[401,402]),fuel_rbe3:spider([5,7],[501,502],['fuel_property','massless_inertia']),loads:{stations:[]},aero:{count:0},spc:{count:0,nodes:new Int32Array()},fuel:{enabled:false}};
const state={scene,root:new B.TransformNode('model',scene),nodeIds:ids,markers:[],deformable:[],layers:new Map(),elements:new Map(),baseline:xyz,data:fixture};
const context=vm.createContext({BABYLON:B,WingGeometryExport:Export,state,DEFAULT_HIDDEN:new Set(['NODES']),
 asI32:v=>v,markerRadius:()=>.08,vec:(v,i)=>B.Vector3.FromArray(v,3*i),color3:B.Color3.FromHexString,
 updateSurfaceNormals(){},updateVlmPose(){},applyPanelMeshOffsets(){},updateSelection(){},document:{getElementById:()=>({checked:false})}});
vm.runInContext(section('const EXTRA_STYLE =','const DEFAULT_HIDDEN'),context);
for(const [start,end]of[['function addLayer(','function shellMesh('],['function lineMesh(','function barSectionMesh('],['function markerMesh(','/** Unique element edges'],['function pushPositions(','const COLOR_SCALES']])vm.runInContext(section(start,end),context);
const attachments=section('  const attachmentLoads =','  if(typeof WingModelEntities');
const hex=material=>material.diffuseColor.toHexString().toLowerCase(),near=(actual,expected)=>assert(Math.abs(actual-expected)<1e-6,`${actual} != ${expected}`);
const rgb=hex=>[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255).concat(1);
(async()=>{try{
 context.data=fixture;context.positions=xyz;context.diag=3;vm.runInContext(attachments,context);
 assert.equal(state.layers.get('RBE3_NODES').color,colors.aero);assert.equal(state.layers.get('FUEL_RBE3_NODES').color,colors.mass);
 for(const [name,color,refs]of[['RBE3_NODES',colors.aero,[4,6]],['FUEL_RBE3_NODES',colors.mass,[5,7]]]){
  const layer=state.layers.get(name);assert.equal(layer.meshes.length,2);for(let i=0;i<2;i++){const mesh=layer.meshes[i];assert.equal(hex(mesh.material),color);assert.deepEqual(mesh.position.asArray(),Array.from(xyz.slice(3*refs[i],3*refs[i]+3)));assert.equal(mesh.parent,state.root);}
 }
 for(const name of ['RBE3','FUEL_RBE3'])assert.equal(state.layers.get(name).color,colors.spider);
 assert.match(state.layers.get('RBE3_NODES').label,/Aerodynamic/);assert.match(state.layers.get('FUEL_RBE3_NODES').label,/structural/);
 checks.push('Known generated aerodynamic reference spheres are magenta; both fuel and massless structural reference spheres are dark green; spider lines stay pink');
 const moved=Float32Array.from(xyz,(v,i)=>v+[.1,-.2,.3][i%3]);context.moved=moved;vm.runInContext('pushPositions(moved)',context);
 for(const marker of state.markers){marker.mesh.position.asArray().forEach((v,i)=>near(v,moved[3*marker.node+i]));assert.equal(hex(marker.mesh.material),marker.kind==='RBE3_NODES'?colors.aero:colors.mass);}
 const labels=Annotations.labelCandidates(state,moved,true,false);for(const ref of [4,6])assert.equal(labels.find(x=>x.id===ids[ref]).color,colors.aero);for(const ref of [5,7])assert.equal(labels.find(x=>x.id===ids[ref]).color,colors.mass);
 checks.push('Spheres, instanced spheres and ID labels retain their role colors at the displayed deformed coordinates');
 const fuel=Mass.create({BABYLON:B,scene,parent:state.root});fuel.update({enabled:true,fuel:{bays:[{index:1,mass_kg:1,reference_m:[1,1,.1],center_of_gravity_m:[1,1,.12],inertia_kg_m2:[[1,0,0],[0,2,0],[0,0,3]]}]}});
 assert.equal(fuel.meshes.find(m=>m.name==='fuel-mass-reference-1').material.emissiveColor.toHexString().toLowerCase(),colors.mass);
 assert.equal(fuel.meshes.find(m=>m.name==='fuel-mass-cg-1').material.emissiveColor.toHexString().toLowerCase(),'#f6b758');fuel.dispose();
 checks.push('Optional inertia ellipsoid reference markers use the same dark green without recoloring their orange CG or principal axes');
 const exported=await Export.collect({data:fixture,diag:3,positions:moved},{scope:'all',references:false,displayed:true});
 for(const [name,color]of [['RBE3_NODES',colors.aero],['FUEL_RBE3_NODES',colors.mass],['NODES',colors.structural]])assert.deepEqual(exported.parts.find(p=>p.extras.component===name).color,rgb(color));
 const exportedAero=exported.parts.find(p=>p.extras.component==='RBE3_NODES');for(let axis=0;axis<3;axis++){const values=Array.from(exportedAero.positions.slice(0,72)).filter((_,i)=>i%3===axis);near((Math.min(...values)+Math.max(...values))/2,moved[12+axis]);}
 checks.push('Geometry interchange exports preserve aerodynamic/mass reference colors and displayed coordinates while structural GRID markers retain their color');
 const imported={...fixture,imported_deck:{name:'explicit-import.bdf'},fuel_rbe3:spider([],[])};context.data=imported;state.data=imported;state.layers.clear();state.markers=[];state.deformable=[];
 vm.runInContext(`{${attachments}}`,context);assert.equal(state.layers.get('RBE3_NODES').color,colors.imported);assert(state.layers.get('RBE3_NODES').meshes.every(m=>hex(m.material)===colors.imported));
 assert.match(state.layers.get('RBE3_NODES').label,/RBE3 reference/);assert(Annotations.labelCandidates(state,xyz,true,false).filter(x=>[105,107].includes(x.id)).every(x=>x.color===colors.imported));
 const importedExport=await Export.collect({data:imported,diag:3},{scope:'all',references:false});assert.deepEqual(importedExport.parts.find(p=>p.extras.component==='RBE3_NODES').color,rgb(colors.imported));
 checks.push('Imported RBE3s remain generic pink in real marker materials, ID labels and exports; aerodynamic/mass roles are never guessed');
 const summary={passed:true,checks};if(process.argv[2]){const out=path.resolve(process.argv[2]);fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'load-reference-colors-summary.json'),JSON.stringify(summary,null,2));}console.log('Load reference colors passed '+checks.length+' groups.');
 }finally{scene.dispose();engine.dispose();}})().catch(error=>{console.error(error.stack);process.exitCode=1;});
