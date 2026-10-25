'use strict';
const assert=require('node:assert/strict'),E=require('../web/model_entities.js'),B=require('../web/vendor/babylon.js'),W=require('../web/workspace.js');
const engine=new B.NullEngine(),scene=new B.Scene(engine),positions=Float32Array.from([2,3,4,5,7,4]);
const element=(eid,p={})=>({eid,nodes:[0,1],type:'CBUSH',properties:{actuator_eid:eid,pid:36000001,axis_system:81000001,actuator_axis:[0,.6,.8],K1_N_per_m:23456.789,surface:'Flap',...p}});
const collection={card:'CBUSH',name:'MOVABLE_HINGES',elements:[element(12)]},state={scene,root:new B.TransformNode('model',scene),deformable:[],data:{imported_connections:[collection]},layers:new Map([['MOVABLE_HINGES',{visible:true}]])};
const near=(a,b)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<1e-6,JSON.stringify({a,b})));
const capCenters=mesh=>[-.5,.5].map(y=>B.Vector3.TransformCoordinates(new B.Vector3(0,y,0),mesh.computeWorldMatrix(true)).asArray());
try{
 const glyph=E.actuatorGlyphs(collection)[0];assert.deepEqual(glyph.axis,[.6,.8,0]);assert.equal(glyph.stiffness,23456.789);assert.equal(glyph.legacy,false);assert(glyph.axial);
 assert.deepEqual(E.actuatorLabel(glyph),['Actuator CBUSH 12 · PBUSH 36000001','K1 = 23457 N/m · CID 81000001 x']);
 assert.equal(E.actuatorGlyphs({card:'CBUSH',elements:[element(14,{actuator_eid:null,fitting:'shell_lugs',kind:'hinge',joint_eid:14,hinge_stiffness:99})]}).length,0);
 assert.equal(E.actuatorGlyphs({card:'CBUSH',elements:[element(14,{kind:'rigid'})]}).length,0);
 const legacy=E.actuatorGlyphs({card:'CBUSH',elements:[element(15,{actuator_eid:null,fitting:'idealized',kind:'hinge',joint_eid:15,hinge_stiffness:99,hinge_axis:[1,0,0]})]})[0];assert.equal(legacy.role,'Hinge restraint');assert.equal(legacy.stiffness,99);assert(!legacy.axial);assert(E.actuatorLabel(legacy)[1].startsWith('K4 = 99 N·m/rad'));
 assert.equal(E.actuatorGlyphs({card:'CBUSH',elements:[element(16,{K1_N_per_m:0}),element(17,{actuator_axis:[0,0,0]})]}).length,0);
 const meshes=E.actuatorMeshes(B,{state,positions,collection,diag:10});assert.equal(meshes.length,1);const mesh=meshes[0],record=state.deformable[0];assert(mesh.getTotalVertices()>40);assert(mesh.actuatorCylinder&&mesh.isPickable&&mesh.metadata.displayOnly);assert.equal(mesh.metadata.elementId,12);near(mesh.position.asArray(),[3.5,5,4]);assert.equal(mesh.scaling.y,5);
 near(B.Axis.Y.applyRotationQuaternion(mesh.rotationQuaternion).asArray(),[.6,.8,0]);assert.equal(E.pickedElementId({hit:true,pickedMesh:mesh,faceId:0}),12);
 let ends=capCenters(mesh);near(ends[0],[2,3,4]);near(ends[1],[5,7,4]);
 const moved=Float32Array.from([3,5,7,4,7,9]),rotations=Float64Array.from([0,0,Math.PI/2,0,0,0]),explosion={offsetElement:()=>[.1,.2,.3],point:(_,p)=>p.map((v,i)=>v+[.1,.2,.3][i])};
 E.updateActuatorMesh(B,record,moved,rotations,1,explosion);near(mesh.position.asArray(),[3.6,6.2,8.3]);near(B.Axis.Y.applyRotationQuaternion(mesh.rotationQuaternion).asArray(),[1/3,2/3,2/3]);assert.equal(mesh.scaling.y,3);
 ends=capCenters(mesh);near(ends[0],[3.1,5.2,7.3]);near(ends[1],[4.1,7.2,9.3]);
 state.panelExplosion=explosion;const label=E.actuatorCandidates(state,moved,true)[0];near(label.point,mesh.position.asArray());assert.equal(label.id,12);assert(label.text.includes('K1 = 23457 N/m'));
 E.updateActuatorMesh(B,record,Float32Array.from([0,0,0,0,0,0]),null,0);assert(!mesh.isVisible);E.updateActuatorMesh(B,record,positions,null,0);assert(mesh.isVisible);
 state.layers.get('MOVABLE_HINGES').visible=false;assert.deepEqual(E.actuatorCandidates(state,moved,true),[]);assert.deepEqual(E.actuatorCandidates(state,moved,false),[]);assert(W.CONTROL_IDS.includes('show-actuator-stiffness'));
 console.log('Axial actuator display: actual endpoint length/orientation, cap locations, two-end deformation, picking, K1 units/frame, legacy restraint distinction, degenerate pose, visibility and persistence passed.');
}finally{scene.dispose();engine.dispose();}
