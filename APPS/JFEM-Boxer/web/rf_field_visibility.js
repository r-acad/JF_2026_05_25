/* Temporary, element-exact RF isolation. Layer choices and FE buffers remain
 * authoritative; only drawing indices and mesh visibility are filtered. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFFieldVisibility=api;})(globalThis,function(){
 'use strict';
 function geometry({indices,elementIds,primitiveSize=3,faceElements,facesPerElement=1},allowed,elementVisible=()=>true){
  const picked=[],owners=[];
  for(let p=0;p<indices.length/primitiveSize;p++){
   const e=faceElements?faceElements[p]:Math.floor(p/facesPerElement);
   if(!allowed.has(elementIds[e])||!elementVisible(e))continue;
   for(let k=0;k<primitiveSize;k++)picked.push(indices[p*primitiveSize+k]);
   owners.push(e);
  }
  return{indices:Int32Array.from(picked),faceElements:Int32Array.from(owners)};
 }
 function create({state,syncImported}){
  const records=new Map(),hidden=new Map();let active=false,lastAllowed=null;
  const alive=mesh=>!mesh.isDisposed?.();
  function restore(){
   for(const [mesh,r]of records){if(!alive(mesh))continue;mesh.setIndices(r.indices);mesh.metadata=r.metadata;mesh.isVisible=r.visible;
    if(mesh.importedRanges){for(const range of mesh.importedRanges)range.visible=undefined;syncImported?.(mesh);}}
   for(const [mesh,visible]of hidden)if(alive(mesh))mesh.isVisible=visible;
   records.clear();hidden.clear();lastAllowed=null;active=false;state.rfVisibleElementIds=null;
  }
  function hide(mesh){if(!mesh||!alive(mesh))return;if(!hidden.has(mesh))hidden.set(mesh,mesh.isVisible);mesh.isVisible=false;}
  function sync(allowed){
   if(!allowed){if(active)restore();return;}
   active=true;state.rfVisibleElementIds=allowed;
   const structural=new Set([...(state.shellMeshes||[]),...(state.barMeshes||[])]);
   for(const mesh of structural){
    if(!alive(mesh)||!mesh.elementIds?.length)continue;
    let r=records.get(mesh);
    if(!r){
     // Imported batches may currently have compacted line indices. Their
     // immutable base retains every EID and the original vertex ordering.
     const indices=mesh.importedBaseIndices||mesh.surfaceIndices||mesh.sectionGeometry?.indices||mesh.shellThicknessGeometry?.indices||mesh.getIndices();
     const faceElements=mesh.sectionGeometry?.faceElements||mesh.shellThicknessGeometry?.faceElements||(!mesh.importedRanges?mesh.metadata?.faceElements:null);
     r={indices:Int32Array.from(indices),metadata:mesh.metadata,visible:mesh.isVisible,primitiveSize:mesh.barRepresentation==='lines'?2:3,faceElements,facesPerElement:mesh.metadata?.facesPerElement||1};records.set(mesh,r);
    }
    const ranges=mesh.importedRanges,key=ranges?ranges.map(range=>!!state.layers.get(range.group.name)?.visible?'1':'0').join(''):'';
    if(r.allowed!==allowed||r.layerKey!==key||r.applied!==mesh.getIndices()){
     let visible;
     if(ranges){visible=new Uint8Array(mesh.elementIds.length);for(const range of ranges)if(state.layers.get(range.group.name)?.visible)visible.fill(1,range.start,range.start+range.count);}
     const masked=geometry({...r,elementIds:mesh.elementIds},allowed,visible?e=>visible[e]===1:undefined);
     mesh.setIndices(masked.indices);mesh.metadata={...r.metadata,faceElements:masked.faceElements};
     r.applied=mesh.getIndices();r.allowed=allowed;r.layerKey=key;r.any=masked.indices.length>0;
    }
    mesh.isVisible=r.visible&&r.any;
   }
   // Context overlays would otherwise redraw the complete model around the
   // isolated elements. Their switches are left untouched for restoration.
   for(const [name,layer]of state.layers||[])if(name!=='MESH_EDGES')for(const mesh of layer.meshes||[])if(!structural.has(mesh))hide(mesh);
   if(state.selectionMesh&&!allowed.has(state.selectedElement))hide(state.selectionMesh);
   else if(state.selectionMesh&&hidden.has(state.selectionMesh)){state.selectionMesh.isVisible=hidden.get(state.selectionMesh);hidden.delete(state.selectionMesh);}
   lastAllowed=allowed;
  }
  return{sync,restore,get active(){return active;},get allowed(){return lastAllowed;}};
 }
 // Movable skins currently have property-wide material checks but no separate
 // generated plate/column buckling metadata. Never paint missing RFs as an
 // assessed solid region. Restore the user's material when leaving RF views.
 function createMovableStyle({state}){
  const records=new Map();
  function sync(contour){
   for(const [mesh,r]of records)if(mesh.isDisposed?.()||!contour||!state.shellMeshes?.includes(mesh)||mesh.material!==r.material){
    if(!mesh.isDisposed?.())Object.assign(r.material,r.original);records.delete(mesh);
   }
   if(!contour)return;
   for(const mesh of state.shellMeshes||[]){
    const group=mesh.metadata?.feGroup,properties=group?.properties;
    if(!properties?.movable_surface&&!/^MOVABLE_/.test(group?.name||''))continue;
    const material=mesh.material;if(!material)continue;
    let record=records.get(mesh);
    if(!record){record={material,original:{wireframe:material.wireframe,zOffset:material.zOffset,zOffsetUnits:material.zOffsetUnits}};records.set(mesh,record);}
    if(record.contour!==contour){record.contour=contour;record.wire=contour.stale||!Array.from(mesh.elementIds||[]).some(id=>contour.byId.has(id));}
    if(record.wire){material.wireframe=true;material.zOffset=0;material.zOffsetUnits=0;}
    else Object.assign(material,record.original);
   }
  }
  return{sync,restore:()=>sync(null)};
 }
 return{geometry,create,createMovableStyle};
});
