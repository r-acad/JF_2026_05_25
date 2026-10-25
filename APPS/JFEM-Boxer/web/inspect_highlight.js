/* Inspection overlays use the drawn FE primitives, not whole merged meshes.
 * Structural colours, visibility, picking and analysis data stay untouched. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingInspectHighlight=api;})(globalThis,function(){
 'use strict';
 const SUPPORTED=new Set(['quad','tria','bar','solid']),SELECTED='#5deaff',PEERS='#ffb52e';
 const alive=mesh=>mesh&&!mesh.isDisposed?.();
 const enabled=mesh=>alive(mesh)&&mesh.isEnabled?.()!==false&&mesh.isVisible!==false&&mesh.visibility!==0&&mesh.alpha!==0&&mesh.material?.alpha!==0;
 const subtract=(a,b)=>a.map((v,i)=>v-b[i]);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const unit=a=>{const n=Math.hypot(...a);return n>0?a.map(v=>v/n):[0,0,0];};
 function propertyId(element){const id=Number(element?.group?.pid);return Number.isFinite(id)&&id>0?id:null;}
 function sourcesFor(state,selected){
  const pid=propertyId(selected),members=new Set();
  for(const [id,element]of state.elements||[])if(id===selected.id||pid!==null&&propertyId(element)===pid)members.add(id);
  const sources=[];
  for(const mesh of new Set([...(state.shellMeshes||[]),...(state.barMeshes||[])])){
   if(!alive(mesh)||!mesh.elementIds?.length)continue;
   const own=new Set(),layers=new Set();
   for(let i=0;i<mesh.elementIds.length;i++)if(members.has(mesh.elementIds[i])){own.add(i);const element=state.elements.get(mesh.elementIds[i]);if(element)layers.add(element.group.name);}
   if(own.size)sources.push({mesh,own,layers});
  }
  return sources;
 }
 function transformPoint(positions,index,matrix){
  const x=positions[3*index],y=positions[3*index+1],z=positions[3*index+2];
  if(!matrix)return[x,y,z];const w=x*matrix[3]+y*matrix[7]+z*matrix[11]+matrix[15],d=w&&w!==1?1/w:1;
  return[(x*matrix[0]+y*matrix[4]+z*matrix[8]+matrix[12])*d,(x*matrix[1]+y*matrix[5]+z*matrix[9]+matrix[13])*d,(x*matrix[2]+y*matrix[6]+z*matrix[10]+matrix[14])*d];
 }
 function collectGeometry(state,selectedId=state.selectedElement,sources){
  const selected=state.elements?.get(selectedId),result={selectedSegments:[],peerSegments:[],selectedVisible:false,peerElementIds:[],propertyId:propertyId(selected)};
  if(!selected||!SUPPORTED.has(selected.group.kind))return result;
  sources=sources||sourcesFor(state,selected);
  const selectedEdges=new Map(),peerEdges=new Map(),peerIds=new Set(),scale=Math.max(Number(state.diag)||1,1e-12),tolerance=scale*1e-9;
  const coordinateKey=p=>p.map(v=>Math.round(v/tolerance)).join(',');
  function addEdge(target,eid,a,b,normal,surface,mesh,aIndex,bIndex){
   if(Math.hypot(...subtract(a,b))<=scale*1e-12)return;
   let ak=coordinateKey(a),bk=coordinateKey(b);if(ak>bk){[ak,bk]=[bk,ak];[a,b]=[b,a];[aIndex,bIndex]=[bIndex,aIndex];}
   const key=eid+':'+ak+':'+bk,existing=target.get(key);
   if(existing){existing.count++;if(normal&&existing.normal&&Math.abs(normal.reduce((v,n,i)=>v+n*existing.normal[i],0))<.985)existing.crease=true;}
   else target.set(key,{a,b,normal,count:1,crease:false,surface,source:{mesh,aIndex,bIndex}});
  }
  for(const source of sources){
   const mesh=source.mesh;if(!enabled(mesh))continue;
   const indices=mesh.getIndices?.(),positions=mesh.getVerticesData?.('position');if(!indices?.length||!positions?.length)continue;
   const matrix=mesh.computeWorldMatrix?.(true)?.m||mesh.getWorldMatrix?.()?.m;
   // A masked/compacted mesh has a new per-drawn-primitive owner map. The
   // original section/thickness maps no longer index the drawn triangles.
   const owners=mesh.metadata?.faceElements||mesh.sectionGeometry?.faceElements||mesh.shellThicknessGeometry?.faceElements;
   const per=mesh.metadata?.facesPerElement||1,stride=mesh.barRepresentation==='lines'?2:3;
   const surface=!mesh.sectionGeometry&&!mesh.shellThicknessGeometry&&mesh.metadata?.feGroup?.kind!=='solid';
   for(let p=0;p<indices.length/stride;p++){
    const owner=owners?owners[p]:Math.floor(p/per);if(!source.own.has(owner))continue;
    const eid=mesh.elementIds[owner],element=state.elements.get(eid),layer=element&&state.layers?.get(element.group.name);
    if(!element||layer?.visible===false||state.rfVisibleElementIds&&!state.rfVisibleElementIds.has(eid))continue;
    const points=[];for(let k=0;k<stride;k++)points.push(transformPoint(positions,indices[p*stride+k],matrix));
    if(points.some(point=>point.some(v=>!Number.isFinite(v))))continue;
    let normal=null;
    if(stride===3){const n=cross(subtract(points[1],points[0]),subtract(points[2],points[0]));if(Math.hypot(...n)<=scale*scale*1e-18)continue;normal=unit(n);}
    else if(Math.hypot(...subtract(points[1],points[0]))<=scale*1e-12)continue;
    const target=eid===selectedId?selectedEdges:peerEdges;
    if(eid===selectedId)result.selectedVisible=true;else peerIds.add(eid);
    for(let k=0;k<(stride===2?1:3);k++)addEdge(target,eid,points[k],points[(k+1)%stride],normal,surface,mesh,indices[p*stride+k],indices[p*stride+(k+1)%stride]);
   }
  }
  const segments=edges=>{const list=[],references=[],seen=new Set();for(const edge of edges.values())if(edge.count===1||!edge.surface&&edge.crease){const key=coordinateKey(edge.a)+':'+coordinateKey(edge.b);if(seen.has(key))continue;seen.add(key);list.push(...edge.a,...edge.b);references.push(edge.source);}return{list,references};};
  const picked=segments(selectedEdges),peers=segments(peerEdges);
  result.selectedSegments=picked.list;result.peerSegments=peers.list;result.selectedSources=picked.references;result.peerSources=peers.references;result.peerElementIds=[...peerIds].sort((a,b)=>a-b);return result;
 }
 // The boundary/crease topology stays fixed during result animation. Keep
 // endpoint references so each pose reads only the displayed outline, rather
 // than rebuilding triangle ownership and coordinate hashes for a large PID.
 function updatePose(geometry){
  const buffers=new Map();
  function segments(sources){const points=[];for(const {mesh,aIndex,bIndex}of sources||[]){let data=buffers.get(mesh);if(!data){data={positions:mesh.getVerticesData('position'),matrix:mesh.computeWorldMatrix?.(true)?.m||mesh.getWorldMatrix?.()?.m};buffers.set(mesh,data);}points.push(...transformPoint(data.positions,aIndex,data.matrix),...transformPoint(data.positions,bIndex,data.matrix));}return points;}
  geometry.selectedSegments=segments(geometry.selectedSources);geometry.peerSegments=segments(geometry.peerSources);return geometry;
 }
 function tubes(segments,radius,sides=8){
  const positions=[],normals=[],indices=[];
  for(let k=0;k<segments.length;k+=6){
   const a=segments.slice(k,k+3),b=segments.slice(k+3,k+6),axis=unit(subtract(b,a));
   const u=unit(cross(axis,Math.abs(axis[1])<.9?[0,1,0]:[1,0,0])),v=cross(axis,u),start=positions.length/3;
   for(let end=0;end<2;end++)for(let j=0;j<sides;j++){const angle=j*2*Math.PI/sides,n=u.map((x,i)=>x*Math.cos(angle)+v[i]*Math.sin(angle)),p=end?b:a;positions.push(...p.map((x,i)=>x+radius*n[i]));normals.push(...n);}
   for(let j=0;j<sides;j++){const next=(j+1)%sides;indices.push(start+j,start+next,start+sides+next,start+j,start+sides+next,start+sides+j);}
  }
  return{positions:Float32Array.from(positions),normals:Float32Array.from(normals),indices:Int32Array.from(indices)};
 }
 function create({BABYLON:B,scene,state}){
  let disposed=false,selectedMesh=null,peerMesh=null,glow=null,lastSelection=null,lastData=null,lastElements=null,lastShells=null,lastBars=null,lastMeshCount=-1,sources=[],lastKey='',cachedGeometry=null,nextIdentity=1;
  const identities=new WeakMap(),id=value=>{if(!value||typeof value!=='object')return String(value);if(!identities.has(value))identities.set(value,nextIdentity++);return identities.get(value);};
  let diagnostics={selectedEid:null,propertyId:null,selectedVisible:false,visiblePeerCount:0,peerElementIds:[],meshCount:0,glowEnabled:false,outlineRadius:0,geometryBuilds:0,poseUpdates:0};
  const allMeshes=()=>[selectedMesh,peerMesh].filter(alive);
  function clear(){for(const mesh of allMeshes())mesh.setEnabled(false);if(glow)glow.isEnabled=false;lastKey='';diagnostics={...diagnostics,selectedEid:state.selectedElement??null,propertyId:null,selectedVisible:false,visiblePeerCount:0,peerElementIds:[],meshCount:allMeshes().length,glowEnabled:false,outlineRadius:0};}
  function initialise(){
   if(selectedMesh)return;
   selectedMesh=new B.Mesh('inspection-selected-glow',scene);selectedMesh.isPickable=false;selectedMesh.renderingGroupId=2;selectedMesh.metadata={wingViewHelper:true,inspectionHighlight:true,selectedHighlight:true};
   const mat=new B.StandardMaterial('inspection-selected-glow-material',scene);mat.diffuseColor=B.Color3.FromHexString(SELECTED);mat.emissiveColor=B.Color3.FromHexString(SELECTED);mat.disableLighting=true;mat.backFaceCulling=false;mat.disableDepthWrite=true;mat.zOffset=-1;selectedMesh.material=mat;
   peerMesh=new B.LinesMesh('inspection-property-peers',scene);peerMesh.isPickable=false;peerMesh.renderingGroupId=2;peerMesh.color=B.Color3.FromHexString(PEERS);peerMesh.alpha=.96;peerMesh.metadata={wingViewHelper:true,inspectionHighlight:true,peerHighlight:true};
   // Line-list primitives cannot use a depth bias on WebGPU. Keep the
   // orange peer edges at their physical depth; selected glow uses triangles.
   if(peerMesh.material){peerMesh.material.zOffset=0;peerMesh.material.zOffsetUnits=0;peerMesh.material.disableDepthWrite=true;}
   if(B.GlowLayer){try{glow=new B.GlowLayer('inspection-selected-halo',scene,{mainTextureFixedSize:512,blurKernelSize:16,renderingGroupId:2});glow.intensity=.75;glow.addIncludedOnlyMesh(selectedMesh);}catch(_){glow?.dispose();glow=null;}}
  }
  function applyVertices(mesh,data){
   const old=mesh.getVerticesData(B.VertexBuffer.PositionKind),oldIndices=mesh.getIndices();
   if(old?.length===data.positions.length&&oldIndices?.length===data.indices.length){mesh.updateVerticesData(B.VertexBuffer.PositionKind,data.positions,true,false);if(data.normals)mesh.updateVerticesData(B.VertexBuffer.NormalKind,data.normals);}
   else{const vd=new B.VertexData();vd.positions=data.positions;vd.indices=data.indices;if(data.normals)vd.normals=data.normals;vd.applyToMesh(mesh,true);}
  }
  function refresh(force=false){
   if(disposed)return;
   const selected=state.elements?.get(state.selectedElement);
   if(!selected||!SUPPORTED.has(selected.group.kind)){clear();lastSelection=null;return;}
   const meshCount=(state.shellMeshes?.length||0)+(state.barMeshes?.length||0);
   if(lastSelection!==selected||lastData!==state.data||lastElements!==state.elements||lastShells!==state.shellMeshes||lastBars!==state.barMeshes||lastMeshCount!==meshCount){
    sources=sourcesFor(state,selected);lastSelection=selected;lastData=state.data;lastElements=state.elements;lastShells=state.shellMeshes;lastBars=state.barMeshes;lastMeshCount=meshCount;lastKey='';
   }
   const key=[selected.id,propertyId(selected),id(state.rfVisibleElementIds),JSON.stringify(state.panelExplosion?.capture?.()||null),...sources.map(source=>{const mesh=source.mesh;return[id(mesh),enabled(mesh),id(mesh.getIndices?.()),mesh.getIndices?.()?.length,id(mesh.metadata?.faceElements),...[...source.layers].map(name=>state.layers.get(name)?.visible)].join('/');})].join('|');
   if(!force&&key===lastKey)return;
   let geometry;if(key===lastKey&&cachedGeometry)geometry=updatePose(cachedGeometry);else{geometry=collectGeometry(state,selected.id,sources);cachedGeometry=geometry;diagnostics.geometryBuilds++;}lastKey=key;if(force)diagnostics.poseUpdates++;
   if(!geometry.selectedSegments.length&&!geometry.peerSegments.length){clear();lastKey=key;diagnostics.selectedEid=selected.id;diagnostics.propertyId=geometry.propertyId;return;}
   initialise();
   if(geometry.selectedSegments.length){let longest=0;for(let k=0;k<geometry.selectedSegments.length;k+=6)longest=Math.max(longest,Math.hypot(...subtract(geometry.selectedSegments.slice(k+3,k+6),geometry.selectedSegments.slice(k,k+3))));
    // A thin PBARL flange edge can be thousands of times shorter than its
    // beam. It must not reduce the inspection outline to a subpixel hairline.
    // Cap by element extent instead, retaining a modest halo on tiny elements.
    const diag=Math.max(Number(state.diag)||1,1e-12),radius=Math.max(diag*1e-7,Math.min(diag*.0007,longest*.025));applyVertices(selectedMesh,tubes(geometry.selectedSegments,radius));selectedMesh.setEnabled(true);diagnostics.outlineRadius=radius;
   }else{selectedMesh.setEnabled(false);diagnostics.outlineRadius=0;}
   if(geometry.peerSegments.length){const positions=Float32Array.from(geometry.peerSegments),indices=Int32Array.from({length:positions.length/3},(_,i)=>i);applyVertices(peerMesh,{positions,indices});peerMesh.setEnabled(true);}else peerMesh.setEnabled(false);
   if(glow)glow.isEnabled=geometry.selectedSegments.length>0;
   diagnostics={...diagnostics,selectedEid:selected.id,propertyId:geometry.propertyId,selectedVisible:geometry.selectedVisible,visiblePeerCount:geometry.peerElementIds.length,peerElementIds:geometry.peerElementIds,meshCount:allMeshes().length,glowEnabled:!!glow?.isEnabled};
  }
  function dispose(){if(disposed)return;disposed=true;glow?.dispose();glow=null;for(const mesh of allMeshes())mesh.dispose(false,true);selectedMesh=null;peerMesh=null;sources=[];cachedGeometry=null;diagnostics={...diagnostics,selectedVisible:false,visiblePeerCount:0,peerElementIds:[],meshCount:0,glowEnabled:false,outlineRadius:0};}
  return{refresh,dispose,get meshes(){return allMeshes();},get diagnostics(){return{...diagnostics,peerElementIds:diagnostics.peerElementIds.slice()};}};
 }
 return{create,collectGeometry,tubes,SELECTED,PEERS};
});
