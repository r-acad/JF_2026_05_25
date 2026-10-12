/* Coordinate systems occupy a separate CID namespace. Miscellaneous element
 * glyphs retain their EIDs and original source definitions for inspection. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingModelEntities=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const COLORS={RBE3:'#f4b8d6',RBE2:'#ef87bb',RBAR:'#db92ee',RBE1:'#ac8bea',RSPLINE:'#cb7fda',CELAS:'#eb61cc',CONM2:'#ddc2ff',coordinate:'#c8cfff'};
  const AXIS_COLORS=['#ef5f6b','#4cc38a','#56a8f5'];
  const toView=p=>[p[1],p[2],p[0]];
  const typeLabel=type=>({RECTANGULAR:'Rectangular',CYLINDRICAL:'Cylindrical',SPHERICAL:'Spherical'})[type]||String(type);
  function coordinateReference(frame){
    const source=frame.properties||{};
    if(frame.card==='BASIC'||frame.id===0)return 'BASIC · no parent';
    // CORD1 has no RID: its three defining GRIDs may each have their own CP.
    if(/^CORD1/.test(frame.card||'')||['G1','G2','G3'].every(key=>source[key]!=null))
      return 'GRIDs '+['G1','G2','G3'].map(key=>key+' '+(source[key]??'?')).join(', ');
    const rid=source.RID??source['Reference ID'];
    return rid!=null?'RID '+rid+(Number(rid)===0?' (BASIC)':''):'Reference unavailable';
  }
  function springRadius(value){
    if(value==null||String(value).trim()==='')throw new Error('Spring radius must be between 1e-12 and 1e12 model units.');
    const radius=Number(value);
    if(!Number.isFinite(radius)||radius<1e-12||radius>1e12)throw new Error('Spring radius must be between 1e-12 and 1e12 model units.');
    return radius;
  }
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
    const radius=globalThis.document?.getElementById('celas-radius')?.value??.01;
    syncSpringStyle({state,positions,enabled:!!globalThis.document?.getElementById('show-celas-cylinders')?.checked,radius});
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
  function syncSpringStyle({state,positions,enabled,radius=.01,BABYLON=globalThis.BABYLON}){
    if(!state?.scene||!positions||!BABYLON)return;
    if(enabled){try{radius=springRadius(radius);}catch(_){return;}}
    for(const collection of state.data?.imported_connections||[]){
      if(!/^CELAS/.test(collection.card))continue;
      const layer=state.layers.get(collection.name);if(!layer)continue;
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
    return(state.data?.coordinate_systems?.systems||[]).map(frame=>({kind:'coordinate',id:frame.id,text:'CID '+frame.id+' · '+typeLabel(frame.type)+' · '+coordinateReference(frame),color:COLORS.coordinate,point:toView(frame.origin)}));
  }
  const springLabelCache=new WeakMap();
  const springNumber=value=>value!=null&&value!==''&&Number.isFinite(Number(value))?Number(Number(value).toPrecision(5)).toString():'unavailable';
  function springPropertyLabel(element){
    const props=element.properties||{},card=element.type||props.TYPE||'CELAS',usesProperty=/^CELAS[13]$/.test(card)||(!/^CELAS[24]$/.test(card)&&props.PID!=null);
    const source=usesProperty?props.property||{}:props;
    const parts=[card+' '+element.eid,usesProperty?'PELAS '+(props.PID??'unavailable'):'direct stiffness','K='+springNumber(source.K)];
    for(const key of ['GE','S'])if(source[key]!=null)parts.push(key+'='+springNumber(source[key]));
    return parts.join(' · ');
  }
  function springEndpointLabel(endpoint,frames){
    const component=Number(endpoint.component),number=endpoint.end??'?',gid=endpoint.grid;
    if(endpoint.grounded||gid===0)return 'End '+number+': ground (no GRID or coordinate axes)';
    if(component===0||endpoint.scalar)return 'End '+number+': scalar '+(gid??'?')+' · DOF 0 · no spatial coordinate axes';
    const parts=['G'+number+' '+(gid??'?'),'DOF '+(endpoint.component??'?')],cid=endpoint.coordinate_id;
    if(cid==null){parts.push('CD unavailable','axis unavailable');return parts.join(' · ');}
    const frame=frames.get(Number(cid)),type=frame?.type;
    const names=type==='CYLINDRICAL'?['r','θ','z']:type==='SPHERICAL'?['r','θ (polar)','φ (azimuth)']:type==='RECTANGULAR'?['x','y','z']:null;
    if(component>=1&&component<=6&&names)parts[1]+=' ('+(component>3?'rotation ':'translation ')+names[(component-1)%3]+')';
    parts.push('CD '+cid+(type?' '+typeLabel(type):' (type unavailable)'));
    if(frame)parts.push(coordinateReference(frame));
    if(!endpoint.axis?.every(Number.isFinite)||endpoint.axis.length!==3||!(Math.hypot(...endpoint.axis)>0))parts.push('axis unavailable');
    return parts.join(' · ');
  }
  function springLabelRecords(data){
    if(springLabelCache.has(data))return springLabelCache.get(data);
    const frames=new Map((data.coordinate_systems?.systems||[]).map(frame=>[Number(frame.id),frame])),records=[];
    // BASIC is defined by Nastran, even in older payloads without CID glyphs.
    if(!frames.has(0))frames.set(0,{id:0,type:'RECTANGULAR',card:'BASIC'});
    for(const collection of data.imported_connections||[]){
      if(!/^CELAS/.test(collection.card))continue;
      for(const element of collection.elements||[]){
        const props=element.properties||{},scalar=/^CELAS[34]$/.test(element.type||collection.card);
        const endpoints=element.endpoints||props.display_endpoints||[1,2].map(end=>({end,grid:props['G'+end]??props['S'+end],component:scalar?0:props['C'+end],scalar}));
        const lines=[springPropertyLabel({...element,type:element.type||collection.card}),...endpoints.map(endpoint=>springEndpointLabel(endpoint,frames))];
        records.push({layer:collection.name,id:element.eid,nodes:element.nodes||[],lines,text:lines.join('\n')});
      }
    }
    springLabelCache.set(data,records);return records;
  }
  function springCandidates(state,positions,enabled){
    if(!enabled||!positions||!state.data)return[];
    const result=[];
    for(const record of springLabelRecords(state.data)){
      const layer=state.layers.get(record.layer);if(!layer?.visible)continue;
      const nodes=Array.from(new Set(record.nodes)).filter(n=>Number.isInteger(n)&&n>=0&&3*n+2<positions.length&&[0,1,2].every(a=>Number.isFinite(positions[3*n+a])));
      // Scalar points do not possess geometric coordinates. Without an
      // actual plotted GRID there is nowhere truthful to place a label.
      if(!nodes.length)continue;
      const point=[0,0,0];for(const node of nodes)for(let axis=0;axis<3;axis++)point[axis]+=positions[3*node+axis]/nodes.length;
      result.push({kind:'spring-label',id:record.id,lines:record.lines,text:record.text,color:layer.color||COLORS.CELAS,point});
    }
    return result;
  }
  return{COLORS,AXIS_COLORS,typeLabel,coordinateReference,springRadius,color,kind,toView,pickedElementId,attachMarker,renderConnections,springGlyphs,springMeshes,syncSpringStyle,coordinateMeshes,pickedCoordinateId,coordinateCandidates,springPropertyLabel,springEndpointLabel,springCandidates};
});
