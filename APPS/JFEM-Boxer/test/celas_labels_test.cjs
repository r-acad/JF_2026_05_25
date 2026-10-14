'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const E=require('../web/model_entities.js'),A=require('../web/annotations.js'),B=require('../web/vendor/babylon.js');
const systems=[{id:0,type:'RECTANGULAR',card:'BASIC'},
 {id:10,type:'RECTANGULAR',card:'CORD2R',properties:{RID:0}},
 {id:20,type:'CYLINDRICAL',card:'CORD2C',properties:{RID:10}},
 {id:30,type:'SPHERICAL',card:'CORD2S',properties:{RID:20}},
 {id:40,type:'RECTANGULAR',card:'CORD1R',properties:{G1:101,G2:102,G3:103}}];
const end=(number,grid,node,component,coordinate_id,axis)=>({end:number,grid,node,component,coordinate_id,axis,grounded:grid===0});
const elements=[
 {eid:1,type:'CELAS1',nodes:[0,1],properties:{PID:91,property:{K:1234.56789,GE:.005,S:2}},endpoints:[end(1,101,0,1,10,[0,1,0]),end(2,102,1,2,20,[-1,0,0])]},
 {eid:2,type:'CELAS2',nodes:[1,2],properties:{K:5e6,GE:.02,S:3},endpoints:[end(1,102,1,3,30,[0,0,1]),end(2,103,2,5,40,[0,1,0])]},
 {eid:3,type:'CELAS2',nodes:[2],properties:{K:42},endpoints:[end(1,103,2,4,0,[1,0,0]),end(2,0,-1,0,undefined,null)]},
 {eid:4,type:'CELAS1',nodes:[3],properties:{PID:92},endpoints:[end(1,104,3,1,99,null),end(2,105,-1,0,undefined,null)]},
 {eid:5,type:'CELAS3',nodes:[],properties:{PID:93,property:{K:100},S1:501,S2:502}},
 {eid:6,type:'CELAS4',nodes:[],properties:{K:200,S1:503,S2:0}}
];
const data={coordinate_systems:{systems},imported_connections:elements.map(element=>({card:element.type,name:'SPRING_'+element.eid,elements:[element]}))};
const positions=Float32Array.of(0,0,0, 1,0,0, 0,1,0, 1,1,0),layers=new Map(elements.map(el=>['SPRING_'+el.eid,{visible:true,color:'#eb61cc'}]));
const state={data,layers,elements:new Map(elements.filter(e=>e.nodes.length).map(el=>[el.eid,{id:el.eid,nodes:Int32Array.from(el.nodes),group:{name:'SPRING_'+el.eid,kind:'spring',card_types:{[el.eid]:el.type}}}])),markers:[],nodeIds:Int32Array.of(101,102,103,104),diag:3};
const checks=[],labels=E.springCandidates(state,positions,true),by=id=>labels.find(row=>row.id===id);
assert.equal(labels.length,4);assert.match(by(1).text,/CELAS1 1 · PELAS 91 · K=1234\.6 · GE=0\.005 · S=2/);
assert.match(by(1).text,/G1 101 · DOF 1 \(translation x\) · CD 10 Rectangular · RID 0/);
assert.match(by(1).text,/G2 102 · DOF 2 \(translation θ\) · CD 20 Cylindrical · RID 10/);
assert.match(by(2).text,/CELAS2 2 · direct stiffness · K=5000000/);assert(!by(2).text.includes('PELAS'));
assert.match(by(2).text,/translation φ \(azimuth\).*CD 30 Spherical.*RID 20/);
assert.match(by(2).text,/rotation y.*CD 40 Rectangular.*G1 101, G2 102, G3 103/);
assert.equal(E.springPropertyLabel({...elements[1],properties:{...elements[1].properties,PID:999}}).includes('PELAS'),false,'Direct stiffness never borrows a property ID');
checks.push('PELAS vs direct K, damping/stress coefficient and rectangular/cylindrical/spherical/rotation DOFs retain correct source definitions and coordinate parents');
assert.match(by(3).text,/rotation x.*CD 0 Rectangular.*BASIC/);assert.match(by(3).text,/End 2: ground \(no GRID or coordinate axes\)/);
assert.match(by(4).text,/PELAS 92 · K=unavailable/);assert.match(by(4).text,/CD 99 \(type unavailable\) · axis unavailable/);assert.match(by(4).text,/scalar 105 · DOF 0 · no spatial coordinate axes/);
assert.equal(E.springPropertyLabel(elements[4]),'CELAS3 5 · PELAS 93 · K=100');assert.equal(E.springPropertyLabel(elements[5]),'CELAS4 6 · direct stiffness · K=200');
assert(!labels.some(row=>row.id>=5),'Unlocated scalar points must not acquire invented label coordinates');
assert.equal(E.springGlyphs({elements:[elements[4],elements[5]]}).length,0);assert.match(E.springEndpointLabel({end:1,grid:7,component:1},new Map()),/CD unavailable · axis unavailable/);
checks.push('Grounded, scalar, missing property and unresolved-coordinate cases stay explicit; scalar-only CELAS3/4 have no invented spatial glyph or label location');
assert.deepEqual(by(1).point,[.5,0,0]);const moved=Float32Array.from(positions,(v,i)=>v+[.25,-.5,.75][i%3]);
const deformed=E.springCandidates(state,moved,true).find(row=>row.id===1);assert.deepEqual(deformed.point,[.75,-.5,.75]);assert.deepEqual(deformed.lines,by(1).lines);
layers.get('SPRING_2').visible=false;assert(!E.springCandidates(state,moved,true).some(row=>row.id===2));assert.deepEqual(E.springCandidates(state,moved,false),[]);layers.get('SPRING_2').visible=true;
checks.push('Labels follow displayed endpoint coordinates and source-layer visibility while metadata remains unchanged; coordinate-triad visibility is independent');
const engine=new B.NullEngine({renderWidth:900,renderHeight:700}),scene=new B.Scene(engine),camera=new B.ArcRotateCamera('camera',-.8,.8,6,new B.Vector3(.5,.5,0),scene);
const drawing=[],controls=new Map([['show-celas-labels',{checked:true,addEventListener(){}}],['id-label-size',{value:'11',addEventListener(){}}],['id-label-status',{textContent:''}]]);
const ctx={measureText:text=>({width:text.length*6}),setTransform(){},clearRect(){drawing.length=0;},save(){},restore(){},beginPath(){},closePath(){},moveTo(){},lineTo(){},fill(){},fillRect(){},strokeRect(){},stroke(){},fillText(text,x,y){drawing.push({text,x,y});}};
const overlay={setAttribute(){},getContext:()=>ctx,remove(){}},doc={defaultView:{devicePixelRatio:1},createElement:()=>overlay,getElementById:id=>controls.get(id)||null},canvas={ownerDocument:doc,parentElement:{appendChild(){}},clientWidth:900,clientHeight:700};
global.WingModelEntities=E;
try{
 state.selectedElement=1;const renderer=A.create({BABYLON:B,scene,camera,engine,canvas,getState:()=>state,getPositions:()=>positions});scene.render();renderer.render(true);
 assert(renderer.stats.springPropertiesShown.includes(1));assert(drawing.some(row=>row.text.includes('PELAS 91')));assert(drawing.some(row=>row.text.includes('CD 20 Cylindrical')));
 const selected=renderer.stats.selected;assert.match(selected.text,/CELAS1 1.*PELAS 91/);
 canvas.clientWidth=300;renderer.render(true);assert(drawing.some(row=>row.text.includes('CD 20 Cylindrical')));assert(drawing.every(row=>!row.text.includes('\n')),'Canvas receives a separate call per wrapped line');
 controls.get('show-celas-labels').checked=false;renderer.render(true);assert.equal(renderer.stats.selected.text,'CELAS1 1');assert(!drawing.some(row=>row.text.includes('PELAS')));
 renderer.dispose();checks.push('Real annotation renderer draws multiline spring metadata, wraps narrow viewports, includes selected springs once, and returns to ordinary selected IDs when disabled');
}finally{delete global.WingModelEntities;scene.dispose();engine.dispose();}
if(process.argv[2]){const out=path.resolve(process.argv[2]);fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'celas-labels-summary.json'),JSON.stringify({passed:true,checks},null,2));}
console.log('CELAS labels passed '+checks.length+' groups.');
