'use strict';
const assert=require('node:assert/strict'),C=require('../web/loft_cuts.js');
let checks=0;const check=(value,message)=>{assert(value,message);checks++;},near=(a,b,t=1e-10)=>check(Math.abs(a-b)<=t,`${a} != ${b}`);
function loft(stations=[0,1]){
 const positions=[],indices=[];
 for(const eta of stations)for(const[qx,qz]of[[-1,-1],[1,-1],[1,1],[-1,1]])positions.push(10+8*eta,3+.7*eta+(1+.2*eta)*qz,-2+4*eta+(2-.5*eta)*qx);
 for(let j=0;j<stations.length-1;j++)for(let k=0;k<4;k++){const a=4*j+k,b=4*j+(k+1)%4,c=4*(j+1)+(k+1)%4,d=4*(j+1)+k;indices.push(a,b,c,a,c,d);}
 return{positions,indices};
}
function totalLength(section){return section.segments.reduce((sum,[a,b])=>sum+Math.hypot(...a.map((v,i)=>v-b[i])),0);}
const model=loft(),planes=C.equallySpacedPlanes(model.positions,3);
check(JSON.stringify(planes)===JSON.stringify([12,14,16]),'Equally spaced internal planes exclude root and tip.');
const cuts=C.intersectTriangles(model.positions,model.indices,planes);
check(cuts.segmentCount===24,'Two triangular segments on each of four side faces.');
for(let i=0;i<cuts.sections.length;i++){
 const section=cuts.sections[i],eta=(planes[i]-10)/8,cx=-2+4*eta,cz=3+.7*eta,chord=2-.5*eta,height=1+.2*eta;
 near(totalLength(section),4*(chord+height));
 for(const[a,b]of section.segments)for(const p of[a,b]){
  near(p[0],planes[i]);
  const dx=Math.abs(p[2]-cx),dz=Math.abs(p[1]-cz);
  check(Math.abs(dx-chord)<1e-10||Math.abs(dz-height)<1e-10,'Cut lies on the swept, tapered, dihedral surface.');
 }
}
const throughRow=loft([0,.5,1]),row=C.intersectTriangles(throughRow.positions,throughRow.indices,[14]);
check(row.segmentCount===4,'A plane on a shared row deduplicates its four edges.');near(totalLength(row.sections[0]),4*(1.75+1.1));
const capPositions=[0,0,0,0,1,0,0,1,1,0,0,1],cap=C.intersectTriangles(capPositions,[0,1,2,0,2,3],[0]);
check(cap.segmentCount===4,'Coplanar square contributes boundary, with no triangulation diagonal.');near(totalLength(cap.sections[0]),4);
const touch=C.intersectTriangles([0,0,0,1,1,0,1,0,1],[0,1,2],[0]);check(touch.segmentCount===0,'A vertex tangency is not a line.');
const edge=C.intersectTriangles([0,0,0,0,1,0,1,0,1],[0,1,2],[0]);check(edge.segmentCount===1,'A coplanar edge is retained once.');near(totalLength(edge.sections[0]),1);
const vertex=C.intersectTriangles([-1,0,0,0,1,0,1,0,0],[0,1,2],[0]);near(totalLength(vertex.sections[0]),1);
check(C.intersectTriangles([0,0,0,0,1,0,0,2,0],[0,1,2],[0]).segmentCount===0,'Collapsed triangle adds no surface cut.');
check(C.intersectTriangles(model.positions,model.indices,[9,19]).segmentCount===0,'Outside planes stay empty.');
const shifted=model.positions.map((v,i)=>v+[0,7,-4][i%3]),translated=C.intersectTriangles(shifted,model.indices,planes);
for(let i=0;i<cuts.sections.length;i++){
 near(totalLength(translated.sections[i]),totalLength(cuts.sections[i]));
 for(let j=0;j<cuts.sections[i].segments.length;j++)for(let k=0;k<2;k++)for(let axis=0;axis<3;axis++)near(translated.sections[i].segments[j][k][axis],cuts.sections[i].segments[j][k][axis]+[0,7,-4][axis]);
}
const permuted=model.positions.flatMap((_,i,a)=>i%3?[]:[a[i+2],a[i],a[i+1]]),basic=C.intersectTriangles(permuted,model.indices,planes,{axis:1});
near(totalLength(basic.sections[1]),totalLength(cuts.sections[1]));
for(const value of[0,201,2.5,NaN,'3',null]){assert.throws(()=>C.normalizeCount(value));checks++;}
assert.throws(()=>C.intersectTriangles(model.positions,[0,1,100],[12]));checks++;
assert.throws(()=>C.intersectTriangles(model.positions,model.indices,[14,12]));checks++;
assert.throws(()=>C.intersectTriangles(model.positions.map((v,i)=>i===1?NaN:v),model.indices,[12]));checks++;
check(C.equallySpacedPlanes(capPositions,3).length===0,'A model with no span has no cut controls.');

