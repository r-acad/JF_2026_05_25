/* Cyan sections of the displayed aerodynamic triangles. Display-only: changing
 * cut count never regenerates the mesh or changes loads/results. Planes stay
 * equally spaced in baseline BASIC Y; the current deformed surface is clipped.
 * Babylon coordinates are [BASIC Y, BASIC Z, BASIC X], hence clip axis zero.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLoftCuts=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const COLOR='#00ffff',DEFAULT_COUNT=10,MAX_COUNT=200;
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
 function create({BABYLON:B=globalThis.BABYLON,scene,parent=null,data,mesh:source,basePositions}={}){
  const positionKind=B?.VertexBuffer?.PositionKind||'position',current=()=>source?.getVerticesData?.(positionKind);
  const raw=floats(data?.aero?.xyz),baseline=basePositions||current(),nativeSpan=raw.length?bounds(raw,1):bounds(baseline,0);
  const indices=source?.getIndices?.();let available=!!(source&&indices?.length&&nativeSpan),visible=false,count=DEFAULT_COUNT,planes=[],helper=null,capacity=0,buffer=null,disposed=false,last={sections:[],segmentCount:0};
  if(available){try{validateTopology(current(),indices);}catch(_){available=false;}}
  function setPlanes(){planes=available?Array.from({length:count},(_,i)=>nativeSpan.min+(nativeSpan.max-nativeSpan.min)*(i+1)/(count+1)):[];}
  function ensureMesh(vertices){
   if(helper&&capacity>=vertices)return;
   helper?.dispose(false,true);capacity=2;while(capacity<vertices)capacity*=2;
   buffer=new Float32Array(3*capacity);const colors=new Float32Array(4*capacity),vd=new B.VertexData();
   // LinesMesh's vertex-color shader uses this buffer directly; mesh.color
   // alone does not tint white vertices. Keep every allocated vertex cyan,
   // including spare pairs and buffers created after a cut-count increase.
   for(let i=0;i<colors.length;i+=4){colors[i]=0;colors[i+1]=1;colors[i+2]=1;colors[i+3]=1;}
   helper=new B.LinesMesh('aerodynamic-loft-cuts',scene,null,undefined,false,true,false);vd.positions=buffer;vd.indices=Int32Array.from({length:capacity},(_,i)=>i);vd.colors=colors;vd.applyToMesh(helper,true);
   helper.color=B.Color3.FromHexString(COLOR);helper.alpha=1;helper.isPickable=false;helper.parent=parent;helper.renderingGroupId=1;
   helper.material.zOffset=-2;helper.material.zOffsetUnits=-2;helper.material.disableDepthWrite=false;
   helper.material.alpha=1;if(B.Material)helper.material.transparencyMode=B.Material.MATERIAL_OPAQUE;
   helper.metadata={wingViewHelper:true,loftCuts:true,cutPlaneAxis:'BASIC Y',fixedBaselinePlanes:true};
  }
  function update(){
   if(disposed)return false;
   if(!available||!visible){helper?.setEnabled(false);return false;}
   const positions=current();last=intersectTriangles(positions,indices,planes,{validate:false});
   if(!last.segmentCount){helper?.setEnabled(false);return true;}
   ensureMesh(2*last.segmentCount);let offset=0;
   for(const section of last.sections)for(const segment of section.segments)for(const p of segment)for(const coordinate of p)buffer[offset++]=coordinate;
   // Spare paired vertices coincide, producing zero-length invisible segments.
   const x=buffer[offset-3],y=buffer[offset-2],z=buffer[offset-1];for(let i=offset;i<buffer.length;i+=3){buffer[i]=x;buffer[i+1]=y;buffer[i+2]=z;}
   helper.updateVerticesData(positionKind,buffer,true,false);helper.setEnabled(true);return true;
  }
  function configure(options={}){
   if(disposed)return false;
   const next=options.count===undefined?count:normalizeCount(options.count),changed=next!==count,oldVisible=visible;count=next;
   if(options.visible!==undefined){if(typeof options.visible!=='boolean')throw Error('Loft-cut visibility must be a boolean.');visible=options.visible;}
   if(changed||!planes.length)setPlanes();
   // UI synchronization calls configure frequently. Geometry only changes
   // through the explicit update hook after deformation, or changed controls.
   if(!changed&&visible===oldVisible)return available&&visible;
   return update();
  }
  function dispose(){if(disposed)return;disposed=true;helper?.dispose(false,true);helper=null;buffer=null;capacity=0;last={sections:[],segmentCount:0};}
  setPlanes();
  return{configure,update,dispose,get available(){return available&&!disposed;},get count(){return count;},get planes(){return planes.slice();},get visible(){return visible;},get mesh(){return helper;},get sections(){return last.sections;},get segmentCount(){return last.segmentCount;}};
 }
 return{COLOR,DEFAULT_COUNT,MAX_COUNT,normalizeCount,equallySpacedPlanes,intersectTriangles,create};
});
