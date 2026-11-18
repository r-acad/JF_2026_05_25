/* Physical RF shell fragments are viewport geometry only. Their barycentric
 * vertices retain the original element, GRID and property identities. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFPanelRender=api;})(globalThis,function(){
 'use strict';
 const sub=(a,b)=>a.map((v,i)=>v-b[i]),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],
  norm=a=>Math.hypot(...a),at=(p,i)=>Array.from(p.subarray(3*i,3*i+3));
 function geometry({index,contour,elements,positions,onlyBelowOne=false,allowed=null,visible=()=>true,explosion,thickness=false,quantum=1e-7,selectedScopeKey,selectedElement}={}){
  const groups=new Map(),partEdges=new Map(),covered=new Set(),visibleParts=new Set(),visibleElements=new Set();
  const pointKey=p=>p.map(v=>Math.round(v/quantum)).join(','),edgeKey=(a,b)=>{const x=pointKey(a),y=pointKey(b);return x<y?x+'|'+y:y+'|'+x;};
  function edge(a,b,key,partKey){if(norm(sub(a,b))<=quantum*.01)return;const id=key+'|'+edgeKey(a,b);let record=partEdges.get(id);if(record)record.count++;else partEdges.set(id,{a,b,count:1,partKey});}
  for(const part of index?.parts||[])for(const fragment of part.fragments||[])covered.add(fragment.eid);
  for(const part of index?.parts||[]){
   if(onlyBelowOne&&!contour.failingPartKeys?.has(part.key))continue;
   const color=contour.colorByPart?.get(part.key)||[.32,.36,.41];
   for(const fragment of part.fragments||[]){
    const element=elements.get(fragment.eid);if(!element||!visible(element)||allowed&&!allowed.has(fragment.eid))continue;
    const group=element.group,key=group.name+'|'+group.pid;
    if(!groups.has(key))groups.set(key,{group,positions:[],colors:[],indices:[],faceElements:[],elementIds:[],partKeys:[],edges:[],edgeRecords:new Map()});
    const out=groups.get(key),owner=out.elementIds.length;out.elementIds.push(fragment.eid);out.partKeys.push(part.key);
    const points=fragment.vertices.map(vertex=>{
     const p=[0,0,0];for(let i=0;i<element.nodes.length;i++){const weight=vertex.weights[i]||0,node=element.nodes[i];for(let c=0;c<3;c++)p[c]+=weight*positions[3*node+c];}
     return explosion?.point?explosion.point(fragment.eid,p):p;
    });
    const original=Array.from(element.nodes,i=>at(positions,i));let normal=original.length===4?cross(sub(original[2],original[0]),sub(original[3],original[1])):cross(sub(original[1],original[0]),sub(original[2],original[0]));
    const length=norm(normal);normal=length>1e-20?normal.map(v=>v/length):[0,0,1];
    const p=group.properties||{},t=Number(p.thickness_m),bottom=Number.isFinite(p.z_bottom_m)?p.z_bottom_m:Number.isFinite(p.z0_m)?p.z0_m:-t/2,
     top=Number.isFinite(p.z_top_m)?p.z_top_m:bottom+t,solid=thickness&&p.thickness_display_supported!==false&&t>0&&Number.isFinite(bottom)&&Number.isFinite(top)&&top>bottom,
     faces=solid?[points.map(a=>a.map((v,c)=>v+bottom*normal[c])),points.map(a=>a.map((v,c)=>v+top*normal[c]))]:[points];
    function triangle(a,b,c){const start=out.positions.length/3;for(const v of[a,b,c]){out.positions.push(...v);out.colors.push(...color,1);}out.indices.push(start,start+1,start+2);out.faceElements.push(owner);}
    for(let side=0;side<faces.length;side++){
     const face=faces[side];for(let i=1;i+1<face.length;i++)solid&&side===0?triangle(face[0],face[i+1],face[i]):triangle(face[0],face[i],face[i+1]);
     for(let i=0;i<face.length;i++){const a=face[i],b=face[(i+1)%face.length],id=part.key+'|'+fragment.eid+'|'+edgeKey(a,b),prior=out.edgeRecords.get(id);
      if(prior)prior.count++;else out.edgeRecords.set(id,{a,b,count:1,partKey:part.key,eid:fragment.eid});
      edge(a,b,part.key+(explosion?.by==='property'?':P'+group.pid:''),part.key);}
    }
    if(solid)for(let i=0;i<points.length;i++){const j=(i+1)%points.length;triangle(faces[0][i],faces[0][j],faces[1][j]);triangle(faces[0][i],faces[1][j],faces[1][i]);}
    visibleParts.add(part.key);visibleElements.add(fragment.eid);
   }
  }
  const outlines=[],selected=[],picked=[],seen=new Set();
  for(const out of groups.values()){const drawn=new Set();for(const record of out.edgeRecords.values())if(record.count===1){const key=edgeKey(record.a,record.b);
    if(!drawn.has(key)){drawn.add(key);out.edges.push(...record.a,...record.b);}
    if(record.partKey===selectedScopeKey&&record.eid===selectedElement)picked.push(...record.a,...record.b);
   }delete out.edgeRecords;}
  for(const record of partEdges.values())if(record.count===1){const key=edgeKey(record.a,record.b);if(!seen.has(key)){seen.add(key);outlines.push(...record.a,...record.b);}if(record.partKey===selectedScopeKey)selected.push(...record.a,...record.b);}
  return{groups,coveredShellIds:covered,visiblePartKeys:visibleParts,visibleElementIds:visibleElements,outlines:Float32Array.from(outlines),selectedOutlines:Float32Array.from(selected),pickedEdges:Float32Array.from(picked)};
 }
 function create({B,state,shellMaterial,lineMesh}={}){
  const records=new Map();let outline=null,selection=null,picked=null,last=null;
  function dispose(){for(const record of records.values()){record.mesh.dispose(false,true);record.edges?.dispose(false,true);}records.clear();for(const mesh of[outline,selection,picked])mesh?.dispose(false,true);outline=selection=picked=null;last=null;}
  function line(prior,name,points,color,width){
   if(!points.length){prior?.dispose(false,true);return null;}
   if(!prior||prior.isDisposed()||prior.getTotalVertices()!==points.length/3){prior?.dispose(false,true);prior=lineMesh(name,points,Int32Array.from({length:points.length/3},(_,i)=>i),color,1,false);}
   else prior.updateVerticesData(B.VertexBuffer.PositionKind,points,true,false);
   prior.isPickable=false;prior.doNotSerialize=true;prior.renderingGroupId=1;
   prior.metadata={wingViewHelper:true,rfPhysicalPanelEdge:true,...(width?{strokeWidthPx:width}:{})};
   prior.material.disableDepthWrite=true;prior.material.zOffset=0;prior.material.zOffsetUnits=0;return prior;
  }
  function sync(options){
   const contour=options?.contour;if(!contour?.panelScopeIndex||contour.stale){dispose();return null;}
   const elements=new Map([...state.elements].map(([eid,element])=>[eid,{...element,group:contour.panelScopeIndex.elements.get(eid)?.group||element.group}]));
   const data=geometry({...options,index:contour.panelScopeIndex,elements,quantum:Math.max(1e-9,state.diag*1e-8)}),keep=new Set();
   const sourceByName=new Map();for(const mesh of state.shellMeshes||[]){const name=mesh.metadata?.feGroup?.name;if(!sourceByName.has(name)||mesh.isEnabled())sourceByName.set(name,mesh);}
   for(const[key,group]of data.groups){
    keep.add(key);let record=records.get(key);
    if(!record){const mesh=new B.Mesh('RF_PHYSICAL_PANEL_'+key,state.scene);mesh.parent=state.root;mesh.material=shellMaterial('RF_PHYSICAL_PANEL_MATERIAL_'+key,'#ffffff',1);mesh.isPickable=true;mesh.doNotSerialize=true;mesh.hasVertexAlpha=false;
     mesh.sideOrientation=state.scene.useRightHandedSystem?B.Material.CounterClockWiseSideOrientation:B.Material.ClockWiseSideOrientation;record={mesh,edges:null};records.set(key,record);}
    const mesh=record.mesh,vd=new B.VertexData(),points=Float32Array.from(group.positions),indices=Int32Array.from(group.indices),normals=new Float32Array(points.length);
    B.VertexData.ComputeNormals(points,indices,normals,{useRightHandedSystem:state.scene.useRightHandedSystem});Object.assign(vd,{positions:points,indices,normals,colors:Float32Array.from(group.colors)});vd.applyToMesh(mesh,true);
    mesh.elementIds=Int32Array.from(group.elementIds);mesh.metadata={feGroup:group.group,faceElements:Int32Array.from(group.faceElements),rfPanelPartKeys:group.partKeys,rfPhysicalPanel:true};
    const original=sourceByName.get(group.group.name),material=mesh.material,source=original?.material;
    if(source){material.alpha=source.alpha;material.wireframe=source.wireframe;material.transparencyMode=source.transparencyMode;material.separateCullingPass=source.separateCullingPass;material.zOffset=source.zOffset;material.zOffsetUnits=source.zOffsetUnits;}
    mesh.setEnabled(true);record.edges=line(record.edges,'RF_PHYSICAL_MESH_EDGES_'+key,Float32Array.from(group.edges),options.edgeColor||'#30465a');
    record.edges?.setEnabled(!!options.edgesOn);
   }
   for(const[key,record]of records)if(!keep.has(key)){record.mesh.dispose(false,true);record.edges?.dispose(false,true);records.delete(key);}
   outline=line(outline,'RF_PANEL_OUTLINES',data.outlines,'#103b73',3.5);
   selection=line(selection,'RF_INSPECTED_PANEL',data.selectedOutlines,'#61dcff',4.5);picked=line(picked,'RF_PICKED_FRAGMENT',data.pickedEdges,'#ffffff',2);
   last={...data,meshes:[...records.values()].map(r=>r.mesh),outline,selection,picked};return last;
  }
  return{sync,dispose,get current(){return last;},get meshes(){return[...records.values()].map(r=>r.mesh);}};
 }
 return{geometry,create};
});
