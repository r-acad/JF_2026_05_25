"use strict";
const assert = require("node:assert/strict");
const B = require("../web/vendor/babylon.js");
const A = require("../web/annotations.js");
const engine = new B.NullEngine({ renderWidth: 900, renderHeight: 700 });
const scene = new B.Scene(engine);
const camera = new B.ArcRotateCamera("camera", -.8, .8, 7, B.Vector3.Zero(), scene);
scene.useRightHandedSystem = true;
const positions = new Float32Array([-1,0,0, 1,0,0, 0,1,0, 0,0,1]);
const element = (id, kind, name, nodes) => ({ id, group: { kind, name }, nodes: Int32Array.from(nodes) });
const state = { selectedElement: 11, elements: new Map([[11,element(11,"tria","LOWER_SKIN_RUNOUTS",[0,1,2])],
  [12,element(12,"bar","SPAR_CAPS",[0,1])], [13,element(13,"rbe3","RBE3",[3,0,1,2])]]),
  layers: new Map(["LOWER_SKIN_RUNOUTS","SPAR_CAPS","RBE3","RBE3_NODES","SPC"].map((name)=>[name,{visible:true}])),
  markers: [{kind:"SPC",node:0},{kind:"RBE3_NODES",node:3}], nodeIds:Int32Array.from([101,102,103,901]),data:{nodes:{n_structural:3}} };
const candidates = A.labelCandidates(state, positions, true, true);
const reactions=new B.Mesh('reaction-values',scene),reactionVertices=new Float32Array(58*3);
reactionVertices.set([2,3,4],3);reactionVertices.set([-2,-3,-4],3*54);
reactions.setVerticesData('position',reactionVertices,true);reactions.position.set(10,20,30);
reactions.metadata={glyphs:[{kind:'force',first_vertex:0,vertex_count:6,axis:'X',component:0,color:'#ef5f6b',value:-12000,node_index:0},{kind:'moment',first_vertex:6,vertex_count:52,axis:'Z',component:2,color:'#56a8f5',value:25,node_index:0}]};
state.layers.set('SUPPORT_FORCES',{visible:true,meshes:[reactions]});
const reactionLabels=A.supportValueCandidates(state);assert.equal(reactionLabels.length,2);assert.deepEqual(reactionLabels[0].point,[12,23,34]);assert.deepEqual(reactionLabels[1].point,[8,17,26]);assert.match(reactionLabels[0].text,/Fx -12000 N/);assert.match(reactionLabels[1].text,/Mz 25 N·m/);assert.equal(reactionLabels[0].color,'#ef5f6b');
reactionVertices.set([5,6,7],3);reactions.updateVerticesData('position',reactionVertices);assert.deepEqual(A.supportValueCandidates(state)[0].point,[15,26,37]);
state.layers.get('SUPPORT_FORCES').visible=false;assert.deepEqual(A.supportValueCandidates(state),[]);state.layers.get('SUPPORT_FORCES').visible=true;reactions.setEnabled(false);assert.deepEqual(A.supportValueCandidates(state),[]);reactions.dispose();state.layers.delete('SUPPORT_FORCES');
assert.equal(candidates.length,7);
assert.equal(candidates.find(x=>x.text==="N 101").color,A.COLORS.support);
assert.equal(candidates.find(x=>x.text==="N 901").color,A.COLORS.rbe3);
assert.equal(candidates.find(x=>x.text==="T 11").color,A.COLORS.tria);
assert.equal(candidates.find(x=>x.text==="B 12").color,A.COLORS.cap);
assert.deepEqual(candidates.find(x=>x.text==="R 13").point,[0,0,1]);
state.layers.get("LOWER_SKIN_RUNOUTS").visible=false;
assert(!A.labelCandidates(state, positions, false, true).some(x=>x.id===11));
state.layers.get("LOWER_SKIN_RUNOUTS").visible=true;
state.data.annotations={ribs:[{index:1,label:"Rib 1",anchor_nodes:[2],anchor_weights:[1]}],
  stringers:[{index:1,label:"U1",anchor_nodes:[1,2],anchor_weights:[.5,.5],runout_anchor_nodes:[0,1],runout_anchor_weights:[.5,.5]}]};