// A lightweight Babylon stub verifies controller caching, buffer reuse and
// lifecycle without replacing the analytic intersection tests with mocks.
let created=0,disposed=0,reads=0;
class LinesMesh{
 constructor(name){this.name=name;this.material={};this.enabled=false;created++;}
 setEnabled(value){this.enabled=value;}
 updateVerticesData(kind,values){if(kind==='color')this.colors=values.slice();else this.positions=values.slice();}
 dispose(){this.disposed=true;disposed++;}
}
class VertexData{applyToMesh(mesh){mesh.positions=this.positions.slice();mesh.indices=this.indices;mesh.colors=this.colors;}}
const B={LinesMesh,VertexData,VertexBuffer:{PositionKind:'position'},Color3:{FromHexString:hex=>hex},Material:{MATERIAL_OPAQUE:0}};
let current=Float32Array.from(model.positions);
const source={enabled:false,getVerticesData(){reads++;return current;},getIndices(){return model.indices;}};
// Native payload axis ordering is BASIC XYZ; the renderer uses YZX.
const raw=model.positions.flatMap((_,i,a)=>i%3?[]:[a[i+2],a[i],a[i+1]]),data={aero:{xyz:raw,count:8}},parent={};
const display=C.create({BABYLON:B,scene:{},parent,data,mesh:source,basePositions:Float32Array.from(model.positions)});
check(display.available&&!display.mesh,'Available geometry creates no hidden helper until enabled.');
display.configure({visible:true,count:3});
check(display.mesh.enabled&&display.mesh.isPickable===false&&display.mesh.color==='#00ffff','Opaque cyan nonpickable helper.');
check(display.mesh.parent===parent&&display.mesh.metadata.wingViewHelper&&display.mesh.renderingGroupId===1,'Helper follows the model root and normal overlay group.');
check(display.mesh.material.transparencyMode===0&&display.mesh.material.alpha===1&&display.mesh.material.zOffset===0&&display.mesh.material.zOffsetUnits===0,'Opaque line primitives have WebGPU-compatible zero depth bias.');
check(Array.from(display.mesh.colors).every((v,i)=>v===(i%4===0?0:1)),'The actual line vertex-color buffer is opaque cyan.');
check(!source.enabled&&display.mesh.enabled,'Cuts remain visible while the source loft is hidden.');
const firstMesh=display.mesh,beforeReads=reads;display.configure({visible:true,count:3});
check(reads===beforeReads&&display.mesh===firstMesh,'Unchanged UI synchronization does not recompute intersections.');
display.configure({color:'#ff4080'});check(display.color==='#ff4080'&&display.mesh===firstMesh&&reads===beforeReads,'Changing color reuses the mesh without recomputing geometry.');
for(let i=0;i<display.mesh.colors.length;i+=4){near(display.mesh.colors[i],1);near(display.mesh.colors[i+1],64/255,1e-7);near(display.mesh.colors[i+2],128/255,1e-7);near(display.mesh.colors[i+3],1);}
assert.throws(()=>display.configure({color:'red'}));checks++;
current=current.map((v,i)=>v+(i%3===1?4:0));display.update();
check(display.mesh===firstMesh&&created===1,'Deformation with unchanged topology reuses the GPU mesh and buffers.');
near(display.sections[0].segments[0][0][1],cuts.sections[0].segments[0][0][1]+4,1e-6);
current=current.map((v,i)=>v+(i%3===0?3:0));display.update();
check(JSON.stringify(display.planes)===JSON.stringify([12,14,16]),'Deformation keeps the original equally spaced planes.');
check(display.sections[0].segments.length===0,'A deformed surface moving past a fixed plane produces no false material-station cut.');
display.configure({visible:false});check(!display.mesh.enabled,'Hide disables the helper immediately.');
const hiddenReads=reads;display.update();check(reads===hiddenReads,'Hidden cuts do no geometry work.');
display.configure({visible:true,count:2});check(display.count===2&&display.planes.length===2,'Count changes update locally.');
display.dispose();check(!display.available&&display.mesh===null&&disposed>=1,'Dispose releases scene resources.');display.dispose();
const absent=C.create({BABYLON:B,scene:{},data:{aero:{count:0}}});check(!absent.available&&!absent.configure({visible:true}), 'Missing loft remains unavailable.');absent.dispose();
console.log(JSON.stringify({passed:true,checks,scope:'Analytic swept/tapered/dihedral cuts, shared/coplanar edges, degeneracy, fixed deformed planes, coordinates, caching and renderer lifecycle'}));
