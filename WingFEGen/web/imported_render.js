/* Bounded GPU batches for imported decks with many property IDs. Original
 * groups and IDs remain authoritative; batching is purely a display detail. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingImportedRender=api;})(globalThis,function(){
 'use strict';
 function bounds(data,allNodes=false){
  if(!data?.imported_deck||allNodes)return data?.bbox;
  if(data.display_bbox)return data.display_bbox;
  // Compatibility for retained payloads: orientation/unused GRID points may
  // lie far from every physical element, but still remain available as nodes.
  const typed=(b,T)=>b.byteOffset%4?new T(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)):new T(b.buffer,b.byteOffset,b.byteLength/4);
  if(!data.nodes?.xyz||!data.groups?.length)return data.bbox;
  const xyz=typed(data.nodes.xyz,Float32Array),lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
  for(const group of data.groups)for(const node of typed(group.conn,Int32Array))for(let axis=0;axis<3;axis++){const value=xyz[3*node+axis];lo[axis]=Math.min(lo[axis],value);hi[axis]=Math.max(hi[axis],value);}
  return lo.every(Number.isFinite)?(data.display_bbox={min:lo,max:hi}):data.bbox;
 }
 function expand(data){
  const buffers=data.imported_buffers;if(!buffers)return data;
  const fields=['eids','conn','orient','centers','x','y','z','lengths'];
  for(const group of data.groups){const offsets=group.binary_offsets;if(!offsets)continue;const n=group.count,stride=group.kind==='quad'?4:group.kind==='tria'?3:2;
   const sizes=[n,n*stride,group.kind==='bar'?3*n:0,3*n,3*n,3*n,3*n,n];group.axes={};
   for(let i=0;i<fields.length;i++){const field=fields[i],source=buffers[field],view=new Uint8Array(source.buffer,source.byteOffset+offsets[i],sizes[i]*4);if(i<3)group[field]=view;else group.axes[field]=view;}
   const materials=buffers.materials,properties=group.properties;
   if(materials&&properties){
    for(const key of ['material','face_material','core_material'])if(Number.isInteger(properties[key]))properties[key]=materials[properties[key]];
    for(const ply of properties.plies||[])if(Number.isInteger(ply.material))ply.material=materials[ply.material];
   }
   delete group.binary_offsets;
  }
  delete data.imported_buffers;return data;
 }
 function batches(groups,read,readFloat,threshold=1000,maxElements=8192){
  if(groups.length<=threshold)return groups;
  const output=[],pending=new Map(),sizes=new Map();
  function flush(kind){const members=pending.get(kind);if(!members?.length)return;
   const count=members.reduce((n,g)=>n+g.count,0),stride=kind==='quad'?4:kind==='tria'?3:2;
   const conn=new Int32Array(count*stride),ids=new Int32Array(count),orient=new Float32Array(kind==='bar'?count*3:0),ranges=[];let e=0;
   for(const group of members){conn.set(read(group.conn),e*stride);ids.set(read(group.eids),e);if(group.orient?.byteLength)orient.set(readFloat(group.orient),e*3);ranges.push({group,start:e,count:group.count});e+=group.count;}
   output.push({name:'IMPORTED_BATCH_'+kind+'_'+output.length,kind,count,pid:0,conn:new Uint8Array(conn.buffer),eids:new Uint8Array(ids.buffer),orient:new Uint8Array(orient.buffer),sourceRanges:ranges});pending.set(kind,[]);sizes.set(kind,0);
  }
  for(const group of groups){
   // Shaped sections retain their actual section definitions. Unshaped beam
   // centerlines can batch across PIDs just like shells.
   if(group.properties?.section?.polygon_yz_m){output.push(group);continue;}
   let members=pending.get(group.kind);if(!members)pending.set(group.kind,members=[]);
   if(members.length&&(sizes.get(group.kind)||0)+group.count>maxElements){flush(group.kind);members=pending.get(group.kind);}
   members.push(group);sizes.set(group.kind,(sizes.get(group.kind)||0)+group.count);
  }
  for(const kind of pending.keys())flush(kind);return output;
 }
 function sync(mesh,layers){
  if(!mesh.importedRanges)return;
  const base=mesh.importedBaseIndices||(mesh.importedBaseIndices=Int32Array.from(mesh.getIndices())),indices=mesh.importedIndices||(mesh.importedIndices=base.slice()),per=mesh.importedIndicesPerElement;
  let changed=false,any=false;
  for(const range of mesh.importedRanges){const visible=!!layers.get(range.group.name)?.visible;any||=visible;
   if(range.visible===visible)continue;range.visible=visible;changed=true;
   const start=range.start*per,end=(range.start+range.count)*per;
   if(visible)indices.set(base.subarray(start,end),start);else indices.fill(0,start,end);
  }
  if(changed){
   if(per===2){
    // Babylon picks even zero-length line segments. Remove hidden bar pairs
    // from the index buffer and map visible faces back to the original EIDs;
    // vertex, result-color and deformation buffers retain their full order.
    const count=mesh.importedRanges.reduce((n,r)=>n+(r.visible?r.count:0),0),visible=new Int32Array(2*count),faces=new Int32Array(count);
    let next=0;
    for(const range of mesh.importedRanges)if(range.visible){
     visible.set(base.subarray(2*range.start,2*(range.start+range.count)),2*next);
     for(let e=0;e<range.count;e++)faces[next+e]=range.start+e;
     next+=range.count;
    }
    mesh.metadata={...mesh.metadata,faceElements:faces};mesh.updateIndices(visible);
   }else mesh.updateIndices(indices);
  }
  mesh.setEnabled(any);
 }
 return{expand,batches,sync,bounds};
});
