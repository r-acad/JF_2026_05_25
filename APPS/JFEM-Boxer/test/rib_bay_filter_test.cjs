'use strict';
const assert=require('node:assert/strict'),F=require('../web/rib_bay_filter.js'),V=require('../web/rf_field_visibility.js'),A=require('../web/annotations.js');
let passed=0;const check=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const rib=(index,y)=>({index,datum_origin:[0,y,0],datum_u:[1,0,0],datum_v:[0,0,1]}),data={annotations:{ribs:[rib(1,0),rib(2,1),rib(3,2)]}},planes=F.boundaries(F.bays(data)[0]);
check('Only physical adjacent ribs form bays; imported or missing metadata disables filtering',()=>{assert.deepEqual(F.bays(data).map(b=>b.rib),[1,2]);assert.deepEqual(F.bays({...data,imported_deck:true}),[]);assert.deepEqual(F.bays({annotations:{ribs:[rib(1,0),rib(3,2)]}}),[]);});
check('Both bounding ribs are included; neighbors sharing only boundary edges are excluded',()=>{
 assert(F.intersects([[0,0,0],[1,0,0],[1,0,1]],planes,1e-6));assert(F.intersects([[0,1,0],[1,1,0]],planes,1e-6));
 assert(!F.intersects([[0,-1,0],[1,-1,0],[1,0,0],[0,0,0]],planes,1e-6));assert(!F.intersects([[0,1,0],[1,1,0],[1,2,0],[0,2,0]],planes,1e-6));
});
check('Crossing bars and RBE attachments are whole members even with endpoints outside the bay',()=>{assert(F.intersects([[0,-.5,0],[0,1.5,0]],planes,1e-6));assert(!F.intersects([[0,1.1,0],[0,1.5,0]],planes,1e-6));});
check('Selection follows swept/slanted planes and local Z rather than global span',()=>{
 const skew={first:{...rib(1,0),datum_u:[1,1,0],datum_v:[0,1,1]},last:{...rib(2,1),datum_u:[1,1,0],datum_v:[0,1,1]}},p=F.boundaries(skew);
 assert(F.intersects([[2,4.2,2],[2,4.8,2]],p,1e-6));assert(!F.intersects([[2,.2,2],[2,.8,2]],p,1e-6));
});
check('All finite-element families retain original IDs and connectivity; LE extensions use their own planes',()=>{
 const d=structuredClone(data);for(const row of d.annotations.ribs){row.leading_edge_datum_origin=[0,row.index-1+.4,0];row.leading_edge_datum_u=[1,0,0];row.leading_edge_datum_v=[0,0,1];}
 const xyz=[[0,.2,0],[1,.8,0],[0,1.1,0],[1,1.3,0],[0,-1,0],[0,2,0]],positions=Float32Array.from(xyz.flatMap(([x,y,z])=>[y,z,x]));
 const elements=new Map([[1,{nodes:[0,1],group:{kind:'bar'}}],[2,{nodes:[2,3],group:{base_group:'UPPER_SKIN'}}],[3,{nodes:[2,3],group:{base_group:'LE_SKIN'}}],[4,{nodes:[4,5],group:{kind:'connection'}}]]),before=JSON.stringify([...elements]);
 const result=F.select(d,elements,positions,1,3);assert.deepEqual([...result.allowed],[1,3,4]);assert(result.nodes.has(5));assert.equal(JSON.stringify([...elements]),before);
});
const mesh=(indices,ids,extra={})=>{let current=Int32Array.from(indices);return{elementIds:ids,isVisible:true,metadata:{facesPerElement:1},getIndices:()=>current,setIndices(v){current=Int32Array.from(v);},...extra};};
check('Connection primitives, support glyphs, markers and FE wireframe follow the mask and restore exactly',()=>{
 const shell=mesh([0,1,2,3,4,5],[10,20]),connections=mesh([0,1,2,3],[30,40],{getClassName:()=> 'LinesMesh'}),support=mesh([0,1,2,3,4,5],null,{filterNodeMap:[0,0,0,3,3,3]}),mark=mesh([],null),overlay=mesh([],null);
 const state={shellMeshes:[shell],barMeshes:[],layers:new Map([['S',{visible:true,meshes:[shell]}],['RBE',{visible:true,meshes:[connections]}],['SPC',{visible:true,meshes:[support,mark]}],['AERO',{visible:true,meshes:[overlay]}]]),markers:[{mesh:mark,node:3}],deformable:[]},controller=V.create({state}),allowed=new Set([20,40]),nodes=new Set([3]);
 controller.sync(allowed,{ribBay:true,nodes});assert.deepEqual([...connections.getIndices()],[2,3]);assert.deepEqual([...support.getIndices()],[3,4,5]);assert(mark.isVisible);assert(!overlay.isVisible);
 controller.sync(new Set([20]));assert(!connections.isVisible);controller.sync(allowed,{ribBay:true,nodes});assert(connections.isVisible);assert.deepEqual([...connections.getIndices()],[2,3]);
 controller.restore();assert.deepEqual([...connections.getIndices()],[0,1,2,3]);assert.equal(support.getIndices().length,6);assert(overlay.isVisible);assert(state.layers.get('S').visible);
});
check('Study filter settings reject invalid indices and round-trip with defaults',()=>{assert.deepEqual(F.normalize(),{enabled:false,rib:1});assert.deepEqual(F.normalize({enabled:true,rib:4}),{enabled:true,rib:4});for(const value of[{enabled:true,rib:0},{enabled:'yes',rib:1},{enabled:true,rib:1.5}])assert.throws(()=>F.normalize(value));});
check('Single-element marker instances retain shared geometry when another marker is hidden',()=>{
 const a=mesh([0,1,2],[10],{metadata:{elementId:10},setIndices(){throw Error('Shared geometry must not change');}}),b=mesh([0,1,2],[20],{metadata:{elementId:20},setIndices(){throw Error('Shared geometry must not change');}}),state={layers:new Map([['M',{meshes:[a,b],visible:true}]]),shellMeshes:[],barMeshes:[]},controller=V.create({state});
 controller.sync(new Set([20]),{ribBay:true,nodes:new Set()});assert(!a.isVisible&&b.isVisible);controller.restore();assert(a.isVisible&&b.isVisible);
});
check('Free in-bay node labels and selected GRID highlights survive bay filtering but not a combined empty RF filter',()=>{
 const mark=mesh([],null),selection=mesh([],null,{metadata:{nodeSelection:true}}),state={data:{nodes:{n_structural:2}},layers:new Map([['NODES',{visible:true,meshes:[mark]}]]),elements:new Map(),markers:[{kind:'NODES',mesh:mark,node:1}],nodeIds:[100,101],selectedNode:1,selectedElement:null,selectionMesh:selection,ribBayFilter:{active:true,nodes:new Set([1])},rfVisibleElementIds:new Set()},positions=Float32Array.from([0,0,0,1,0,0]);
 assert.deepEqual(A.labelCandidates(state,positions,true,false).map(c=>c.id),[101]);
 const controller=V.create({state});controller.sync(new Set(),{ribBay:true,nodes:state.ribBayFilter.nodes});assert(selection.isVisible);
 state.rfField={request:{onlyBelowOne:true}};controller.sync(new Set());assert.deepEqual(A.labelCandidates(state,positions,true,false),[]);assert(!selection.isVisible);controller.restore();
});
check('Reaction value labels follow the filtered node set after glyph draw indices are compacted',()=>{
 const reactions=mesh([0,1,2],null,{metadata:{glyphs:[{node_index:1,kind:'force',label_vertex:0,value:5,axis:'X'},{node_index:2,kind:'force',label_vertex:1,value:7,axis:'Y'}]},getVerticesData:()=>Float32Array.from([0,0,0,1,0,0]),computeWorldMatrix:()=>null}),state={layers:new Map([['SUPPORT_FORCES',{visible:true,meshes:[reactions]}]]),ribBayFilter:{active:true,nodes:new Set([1])}};
 assert.deepEqual(A.supportValueCandidates(state,true,false).map(c=>c.id),[1]);
});
console.log(passed+' rib bay filter tests passed.');
