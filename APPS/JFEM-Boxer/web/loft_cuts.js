/* Sections of aerodynamic and optional reference triangles. Display-only: changing
 * cut count never regenerates the mesh or changes loads/results. Planes stay
 * equally spaced in baseline BASIC Y; the current deformed surface is clipped.
 * Babylon coordinates are [BASIC Y, BASIC Z, BASIC X], hence clip axis zero.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLoftCuts=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const REFERENCE_COLOR='#ff40d8',COLOR='#00ffff',DEFAULT_COUNT=10,MAX_COUNT=200;
 function normalizeCount(value){if(typeof value!=='number'||!Number.isInteger(value)||value<1||value>MAX_COUNT)throw Error('Number of loft cuts must be a whole number from 1 to '+MAX_COUNT+'.');return value;}
 function floats(value){
  if(value instanceof Float32Array||value instanceof Float64Array)return value;
  if(Array.isArray(value))return value;
  if(value instanceof ArrayBuffer)return new Float32Array(value);
  if(ArrayBuffer.isView(value)){const bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength);if(bytes.byteLength%4)return[];return new Float32Array(bytes.byteOffset%4?bytes.slice().buffer:bytes.buffer,bytes.byteOffset%4?0:bytes.byteOffset,bytes.byteLength/4);}
  return[];
 }
 function bounds(positions,axis=0){
  if(!Number.isInteger(axis)||axis<0||axis>2)throw Error('Invalid loft-cut coordinate axis.');
  if(!positions||positions.length<6||positions.length%3)return null;
  let min=Infinity,max=-Infinity;
  for(let i=axis;i<positions.length;i+=3){const v=positions[i];if(!Number.isFinite(v))return null;min=Math.min(min,v);max=Math.max(max,v);}
  return max>min?{min,max}:null;
 }
 function equallySpacedPlanes(positions,count=DEFAULT_COUNT,{axis=0}={}){
  normalizeCount(count);const span=bounds(positions,axis);if(!span)return[];
  return Array.from({length:count},(_,i)=>span.min+(span.max-span.min)*(i+1)/(count+1));
 }
 function lowerBound(values,value){let lo=0,hi=values.length;while(lo<hi){const mid=(lo+hi)>>>1;if(values[mid]<value)lo=mid+1;else hi=mid;}return lo;}
 function upperBound(values,value){let lo=0,hi=values.length;while(lo<hi){const mid=(lo+hi)>>>1;if(values[mid]<=value)lo=mid+1;else hi=mid;}return lo;}
 function validateTopology(positions,indices){
  if(!positions||positions.length%3||!indices||indices.length%3)throw Error('Loft cuts require triangle positions and connectivity.');
  for(const value of positions)if(!Number.isFinite(value))throw Error('Loft cuts cannot use non-finite surface coordinates.');
  const n=positions.length/3;
  for(const id of indices)if(!Number.isInteger(id)||id<0||id>=n)throw Error('Loft cuts have invalid triangle connectivity.');
 }
 // Intersect only planes that overlap each triangle's axial bounds. Compared
 // with rescanning the entire mesh for every plane, fine span meshes therefore
 // scale chiefly with their intersected strips, not count * all triangles.
 function intersectTriangles(positions,indices,planes,{axis=0,tolerance,validate=true}={}){
  if(validate)validateTopology(positions,indices);
  if(!Number.isInteger(axis)||axis<0||axis>2)throw Error('Invalid loft-cut coordinate axis.');
  if(!Array.isArray(planes)||planes.some((v,i)=>!Number.isFinite(v)||i&&v<=planes[i-1]))throw Error('Loft-cut planes must be finite and strictly increasing.');
  const sections=planes.map(plane=>({plane,segments:[]}));if(!planes.length)return{sections,segmentCount:0};
  const extent=bounds(positions,axis),span=extent?extent.max-extent.min:0,absolute=extent?Math.max(Math.abs(extent.min),Math.abs(extent.max)):Math.max(...planes.map(Math.abs));
  const eps=tolerance===undefined?Math.max(span*1e-10,64*Number.EPSILON*Math.max(1,absolute)):tolerance;
  if(!Number.isFinite(eps)||eps<0)throw Error('Invalid loft-cut tolerance.');
  const maps=planes.map(()=>new Map());
  const point=id=>[positions[3*id],positions[3*id+1],positions[3*id+2]];
  function add(map,a,b,coplanar=false){
   if(a.key===b.key||Math.hypot(...a.p.map((v,i)=>v-b.p[i]))<=eps)return;
   const key=a.key<b.key?a.key+'|'+b.key:b.key+'|'+a.key,old=map.get(key);
   if(old){if(coplanar)old.coplanar++;else old.crossing=true;}
   else map.set(key,{a:a.p,b:b.p,coplanar:coplanar?1:0,crossing:!coplanar});
  }
  for(let i=0;i<indices.length;i+=3){
   const ids=[indices[i],indices[i+1],indices[i+2]],v=ids.map(id=>positions[3*id+axis]);
   if(v.some(n=>!Number.isFinite(n)))throw Error('Loft cuts cannot use non-finite surface coordinates.');
   const first=lowerBound(planes,Math.min(...v)-eps),end=upperBound(planes,Math.max(...v)+eps);
   if(first===end)continue;
   const a=point(ids[0]),b=point(ids[1]),c=point(ids[2]),ab=b.map((n,j)=>n-a[j]),ac=c.map((n,j)=>n-a[j]);
   const twiceArea=Math.hypot(ab[1]*ac[2]-ab[2]*ac[1],ab[2]*ac[0]-ab[0]*ac[2],ab[0]*ac[1]-ab[1]*ac[0]);
   if(!Number.isFinite(twiceArea)||twiceArea<=1e-14*Math.max(ab.reduce((s,n)=>s+n*n,0),ac.reduce((s,n)=>s+n*n,0)))continue;
   for(let k=first;k<end;k++){
    const plane=planes[k],d=v.map(n=>n-plane),on=d.map(n=>Math.abs(n)<=eps),map=maps[k];
    const vertex=j=>{const p=point(ids[j]);p[axis]=plane;return{key:'v:'+ids[j],p};};
    if(on.every(Boolean)){
     for(let e=0;e<3;e++)add(map,vertex(e),vertex((e+1)%3),true);
     continue;
    }
    const points=new Map();
    for(let e=0;e<3;e++){
     const next=(e+1)%3;
     if(on[e]){const a=vertex(e);points.set(a.key,a);}
     if(!on[e]&&!on[next]&&(d[e]<0)!==(d[next]<0)){
      const a=point(ids[e]),b=point(ids[next]),t=d[e]/(d[e]-d[next]),p=a.map((n,j)=>n+t*(b[j]-n));p[axis]=plane;
      const lo=Math.min(ids[e],ids[next]),hi=Math.max(ids[e],ids[next]),key='e:'+lo+':'+hi;points.set(key,{key,p});
     }
    }
    if(points.size===2){const[a,b]=points.values();add(map,a,b);}
   }
  }
  let segmentCount=0;
  for(let i=0;i<maps.length;i++)for(const record of maps[i].values()){
   // A coplanar patch contributes its boundary once, not its triangulation
   // diagonals. Adjacent transverse triangles retain that same boundary.
   if(record.crossing||record.coplanar===1){sections[i].segments.push([record.a,record.b]);segmentCount++;}
  }
  return{sections,segmentCount};
 }
 // Babylon matrices map local coordinates to world coordinates. Transform into
 // the loft parent's frame before clipping, then parent the lines exactly once.
 function transformPositions(positions,matrix){
  const m=matrix?.m||matrix;if(!m||m.length!==16||Array.from(m).some(v=>!Number.isFinite(v)))throw Error('Reference cuts need a finite 4 by 4 transform.');
  const result=new Float64Array(positions.length);
  for(let i=0;i<positions.length;i+=3){const x=positions[i],y=positions[i+1],z=positions[i+2],w=m[3]*x+m[7]*y+m[11]*z+m[15];
   if(!Number.isFinite(w)||Math.abs(w)<1e-20)throw Error('Reference cut transform is singular.');
   result[i]=(m[0]*x+m[4]*y+m[8]*z+m[12])/w;result[i+1]=(m[1]*x+m[5]*y+m[9]*z+m[13])/w;result[i+2]=(m[2]*x+m[6]*y+m[10]*z+m[14])/w;
  }return result;
 }
 function createLines(B,scene,parent,name,metadata,initialColor){
  let mesh=null,capacity=0,positions=null,colors=null,color=initialColor;
  function paint(){if(!colors)return;const rgb=[1,3,5].map(i=>parseInt(color.slice(i,i+2),16)/255);for(let i=0;i<colors.length;i+=4){colors[i]=rgb[0];colors[i+1]=rgb[1];colors[i+2]=rgb[2];colors[i+3]=1;}}
  function setColor(value){if(value===color)return;color=value;paint();if(mesh){mesh.color=B.Color3.FromHexString(color);mesh.updateVerticesData(B.VertexBuffer.ColorKind||'color',colors,false,false);}}
  function dispose(){mesh?.dispose(false,true);mesh=null;capacity=0;positions=null;colors=null;}
  function update(result){
   if(!result.segmentCount){mesh?.setEnabled(false);return;}
   const vertices=2*result.segmentCount;
   if(!mesh||capacity<vertices){dispose();capacity=2;while(capacity<vertices)capacity*=2;positions=new Float32Array(3*capacity);colors=new Float32Array(4*capacity);paint();
    mesh=new B.LinesMesh(name,scene,null,undefined,false,true,false);const vd=new B.VertexData();vd.positions=positions;vd.indices=Int32Array.from({length:capacity},(_,i)=>i);vd.colors=colors;vd.applyToMesh(mesh,true);
    mesh.color=B.Color3.FromHexString(color);mesh.alpha=1;mesh.isPickable=false;mesh.parent=parent;mesh.renderingGroupId=1;
    // Nonzero line depth bias invalidates WebGPU pipelines and can blank the
    // entire viewport. Use physical positions with normal depth testing.
    mesh.material.zOffset=0;mesh.material.zOffsetUnits=0;mesh.material.disableDepthWrite=false;mesh.material.alpha=1;if(B.Material)mesh.material.transparencyMode=B.Material.MATERIAL_OPAQUE;
    mesh.metadata={wingViewHelper:true,cutPlaneAxis:'BASIC Y',fixedBaselinePlanes:true,...metadata};
   }
   let offset=0;for(const section of result.sections)for(const segment of section.segments)for(const point of segment)for(const value of point)positions[offset++]=value;
   const x=positions[offset-3],y=positions[offset-2],z=positions[offset-1];for(let i=offset;i<positions.length;i+=3){positions[i]=x;positions[i+1]=y;positions[i+2]=z;}
   mesh.updateVerticesData(B.VertexBuffer.PositionKind||'position',positions,true,false);mesh.setEnabled(true);
  }
  return{update,setColor,dispose,hide(){mesh?.setEnabled(false);},get mesh(){return mesh;}};
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,parent=null,data,mesh:source,basePositions,getReferenceMeshes=()=>[],getReferenceRevision=()=>0}={}){
  const positionKind=B?.VertexBuffer?.PositionKind||'position',current=()=>source?.getVerticesData?.(positionKind);
  const raw=floats(data?.aero?.xyz),baseline=basePositions||current(),nativeSpan=raw.length?bounds(raw,1):bounds(baseline,0),indices=source?.getIndices?.();
  let available=!!(source&&indices?.length&&nativeSpan),visible=false,referenceVisible=false,count=DEFAULT_COUNT,color=COLOR,referenceColor=REFERENCE_COLOR,planes=[],disposed=false,last={sections:[],segmentCount:0},referenceLast={sections:[],segmentCount:0};
  if(available){try{validateTopology(current(),indices);}catch(_){available=false;}}
  const loftLines=createLines(B,scene,parent,'aerodynamic-loft-cuts',{loftCuts:true},color),referenceLines=createLines(B,scene,parent,'reference-loft-cuts',{referenceLoftCuts:true},referenceColor);
  let referenceRevision,referenceSources=[],referenceGeometry=null,parentElements=null,referenceDirty=true,referenceBuilds=0;
  const sameMatrix=(a,b)=>a&&b&&a.length===b.length&&a.every((value,i)=>value===b[i]);
  function setPlanes(){planes=available?Array.from({length:count},(_,i)=>nativeSpan.min+(nativeSpan.max-nativeSpan.min)*(i+1)/(count+1)):[];referenceDirty=true;}
  function surfaceMesh(mesh){
   if(!mesh||mesh.isDisposed?.()||mesh.metadata?.wingViewHelper||mesh.metadata?.wingReferenceTriangles===false||mesh.getClassName?.()==='LinesMesh')return false;
   if(mesh.metadata?.wingReferenceTriangles===true)return true;
   const mode=mesh.material?.fillMode;return mode===undefined||mode===(B.Material?.TriangleFillMode??0)||mode===(B.Material?.WireFrameFillMode??1);
  }
  function syncReferenceSources(){
   const revision=getReferenceRevision();if(referenceRevision===revision)return false;referenceRevision=revision;
   referenceSources=Array.from(new Set(getReferenceMeshes()||[])).filter(surfaceMesh);referenceGeometry=null;referenceDirty=true;
   if(!referenceSources.length){referenceLines.dispose();referenceLast={sections:[],segmentCount:0};}
   return true;
  }
  function parentWorld(){return parent?.computeWorldMatrix?.()||parent?.getWorldMatrix?.()||null;}
  function prepareReferenceGeometry(world){
   const inverse=world?world.clone().invert():null;referenceGeometry=[];
   for(const mesh of referenceSources){
    if(!surfaceMesh(mesh))continue;const positions=mesh.getVerticesData?.(positionKind),triangles=mesh.getIndices?.();if(!positions?.length||!triangles?.length||triangles.length%3)continue;
    validateTopology(positions,triangles);const meshWorld=mesh.computeWorldMatrix?.(true)||mesh.getWorldMatrix?.();if(!meshWorld)continue;
    // Standard instances expose their own world matrix. Thin-instance matrices
    // are local to the source mesh and must also include its complete hierarchy.
    const instances=mesh.hasThinInstances?mesh.thinInstanceGetWorldMatrices():[null];
    for(const instance of instances){const worldMatrix=instance?instance.multiply(meshWorld):meshWorld,relative=inverse?worldMatrix.multiply(inverse):worldMatrix;referenceGeometry.push({positions:transformPositions(positions,relative),indices:triangles});}
   }
  }
  function updateReferences(){
   if(disposed)return false;syncReferenceSources();
   if(!available||!referenceVisible||!referenceSources.length){referenceLines.hide();return false;}
   const world=parentWorld(),elements=world?.m||null;
   if(world&&!sameMatrix(parentElements,elements)||!world&&parentElements){parentElements=elements?Array.from(elements):null;referenceGeometry=null;referenceDirty=true;}
   if(!referenceDirty){referenceLines.mesh?.setEnabled(referenceLast.segmentCount>0);return true;}
   if(!referenceGeometry)prepareReferenceGeometry(world);
   referenceLast={sections:planes.map(plane=>({plane,segments:[]})),segmentCount:0};
   for(const geometry of referenceGeometry){const result=intersectTriangles(geometry.positions,geometry.indices,planes,{validate:false});for(let i=0;i<planes.length;i++)for(const segment of result.sections[i].segments)referenceLast.sections[i].segments.push(segment);referenceLast.segmentCount+=result.segmentCount;}
   referenceBuilds++;referenceDirty=false;referenceLines.update(referenceLast);return true;
  }
  function update(){
   if(disposed)return false;
   if(available&&visible){last=intersectTriangles(current(),indices,planes,{validate:false});loftLines.update(last);}else loftLines.hide();
   updateReferences();return available&&(visible||referenceVisible);
  }
  function configure(options={}){
   if(disposed)return false;
   for(const key of ['color','referenceColor'])if(options[key]!==undefined){if(typeof options[key]!=='string'||!/^#[0-9a-f]{6}$/i.test(options[key]))throw Error('Loft intersection color must be a six-digit hex color.');if(key==='color'){color=options[key].toLowerCase();loftLines.setColor(color);}else{referenceColor=options[key].toLowerCase();referenceLines.setColor(referenceColor);}}
   const next=options.count===undefined?count:normalizeCount(options.count),changed=next!==count,oldVisible=visible,oldReferenceVisible=referenceVisible;count=next;
   for(const key of ['visible','referenceVisible'])if(options[key]!==undefined&&typeof options[key]!=='boolean')throw Error('Loft-cut visibility must be a boolean.');
   if(options.visible!==undefined)visible=options.visible;if(options.referenceVisible!==undefined)referenceVisible=options.referenceVisible;
   if(changed||!planes.length)setPlanes();
   if(changed||visible!==oldVisible)return update();
   if(referenceVisible!==oldReferenceVisible)updateReferences();
   return available&&(visible||referenceVisible);
  }
  function refreshReferences(){if(disposed)return false;syncReferenceSources();return updateReferences();}
  // Only matrix/revision checks run per frame. Static references are never
  // re-intersected merely because the aerodynamic loft animates or is hidden.
  const observer=scene?.onBeforeRenderObservable?.add(()=>{if(referenceVisible)updateReferences();});
  function dispose(){if(disposed)return;disposed=true;if(observer)scene.onBeforeRenderObservable.remove(observer);loftLines.dispose();referenceLines.dispose();referenceSources=[];referenceGeometry=null;last={sections:[],segmentCount:0};referenceLast={sections:[],segmentCount:0};}
  setPlanes();syncReferenceSources();
  return{configure,update,refreshReferences,dispose,get available(){return available&&!disposed;},get count(){return count;},get color(){return color;},get planes(){return planes.slice();},get visible(){return visible;},get mesh(){return loftLines.mesh;},get sections(){return last.sections;},get segmentCount(){return last.segmentCount;},
   get referenceAvailable(){return available&&!disposed&&referenceSources.length>0;},get referenceVisible(){return referenceVisible;},get referenceColor(){return referenceColor;},get referenceMesh(){return referenceLines.mesh;},get referenceSections(){return referenceLast.sections;},get referenceSegmentCount(){return referenceLast.segmentCount;},get referenceBuilds(){return referenceBuilds;}};
 }

 return{COLOR,REFERENCE_COLOR,DEFAULT_COUNT,MAX_COUNT,normalizeCount,equallySpacedPlanes,intersectTriangles,transformPositions,create};
});