for(const name of ["RIB_WEBS","STRINGERS","STRINGER_RUNOUTS"])state.layers.set(name,{visible:true});
assert.deepEqual(A.physicalLabelCandidates(state,positions,true,true).map(x=>x.text),["R 1","U1"]);
state.layers.get("STRINGERS").visible=false;
assert.deepEqual(A.physicalLabelCandidates(state,positions,false,true)[0].point,[0,0,0],"runout-only labels attach to the visible connector");
state.layers.get("STRINGER_RUNOUTS").visible=false; state.layers.get("RIB_WEBS").visible=false;
assert.equal(A.physicalLabelCandidates(state,positions,true,true).length,0,"hidden physical members contribute no labels");
const drawing=[], controls=new Map([...["show-node-ids","show-element-ids"].map(id=>[id,{checked:true,addEventListener(){}}]),
  ...["mesh-labels-none","mesh-labels-ribs","mesh-labels-stringers","mesh-labels-both"].map(id=>[id,{checked:false,addEventListener(){}}]),
  ["id-label-size",{value:"12",addEventListener(){}}],["id-label-status",{textContent:""}]]);
const ctx={ measureText:text=>({width:text.length*7}), setTransform(){},clearRect(){drawing.length=0;},
  save(){},restore(){},beginPath(){},closePath(){},moveTo(){},lineTo(){},fill(){},fillRect(){},strokeRect(){},
  stroke(){drawing.push({kind:"stroke",width:this.lineWidth,blur:this.shadowBlur});},
  fillText(text,x,y){drawing.push({kind:"text",text,x,y,color:this.fillStyle});} };
const overlay={setAttribute(){},getContext:()=>ctx,remove(){this.removed=true;}};
const doc={defaultView:{devicePixelRatio:1},createElement:()=>overlay,getElementById:id=>controls.get(id)||null};
const canvas={ownerDocument:doc,parentElement:{appendChild(){}},clientWidth:900,clientHeight:700};
const annotations=A.create({BABYLON:B,scene,camera,engine,canvas,getState:()=>state,getPositions:()=>positions});
scene.render();annotations.render(true);
assert.equal(annotations.stats.selected.text,"CTRIA3 11");
assert(drawing.some(x=>x.kind==="stroke"&&x.width===7&&x.blur===15),"selection has a wide luminous halo");
assert(drawing.some(x=>x.text==="CTRIA3 11"&&x.color===A.COLORS.selected));
assert(annotations.stats.shown>0);
assert.match(controls.get("id-label-status").textContent,/labels shown/);
const before=annotations.stats.selected;
for(let i=0;i<3;i++) positions[3*i+1]+=.5;
annotations.invalidate();annotations.render(true);
assert.notEqual(annotations.stats.selected.y,before.y,"selection label follows deformed positions");
controls.get("show-node-ids").checked=false;controls.get("show-element-ids").checked=false;
annotations.render(true);assert.equal(annotations.stats.shown,0);
assert.equal(annotations.stats.selected.text,"CTRIA3 11","picked ID remains visible with normal IDs off");
state.layers.get("LOWER_SKIN_RUNOUTS").visible=false;
annotations.render(true);assert.equal(annotations.stats.selected,null,"hidden selected layer has no halo/ID");
state.layers.get("LOWER_SKIN_RUNOUTS").visible=true;
canvas.clientWidth=450;canvas.clientHeight=350;annotations.render(true);
assert.equal(overlay.width,450);assert.equal(overlay.height,350);
state.selectedElement=null;
state.layers.set("RIB_WEBS",{visible:true});state.layers.set("STRINGERS",{visible:true});
state.data.annotations={ribs:[{index:1,label:"Rib 1",anchor_nodes:[0],anchor_weights:[1]}],
  stringers:[{index:2,label:"Stringer 2",anchor_nodes:[3],anchor_weights:[1],eids:[12]}]};
controls.get("mesh-labels-both").checked=true;
annotations.render(true);assert.equal(annotations.stats.eligible,2,"Both radio includes physical ribs/stringers without FE ID switches");
assert(drawing.some(x=>x.text==="R 1"));assert(drawing.some(x=>x.text==="Stringer 2"));
state.layers.get("RIB_WEBS").visible=false;
annotations.render(true);assert.equal(annotations.stats.eligible,1,"physical label follows structural layer visibility");
controls.get("mesh-labels-both").checked=false;controls.get("mesh-labels-ribs").checked=true;
annotations.render(true);assert.equal(annotations.stats.eligible,0,"Ribs radio does not include stringers");
state.layers.get("RIB_WEBS").visible=true;annotations.render(true);assert.equal(annotations.stats.eligible,1);
annotations.dispose();assert(overlay.removed);scene.dispose();engine.dispose();
console.log("Annotation checks passed: typed IDs/colors, visible entities, luminous selection/ID, deformation, toggles, overlap status, resized projection and disposal.");
