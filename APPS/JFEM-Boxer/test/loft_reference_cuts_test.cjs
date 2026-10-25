'use strict';
const assert=require('node:assert/strict'),B=require('../web/vendor/babylon.js'),C=require('../web/loft_cuts.js');
let checks=0;const check=(condition,message)=>{assert(condition,message);checks++;},near=(a,b,t=3e-5)=>check(Math.abs(a-b)<=t*Math.max(1,Math.abs(a),Math.abs(b)),`${a} != ${b}`);
const engine=new B.NullEngine(),scene=new B.Scene(engine);
function tube(name,length){const positions=[],indices=[];for(const x of [0,length])for(const[y,z]of[[-1,-1],[1,-1],[1,1],[-1,1]])positions.push(x,y,z);for(let k=0;k<4;k++)indices.push(k,(k+1)%4,4+(k+1)%4,k,4+(k+1)%4,4+k);const mesh=new B.Mesh(name,scene),v=new B.VertexData();v.positions=positions;v.indices=indices;v.applyToMesh(mesh,true);return mesh;}
try{
 const parent=new B.TransformNode('loft-frame',scene);parent.position.set(3,-2,5);parent.rotationQuaternion=B.Quaternion.RotationYawPitchRoll(.23,-.14,.31);parent.scaling.set(1.3,.7,-1.1);
 const source=tube('loft',8);source.parent=parent;source.setEnabled(false);
 const refAncestor=parent.clone('separate-reference-frame',null,true),refRoot=new B.TransformNode('reference-placement',scene);refRoot.parent=refAncestor;refRoot.position.set(1,.4,-.2);refRoot.rotationQuaternion=B.Quaternion.RotationAxis(B.Axis.X,.37);refRoot.scaling.set(12,.6,2);
 const reference=tube('reference',1);reference.parent=refRoot;reference.setEnabled(false);
 let meshes=[reference],revision=0,reads=0;const read=reference.getVerticesData.bind(reference);reference.getVerticesData=(...args)=>{reads++;return read(...args);};
 const cuts=C.create({BABYLON:B,scene,parent,mesh:source,basePositions:source.getVerticesData('position'),getReferenceMeshes:()=>meshes,getReferenceRevision:()=>revision});
 check(cuts.referenceAvailable&&!cuts.referenceMesh,'Availability does not construct reference triangles or a helper');check(reads===0,'Reference triangles are lazy');
 cuts.configure({visible:true,referenceVisible:true,count:3});check(cuts.referenceMesh.isEnabled()&&!reference.isEnabled(),'Hidden imported geometry can be sectioned independently');check(cuts.referenceMesh.parent===parent,'Reference lines have exactly the loft parent');
 check(JSON.stringify(cuts.planes)===JSON.stringify([2,4,6]),'Both surfaces use the same baseline planes');
 for(const section of cuts.referenceSections){let perimeter=0;for(const[a,b]of section.segments){perimeter+=B.Vector3.Distance(B.Vector3.FromArray(a),B.Vector3.FromArray(b));for(const p of [a,b]){near(p[0],section.plane);const y=p[1]-.4,z=p[2]+.2,u=Math.cos(.37)*y+Math.sin(.37)*z,v=-Math.sin(.37)*y+Math.cos(.37)*z;check(Math.abs(Math.abs(u)-.6)<3e-5||Math.abs(Math.abs(v)-2)<3e-5,'Transformed endpoint lies on analytic rotated reference section');}}near(perimeter,4*(.6+2));}
 const builds=cuts.referenceBuilds,readCount=reads,referenceMesh=cuts.referenceMesh;
 cuts.configure({referenceVisible:false});check(!referenceMesh.isEnabled(),'Turning off reference cuts hides cached mesh');cuts.configure({referenceVisible:true});check(referenceMesh.isEnabled()&&cuts.referenceBuilds===builds&&reads===readCount,'Turning cached reference cuts on restores visibility without recomputing');
 for(let i=0;i<30;i++){const positions=source.getVerticesData('position').slice();for(let j=1;j<positions.length;j+=3)positions[j]+=.01;source.updateVerticesData('position',positions);cuts.update();scene.onBeforeRenderObservable.notifyObservers(scene);}
 check(cuts.referenceBuilds===builds&&reads===readCount,'Animating loft never rereads or recuts static reference triangles');
 cuts.configure({referenceColor:'#ff0000'});check(cuts.referenceMesh===referenceMesh&&cuts.referenceBuilds===builds,'Reference color changes reuse geometry');
 cuts.configure({count:5});check(reads===readCount&&cuts.referenceBuilds===builds+1,'Changing cut count reuses transformed reference triangles');
 cuts.configure({count:3});refRoot.position.x=3;revision++;cuts.refreshReferences();check(cuts.referenceSections[0].segments.length===0,'Moved reference no longer intersects the first unchanged plane');check(reads===readCount+1,'Reference transform revision invalidates cached positions once');
 const movedBuilds=cuts.referenceBuilds;cuts.refreshReferences();check(cuts.referenceBuilds===movedBuilds,'Appearance-only notifications do no geometry work');
 parent.position.x+=.5;parent.rotationQuaternion=B.Quaternion.RotationYawPitchRoll(.21,-.13,.29);cuts.update();check(cuts.referenceBuilds===movedBuilds+1,'A changed loft parent refreshes reference coordinates');
 const refInverse=reference.computeWorldMatrix(true).clone().invert(),world=parent.computeWorldMatrix(true);
 for(const section of cuts.referenceSections)for(const segment of section.segments)for(const p of segment){near(p[0],section.plane);const q=B.Vector3.TransformCoordinates(B.Vector3.TransformCoordinates(B.Vector3.FromArray(p),world),refInverse);check(Math.abs(Math.abs(q.y)-1)<1e-4||Math.abs(Math.abs(q.z)-1)<1e-4,'Rendered world endpoint stays on the actual reference after parent change');}
 const line=B.MeshBuilder.CreateLines('line-only',{points:[new B.Vector3(0,0,0),new B.Vector3(8,1,1)]},scene);meshes.push(line);revision++;cuts.refreshReferences();check(cuts.referenceSegmentCount>0,'Line-only helpers do not cause triangle validation errors');
 const instance=reference.createInstance('reference-instance');instance.parent=refRoot;instance.position.y=4;meshes.push(instance);revision++;cuts.refreshReferences();check(cuts.referenceSegmentCount>24,'Ordinary instances contribute their transformed surfaces');
 meshes=[];revision++;cuts.refreshReferences();check(!cuts.referenceAvailable&&cuts.referenceMesh===null&&cuts.referenceSegmentCount===0,'Removing references disposes old cut geometry');
 cuts.dispose();check(!cuts.available&&cuts.mesh===null&&cuts.referenceMesh===null,'Model disposal releases both overlays');
 // Unit conversion and general affine coordinates are independent of Babylon rendering.
 const mm=B.Matrix.Scaling(.001,.001,.001).multiply(B.Matrix.Translation(4,5,6));const converted=C.transformPositions([1000,2000,3000],mm);near(converted[0],5);near(converted[1],7);near(converted[2],9);
 assert.throws(()=>C.transformPositions([1,2,3],Array(16).fill(0)));checks++;
 console.log(JSON.stringify({passed:true,checks,scope:'Exact shared planes; transformed, mirrored, nonuniform reference hierarchy; physical endpoints; hidden references; instances; static caching; color/count changes; disposal'}));
}finally{scene.dispose();engine.dispose();}
