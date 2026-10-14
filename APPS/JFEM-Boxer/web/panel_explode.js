/* View-only rigid panel/property translations; never modify FE or result coordinates. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPanelExplode=api;})(globalThis,function(){
 'use strict';
 const ZERO=Object.freeze([0,0,0]);
 function normalize(value){
  if(value!=null&&(typeof value!=='object'||Array.isArray(value)))throw Error('Panel explosion settings must be an object.');
  const v=value||{},enabled=v.enabled??false,origin=v.origin??'centroid',distance=v.distance??1,by=v.by??'panel';
  if(typeof enabled!=='boolean'||!['panel','property'].includes(by)||!['centroid','midspan','ribbay','rib'].includes(origin)||typeof distance!=='number'||!Number.isFinite(distance)||distance<0||distance>10000)throw Error('Explosion needs a valid grouping, origin and distance from 0 to 10000 m.');
  // Keep old panel-only Studies byte-compatible while persisting the new mode.
  return{enabled,origin,distance,...(by==='property'?{by}: {})};
 }
 function create(){
  let settings=normalize(),panels=[],elements=new Map(),positions=null,ribs=[],offsets=new Map(),byElement=new Map(),origins=new Map(),center=ZERO;
  let properties=new Map(),propertyOffsets=new Map(),propertyOrigins=new Map(),hasRibOrigins=false,effectiveOrigin='centroid';
  const propertyMode=()=>settings.by==='property';
  const structuralElement=e=>['quad','tria','bar','spring'].includes(e.group.kind);
  function elementProperty(e){
   const g=e.group;if(['quad','tria','bar'].includes(g.kind))return g.pid;
   if(g.kind==='spring'&&/^CELAS[13]$/.test(g.card_types?.[e.id]||g.properties?.TYPE||''))return g.properties?.PID;
  }
  const bayId=panel=>Number.isInteger(panel.rib_bay)?panel.rib_bay:Number(String(panel.key||'').match(/(?:^|:)bay(\d+)(?::|$)/)?.[1])||null;
  const meanNodes=nodes=>{const result=[0,0,0];for(const n of nodes)for(let a=0;a<3;a++)result[a]+=positions[3*n+a]/nodes.size;return result;};
  function ribCenters(){
   const result=new Map();
   for(const rib of ribs){const points=[rib.front,rib.rear];if(!points.every(p=>Array.isArray(p)&&p.length===3&&p.every(Number.isFinite)))continue;
    // Metadata is FE XYZ, while panel positions are already viewport YZX.
    const p=points[0].map((v,a)=>(v+points[1][a])/2);result.set(rib.number,[p[1],p[2],p[0]]);
   }return result;
  }
  function rebuild(){
   offsets=new Map();byElement=new Map();origins=new Map();propertyOffsets=new Map();propertyOrigins=new Map();properties=new Map();const all=new Set();
   for(const panel of panels)for(const id of [...panel.shell_eids,...panel.stringer_eids]){byElement.set(id,panel.id);for(const n of elements.get(id)?.nodes||[])all.add(n);}
   // A geometric centroid of unique structural GRID positions, independent
   // of meshing duplication between skins and normal stringers.
   const structural=new Set();for(const [id,e]of elements)if(structuralElement(e)){
    for(const n of e.nodes)structural.add(n);
    const pid=elementProperty(e);if(Number.isInteger(pid)&&pid>0&&e.nodes.length){const members=properties.get(pid)||new Set();for(const n of e.nodes)members.add(n);properties.set(pid,members);if(propertyMode())byElement.set(id,pid);}
   }
   if(propertyMode())for(const [id,e]of elements){const pid=elementProperty(e);if(!Number.isInteger(pid)||pid<=0)byElement.delete(id);}
   const ribOrigins=ribCenters();hasRibOrigins=ribOrigins.size>1;
   effectiveOrigin=propertyMode()&&!hasRibOrigins&&['rib','ribbay'].includes(settings.origin)?'centroid':settings.origin;
   const nodes=[...(structural.size?structural:all)],mean=[0,0,0],lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
   for(const n of nodes)for(let a=0;a<3;a++){const v=positions[3*n+a];mean[a]+=v/nodes.length;lo[a]=Math.min(lo[a],v);hi[a]=Math.max(hi[a],v);}
   center=nodes.length?(effectiveOrigin==='midspan'?lo.map((v,a)=>(v+hi[a])/2):mean):ZERO;
   const bayNodes=new Map();
   for(const panel of panels){const bay=bayId(panel);if(bay===null)continue;const members=bayNodes.get(bay)||new Set();
    for(const id of [...panel.shell_eids,...panel.stringer_eids])for(const n of elements.get(id)?.nodes||[])members.add(n);bayNodes.set(bay,members);
   }
   const bayOrigins=new Map();for(const [bay,members]of bayNodes){const a=ribOrigins.get(bay),b=ribOrigins.get(bay+1);
    // Adjacent physical rib centers include sweep, twist and oblique ribs.
    // Runout panels keep their rib_bay even when one end is not on a rib.
    bayOrigins.set(bay,a&&b?a.map((v,k)=>(v+b[k])/2):members.size?meanNodes(members):center);
   }
   for(const panel of panels){
    const members=new Set();for(const id of panel.shell_eids)for(const n of elements.get(id)?.nodes||[])members.add(n);
    if(!members.size)for(const id of panel.stringer_eids)for(const n of elements.get(id)?.nodes||[])members.add(n);
    const p=[0,0,0];for(const n of members)for(let a=0;a<3;a++)p[a]+=positions[3*n+a]/members.size;
    const bay=bayId(panel),origin=settings.origin==='rib'?(ribOrigins.get(bay)||bayOrigins.get(bay)||center):settings.origin==='ribbay'?(bayOrigins.get(bay)||center):center;origins.set(panel.id,origin);
    let v=p.map((x,a)=>x-origin[a]),length=Math.hypot(...v);
    if(length<1e-12){v=[0,panel.skin==='lower'?-1:1,0];length=1;}
    offsets.set(panel.id,v.map(x=>settings.enabled?x/length*settings.distance:0));
   }
   const bays=[...ribOrigins].sort((a,b)=>a[0]-b[0]).slice(0,-1).map(([id,a])=>{const b=ribOrigins.get(id+1);return b?{inboard:a,center:a.map((v,k)=>(v+b[k])/2)}:null;}).filter(Boolean);
   const ids=[...properties.keys()].sort((a,b)=>a-b),centers=ids.map(id=>meanNodes(properties.get(id))),coincident=new Map();
   const centerKey=p=>p.map(v=>v.toPrecision(12)).join(',');for(let i=0;i<ids.length;i++){const key=centerKey(centers[i]),members=coincident.get(key)||[];members.push(i);coincident.set(key,members);}
   for(let i=0;i<ids.length;i++){
    const id=ids[i],p=centers[i];let origin=center;
    if(bays.length&&['rib','ribbay'].includes(effectiveOrigin)){
     // One PID remains rigid even when it spans many bays. Its centroid
     // chooses the nearest bay; every member uses that same origin.
     let nearest=bays[0],distance=Infinity;for(const bay of bays){const d=bay.center.reduce((sum,v,k)=>sum+(v-p[k])**2,0);if(d<distance){distance=d;nearest=bay;}}
     origin=effectiveOrigin==='rib'?nearest.inboard:nearest.center;
    }
    propertyOrigins.set(id,origin);
    let vector=p.map((v,k)=>v-origin[k]),length=Math.hypot(...vector);
    if(length<1e-12){
     // Coincident property centroids (common for skins and their stiffeners)
     // need distinct deterministic directions instead of identical offsets.
     const y=1-2*(i+.5)/ids.length,r=Math.sqrt(Math.max(0,1-y*y)),angle=i*Math.PI*(3-Math.sqrt(5));vector=[r*Math.cos(angle),y,r*Math.sin(angle)];length=1;
    }else if(coincident.get(centerKey(p)).length>1){
     const members=coincident.get(centerKey(p)),angle=2*Math.PI*members.indexOf(i)/members.length,n=vector.map(v=>v/length),axis=Math.abs(n[1])<.9?[0,1,0]:[1,0,0];
     let u=[n[1]*axis[2]-n[2]*axis[1],n[2]*axis[0]-n[0]*axis[2],n[0]*axis[1]-n[1]*axis[0]],uLength=Math.hypot(...u);u=u.map(v=>v/uLength);
     const v=[n[1]*u[2]-n[2]*u[1],n[2]*u[0]-n[0]*u[2],n[0]*u[1]-n[1]*u[0]];vector=n.map((x,k)=>x+.35*(Math.cos(angle)*u[k]+Math.sin(angle)*v[k]));length=Math.hypot(...vector);
    }
    propertyOffsets.set(id,vector.map(v=>settings.enabled?v/length*settings.distance:0));
   }
  }
  function configure(index,modelElements,modelPositions,ribLayout){panels=index?.panels||[];elements=modelElements||new Map();positions=modelPositions;ribs=ribLayout?.ribs||[];rebuild();}
  function restore(value){settings=normalize(value);rebuild();return capture();}
  function capture(){return{...settings};}
  function offsetPanel(id){return offsets.get(id)||ZERO;}
  function offsetProperty(id){return propertyOffsets.get(id)||ZERO;}
  function offsetElement(id){return propertyMode()?offsetProperty(byElement.get(id)):offsetPanel(byElement.get(id));}
  function point(id,p){const offset=offsetElement(id);return p.map((v,a)=>v+offset[a]);}
  function applyMesh(mesh,panelId=mesh.metadata?.feGroup?.panel_id??mesh.explodedPanelId){
   const v=propertyMode()?offsetProperty(mesh.explodedPropertyId??mesh.metadata?.feGroup?.pid):offsetPanel(panelId);if(mesh.position.x!==v[0]||mesh.position.y!==v[1]||mesh.position.z!==v[2])mesh.position.copyFromFloats(...v);
  }
  function applyVertices(mesh,buffer){
   if(!propertyMode()||!settings.enabled||!settings.distance)return false;
   if(mesh.explodedVertexRanges?.length){
    for(const range of mesh.explodedVertexRanges){const offset=offsetProperty(range.pid);for(let v=range.start;v<range.start+range.count;v++)for(let a=0;a<3;a++)buffer[3*v+a]+=offset[a];}return true;
   }
   if(mesh.explodedElementRanges?.length){
    for(const range of mesh.explodedElementRanges){const offset=offsetElement(range.id);for(let v=range.start;v<range.start+range.count;v++)for(let a=0;a<3;a++)buffer[3*v+a]+=offset[a];}return true;
   }
   if(!mesh.importedRanges?.length)return false;
   const count=mesh.elementIds?.length,per=count?buffer.length/(3*count):0;if(!Number.isInteger(per)||per<1)return false;
   // Imported GPU batches have element-local copies, including shared GRID
   // points. Translate each complete element after its physical pose update.
   for(const range of mesh.importedRanges){const offset=offsetProperty(range.group.pid);for(let v=range.start*per;v<(range.start+range.count)*per;v++)for(let a=0;a<3;a++)buffer[3*v+a]+=offset[a];}
   return true;
  }
  return{configure,restore,capture,offsetPanel,offsetProperty,offsetElement,point,applyMesh,applyVertices,originPanel:id=>(origins.get(id)||center).slice(),originProperty:id=>(propertyOrigins.get(id)||center).slice(),
   get by(){return propertyMode()?'property':'panel';},get propertyCount(){return properties.size;},get hasRibOrigins(){return hasRibOrigins;},get effectiveOrigin(){return effectiveOrigin;},
   get active(){return settings.enabled&&settings.distance>0&&(propertyMode()?properties.size:panels.length)>0;},get center(){return center.slice();}};
 }
 return{normalize,create};
});
