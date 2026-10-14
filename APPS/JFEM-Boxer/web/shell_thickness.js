/* Physical shell thickness is display geometry only. FE midsurface GRID
 * coordinates, stiffness, properties, stress locations and IDs are unchanged. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingShellThickness=api;})(globalThis,function(){
 'use strict';
 const point=(p,n)=>[p[3*n],p[3*n+1],p[3*n+2]],sub=(a,b)=>a.map((v,i)=>v-b[i]);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 function boundsForGroup(group){
  if(!['quad','tria'].includes(group.kind))return null;
  const bounds=new Float64Array(group.count*2),ranges=group.sourceRanges||[{group,start:0,count:group.count}];
  for(const range of ranges){const p=range.group.properties||{},t=Number(p.thickness_m);
   if(!(t>0)||!Number.isFinite(t)||p.thickness_display_supported===false)return null;
   if(['z_bottom_m','z_top_m','z0_m'].some(key=>key in p&&!Number.isFinite(p[key])))return null;
   const bottom=Number.isFinite(p.z_bottom_m)?p.z_bottom_m:Number.isFinite(p.z0_m)?p.z0_m:-t/2,top=Number.isFinite(p.z_top_m)?p.z_top_m:bottom+t;
   if(!(top>bottom)||!Number.isFinite(top)||Math.max(Math.abs(bottom),Math.abs(top))>3.4e38)return null;
   for(let e=range.start;e<range.start+range.count;e++){bounds[2*e]=bottom;bounds[2*e+1]=top;}
  }
  return bounds;
 }
 function geometry(positions,conn,nodesPerElement,bounds){
  const n=nodesPerElement,template=[];
  const tri=(side,a,b,c)=>template.push([a,side],[b,side],[c,side]);
  for(let i=1;i<n-1;i++){tri(0,0,i+1,i);tri(1,0,i,i+1);}
  for(let i=0;i<n;i++){const j=(i+1)%n;template.push([i,0],[j,0],[j,1],[i,0],[j,1],[i,1]);}
  const count=conn.length/n,nv=count*template.length;
  const data={conn,nodesPerElement:n,bounds,template,verticesPerElement:template.length,positions:new Float32Array(3*nv),indices:Int32Array.from({length:nv},(_,i)=>i),normals:new Float32Array(3*nv),faceElements:new Int32Array(nv/3),referenceNormals:new Float64Array(3*count)};
  for(let e=0;e<count;e++){data.faceElements.fill(e,e*template.length/3,(e+1)*template.length/3);}
  update(data,positions,true);return data;
 }
 function update(data,positions,initial=false){
  const {conn,nodesPerElement:n,bounds,template}=data;
  for(let e=0;e<conn.length/n;e++){
   const points=Array.from({length:n},(_,k)=>point(positions,conn[e*n+k]));
   let normal=n===4?cross(sub(points[2],points[0]),sub(points[3],points[1])):cross(sub(points[1],points[0]),sub(points[2],points[0]));
   const length=Math.hypot(...normal);
   if(length>1e-20){normal=normal.map(v=>v/length);if(initial)data.referenceNormals.set(normal,e*3);}
   else normal=Array.from(data.referenceNormals.subarray(e*3,e*3+3));
   for(let v=0;v<template.length;v++){const [node,side]=template[v],offset=bounds[2*e+side];
    for(let c=0;c<3;c++)data.positions[3*(e*template.length+v)+c]=points[node][c]+offset*normal[c];}
  }
  return data.positions;
 }
 function createMesh(B,options){
  const data=geometry(options.positions,options.conn,options.nodesPerElement,options.bounds),mesh=new B.Mesh(options.name,options.scene),vd=new B.VertexData();
  vd.positions=data.positions;vd.indices=data.indices;B.VertexData.ComputeNormals(data.positions,data.indices,data.normals,{useRightHandedSystem:true});vd.normals=data.normals;vd.colors=new Float32Array(data.positions.length/3*4).fill(1);vd.applyToMesh(mesh,true);mesh.shellThicknessGeometry=data;return mesh;
 }
 function updateMesh(B,mesh,positions){const data=mesh.shellThicknessGeometry;update(data,positions);mesh.updateVerticesData(B.VertexBuffer.PositionKind,data.positions,true,false);B.VertexData.ComputeNormals(data.positions,data.indices,data.normals,{useRightHandedSystem:true});mesh.updateVerticesData(B.VertexBuffer.NormalKind,data.normals);}
 return{boundsForGroup,geometry,update,createMesh,updateMesh};
});
