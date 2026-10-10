'use strict';
const assert=require('node:assert/strict'),B=require('../web/vendor/babylon.js'),S=require('../web/sections.js'),H=require('../web/shell_thickness.js'),R=require('../web/imported_render.js');
const close=(a,b,t=2e-6)=>assert(Math.abs(a-b)<=t*Math.max(1,Math.abs(b)),`${a} != ${b}`);
const area=p=>Math.abs(p.reduce((s,a,i)=>{const b=p[(i+1)%p.length];return s+a[0]*b[1]-b[0]*a[1];},0)/2);
function volume(d,e=0){const p=d.positions,n=d.verticesPerElement;let result=0;for(let k=3*e*n;k<3*(e+1)*n;k+=9)result+=(p[k]*(p[k+4]*p[k+8]-p[k+5]*p[k+7])+p[k+1]*(p[k+5]*p[k+6]-p[k+3]*p[k+8])+p[k+2]*(p[k+3]*p[k+7]-p[k+4]*p[k+6]))/6;return result;}
const xyz=Float32Array.of(0,0,0,2,0,0,0,2,0,2,2,0),conn=Int32Array.of(0,1,2,3),orient=Float32Array.of(0,1,0,0,1,0);
for(const rod of [false,true]){const source={type:rod?'PROD':'PBAR',area_m2:.16,I1_m4:5e-6,J_m4:8e-8},before=JSON.stringify(source),section=S.displaySection(source,rod);close(area(section.polygon_yz_m),.16);assert.equal(section.equivalent,true);assert.match(section.display_note,/not inferred/);assert.equal(JSON.stringify(source),before);const geometry=S.geometry(xyz,conn,orient,section);close(volume(geometry,0),.32);close(volume(geometry,1),.32);}
const actual={type:'PBARL',polygon_yz_m:[[0,0],[1,0],[0,1]]};assert.equal(S.displaySection(actual),actual);assert.equal(S.displaySection({area_m2:0}),null);
const varying=S.displaySection({areas_m2:Float64Array.of(.04,.25)}),varied=S.geometry(xyz,conn,orient,varying);close(volume(varied,0),.08);close(volume(varied,1),.5);
const surface=Float32Array.of(0,0,0,2,0,0,2,1,0,0,1,0),group={kind:'quad',count:1,properties:{thickness_m:.1,z_bottom_m:-.02,z_top_m:.08}};
const bounds=H.boundsForGroup(group);assert.deepEqual(Array.from(bounds),[-.02,.08]);const shell=H.geometry(surface,Int32Array.of(0,1,2,3),4,bounds);close(volume(shell),.2);close(Math.min(...shell.positions.filter((_,i)=>i%3===2)),-.02);close(Math.max(...shell.positions.filter((_,i)=>i%3===2)),.08);
const triangle=H.geometry(surface,Int32Array.of(0,1,2),3,Float64Array.of(-.05,.05));close(volume(triangle),.1);assert.equal(H.boundsForGroup({kind:'quad',count:1,properties:{}}),null);
for(const properties of [{thickness_m:-1},{thickness_m:NaN},{thickness_m:.1,z_bottom_m:Infinity},{thickness_m:.1,z_bottom_m:1,z_top_m:0},{thickness_m:1e40}])assert.equal(H.boundsForGroup({kind:'quad',count:1,properties}),null);
const engine=new B.NullEngine(),scene=new B.Scene(engine);scene.useRightHandedSystem=true;
try{const mesh=H.createMesh(B,{name:'shell',scene,positions:surface,conn:Int32Array.of(0,1,2,3),nodesPerElement:4,bounds});mesh.material=new B.StandardMaterial('shell',scene);mesh.material.backFaceCulling=false;mesh.computeWorldMatrix(true);
 const normals=mesh.getVerticesData(B.VertexBuffer.NormalKind);for(let i=0;i<normals.length;i+=3)close(Math.hypot(...normals.slice(i,i+3)),1);assert(normals.every(Number.isFinite));
 const ray=new B.Ray(new B.Vector3(1,.5,2),new B.Vector3(0,0,-1));const hit=ray.intersectsMesh(mesh);assert(hit.hit);close(hit.pickedPoint.z,.08);assert.equal(mesh.shellThicknessGeometry.faceElements[hit.faceId],0);
 const tilted=surface.slice();for(let i=0;i<tilted.length;i+=3)tilted[i+2]=.5*tilted[i];H.updateMesh(B,mesh,tilted);assert(mesh.getVerticesData(B.VertexBuffer.PositionKind).every(Number.isFinite));close(volume(mesh.shellThicknessGeometry),Math.sqrt(1.25)*.2);
}finally{engine.dispose();}
const bytes=a=>new Uint8Array(a.buffer),read=a=>new Int32Array(a.buffer,a.byteOffset,a.byteLength/4),readFloat=a=>new Float32Array(a.buffer,a.byteOffset,a.byteLength/4);
const groups=Array.from({length:1200},(_,i)=>({name:(i%2?'IMPORTED_CROD_':'IMPORTED_BAR_')+i,kind:'bar',pid:i,count:1,eids:bytes(Int32Array.of(i+1)),conn:bytes(Int32Array.of(0,1)),orient:bytes(Float32Array.of(0,1,0)),properties:{type:i%2?'PROD':'PBAR',section:{area_m2:(i+1)/10000}}}));
const batches=R.batches(groups,read,readFloat);assert.equal(batches.length,2);for(const batch of batches){const section=S.displaySection(batch.properties.section),geom=S.geometry(xyz,read(batch.conn),readFloat(batch.orient),section);for(let e=0;e<batch.count;e++)close(volume(geom,e),2*batch.sourceRanges[e].group.properties.section.area_m2);}
console.log('Solid geometry passed: exact equivalent areas, true PBARL preservation, thickness/Z0, closed outward normals, ray picking, deformation and per-element batch areas.');
