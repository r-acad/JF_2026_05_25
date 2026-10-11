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
    syncSpringStyle({state,positions,enabled:!!globalThis.document?.getElementById('show-celas-cylinders')?.checked,markerRadius:markerRadius()});
  }
  function springGlyphs(collection){
    const glyphs=[];
    for(const el of collection.elements||[]){
      const seen=new Set();
      for(const end of el.endpoints||el.properties?.display_endpoints||[]){
        if(end.grounded||!Number.isInteger(end.node)||end.node<0||!(end.component>=1&&end.component<=6)||!end.axis?.every(Number.isFinite)||end.axis.length!==3)continue;
        const norm=Math.hypot(...end.axis);if(!(norm>0))continue;
        const key=[end.node,end.component,...end.axis].join(':');if(seen.has(key))continue;seen.add(key);
        glyphs.push({...end,eid:el.eid,axis:toView(end.axis.map(v=>v/norm)),color:AXIS_COLORS[(end.component-1)%3],rotational:end.component>3});
      }
    }
    return glyphs;
  }
  // One bounded GPU batch per component: even a large imported spring model
  // does not allocate a Babylon mesh/material per endpoint. Source topology
  // remains visible because scalar and grounded ends have no invented axis.
  function springMeshes(B,{state,positions,collection,radius}){
    const glyphs=springGlyphs(collection),meshes=[];
    const shape=B.VertexData.CreateCylinder({height:4*radius,diameter:2*radius,tessellation:12});
    for(let component=1;component<=6;component++){
      const selected=glyphs.filter(glyph=>glyph.component===component);
      for(let start=0;start<selected.length;start+=2048){
        const chunk=selected.slice(start,start+2048),nv=shape.positions.length/3,nf=shape.indices.length/3;
        const points=new Float32Array(chunk.length*shape.positions.length),normals=new Float32Array(points.length),offsets=new Float32Array(points.length),map=new Int32Array(points.length/3),indices=new Uint32Array(chunk.length*shape.indices.length);
        chunk.forEach((glyph,g)=>{
          const axis=new B.Vector3(...glyph.axis),x=B.Vector3.Cross(Math.abs(axis.y)<.9?B.Axis.Y:B.Axis.X,axis).normalize(),z=B.Vector3.Cross(x,axis).normalize();
          for(let v=0;v<nv;v++){
            const p=3*v,k=3*(g*nv+v),vector=x.scale(shape.positions[p]).add(axis.scale(shape.positions[p+1])).add(z.scale(shape.positions[p+2]));
            const normal=x.scale(shape.normals[p]).add(axis.scale(shape.normals[p+1])).add(z.scale(shape.normals[p+2]));
            offsets.set(vector.asArray(),k);normals.set(normal.asArray(),k);map[g*nv+v]=glyph.node;
            for(let a=0;a<3;a++)points[k+a]=positions[3*glyph.node+a]+offsets[k+a];
          }
          for(let i=0;i<shape.indices.length;i++)indices[g*shape.indices.length+i]=g*nv+shape.indices[i];
        });
        const mesh=new B.Mesh(collection.name+'-axis-'+component+'-'+start,state.scene),vd=new B.VertexData();vd.positions=points;vd.normals=normals;vd.indices=indices;vd.applyToMesh(mesh,true);
        const material=new B.StandardMaterial(mesh.name+'-material',state.scene);material.diffuseColor=B.Color3.FromHexString(AXIS_COLORS[(component-1)%3]);material.specularColor=new B.Color3(.15,.15,.15);material.backFaceCulling=false;mesh.material=material;
        mesh.parent=state.root;mesh.isPickable=true;mesh.springCylinders=true;mesh.elementIds=Int32Array.from(chunk,g=>g.eid);
        mesh.metadata={feGroup:{name:collection.name,kind:'spring'},facesPerElement:nf,springGlyphs:chunk};
        state.deformable.push({mesh,map,offsets,buf:points});meshes.push(mesh);
      }
    }
    return meshes;
  }
  function syncSpringStyle({state,positions,enabled,markerRadius=0,BABYLON=globalThis.BABYLON}){
    if(!state?.scene||!positions||!BABYLON)return;
    for(const collection of state.data?.imported_connections||[]){
      if(!/^CELAS/.test(collection.card))continue;
      const layer=state.layers.get(collection.name);if(!layer)continue;
      const radius=Math.max(Number(markerRadius)||0,(state.diag||1)*.001,1e-9);
      if(enabled&&layer.springRadius!==radius){
        const old=new Set(layer.meshes.filter(mesh=>mesh.springCylinders));state.deformable=state.deformable.filter(record=>!old.has(record.mesh));
        old.forEach(mesh=>mesh.dispose(false,true));layer.meshes=layer.meshes.filter(mesh=>!old.has(mesh));
        layer.meshes.push(...springMeshes(BABYLON,{state,positions,collection,radius}));layer.springRadius=radius;
      }
      for(const mesh of layer.meshes)if(mesh.springCylinders)mesh.setEnabled(!!enabled&&layer.visible);
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
  return{COLORS,AXIS_COLORS,typeLabel,color,kind,toView,pickedElementId,attachMarker,renderConnections,springGlyphs,springMeshes,syncSpringStyle,coordinateMeshes,pickedCoordinateId,coordinateCandidates};
});
