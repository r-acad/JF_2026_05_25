/* Coordinate systems occupy a separate CID namespace. Miscellaneous element
 * glyphs retain their EIDs and original source definitions for inspection. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingModelEntities=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const COLORS={RBE3:'#f4b8d6',RBE2:'#ef87bb',RBAR:'#db92ee',RBE1:'#ac8bea',RSPLINE:'#cb7fda',CELAS:'#eb61cc',CONM2:'#ddc2ff',coordinate:'#c8cfff'};
  const AXIS_COLORS=['#ef5f6b','#4cc38a','#56a8f5'];
  const toView=p=>[p[1],p[2],p[0]];
  const typeLabel=type=>({RECTANGULAR:'Rectangular',CYLINDRICAL:'Cylindrical',SPHERICAL:'Spherical'})[type]||String(type);
  const color=card=>COLORS[card]||(/^CELAS/.test(card)?COLORS.CELAS:COLORS.RBE1);
  const kind=card=>card==='CONM2'?'conm2':/^CELAS/.test(card)?'spring':'connection';
  function pickedElementId(pick){
    const mesh=pick?.pickedMesh,metadata=mesh?.metadata;
    if(!pick?.hit||!metadata)return undefined;
    if(Number.isInteger(metadata.elementId))return metadata.elementId;
    if(!(pick.faceId>=0))return undefined;
    const index=metadata.faceElements?metadata.faceElements[pick.faceId]:Math.floor(pick.faceId/metadata.facesPerElement);
    return mesh.elementIds?.[index];
  }
  function attachMarker(mesh,element){
    mesh.isPickable=true;
    mesh.metadata={feGroup:element.group,elementId:element.id};
    mesh.elementIds=Int32Array.of(element.id);
  }
  function renderConnections({data,state,positions,lineMesh,markerMesh,markerRadius,addLayer,diag}){
    for(const collection of data.imported_connections||[]){
      const pairs=[],faces=[],ids=Int32Array.from(collection.elements,el=>el.eid),hex=color(collection.card);
      for(let i=0;i<collection.elements.length;i++){
        const el=collection.elements[i],group={name:collection.name,kind:kind(el.type),card_types:{[el.eid]:el.type},color:hex,properties:el.properties};
        state.elements.set(el.eid,{id:el.eid,group,nodes:Int32Array.from(el.nodes)});
        for(let n=1;n<el.nodes.length;n++){pairs.push(el.nodes[0],el.nodes[n]);faces.push(i);}
      }
      const mesh=lineMesh(collection.name,positions,Int32Array.from(pairs),hex,1,true),meshes=mesh?[mesh]:[];
      if(mesh){mesh.isPickable=true;mesh.intersectionThreshold=.002*diag;mesh.elementIds=ids;mesh.metadata={feGroup:{name:collection.name,kind:kind(collection.card)},faceElements:faces,facesPerElement:1};}
      // Two different GRID IDs can share one position. Those zero-length
      // springs need the same pickable marker as a one-GRID mass/connection.
      const points=collection.elements.filter(el=>collection.point_mass||el.nodes.length<2||el.nodes.every(n=>[0,1,2].every(a=>positions[3*n+a]===positions[3*el.nodes[0]+a])));
      if(points.length){
        const marks=markerMesh(collection.name,positions,points.map(el=>el.nodes[0]),hex,Math.max(markerRadius(),diag*1e-8))||[];
        marks.forEach((mark,i)=>attachMarker(mark,state.elements.get(points[i].eid)));meshes.push(...marks);
      }
      addLayer(collection.name,collection.card+(collection.point_mass?' mass attachment nodes':' connections'),hex,collection.elements.length+' elements',meshes);
    }
  }
  function coordinateMeshes(B,{scene,parent,payload,diag}){
    const systems=payload?.systems||[],length=Math.max(diag*.035,1e-8),meshes=[];
    for(let axis=0;axis<3;axis++){
      const lines=[],owners=[];
      systems.forEach((frame,index)=>{
        const origin=new B.Vector3(...toView(frame.origin)),direction=new B.Vector3(...toView(frame[['x','y','z'][axis]]));
        const tip=origin.add(direction.scale(length)),side=B.Vector3.Cross(direction,Math.abs(direction.y)<.9?B.Axis.Y:B.Axis.X).normalize().scale(length*.08),back=tip.subtract(direction.scale(length*.2));
        lines.push([origin,tip],[tip,back.add(side)],[tip,back.subtract(side)]);owners.push(index,index,index);
      });
      if(!lines.length)continue;
      const mesh=B.MeshBuilder.CreateLineSystem('COORDINATE_SYSTEMS-'+axis,{lines},scene);
      mesh.parent=parent;mesh.color=B.Color3.FromHexString(AXIS_COLORS[axis]);mesh.alpha=1;mesh.isPickable=true;mesh.intersectionThreshold=length*.07;
      mesh.metadata={coordinateIds:systems.map(frame=>frame.id),faceCoordinates:owners};meshes.push(mesh);
    }
    return meshes;
  }
  function pickedCoordinateId(pick){const meta=pick?.pickedMesh?.metadata;return pick?.hit&&pick.faceId>=0?meta?.coordinateIds?.[meta.faceCoordinates?.[pick.faceId]]:undefined;}
  function coordinateCandidates(state,enabled){
    if(!enabled||!state.layers.get('COORDINATE_SYSTEMS')?.visible)return[];
    return(state.data?.coordinate_systems?.systems||[]).map(frame=>({kind:'coordinate',id:frame.id,text:'CID '+frame.id+' · '+typeLabel(frame.type),color:COLORS.coordinate,point:toView(frame.origin)}));
  }
  return{COLORS,AXIS_COLORS,typeLabel,color,kind,toView,pickedElementId,attachMarker,renderConnections,coordinateMeshes,pickedCoordinateId,coordinateCandidates};
});
