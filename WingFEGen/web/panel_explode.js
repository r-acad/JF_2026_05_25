/* View-only rigid panel translations; never modify FE or result coordinates. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPanelExplode=api;})(globalThis,function(){
 'use strict';
 const ZERO=Object.freeze([0,0,0]);
 function normalize(value){
  if(value!=null&&(typeof value!=='object'||Array.isArray(value)))throw Error('Panel explosion settings must be an object.');
  const v=value||{},enabled=v.enabled??false,origin=v.origin??'centroid',distance=v.distance??1;
  if(typeof enabled!=='boolean'||!['centroid','midspan','ribbay'].includes(origin)||typeof distance!=='number'||!Number.isFinite(distance)||distance<0||distance>10000)throw Error('Panel explosion needs a valid origin and distance from 0 to 10000 m.');
  return{enabled,origin,distance};
 }
 function create(){
  let settings=normalize(),panels=[],elements=new Map(),positions=null,ribs=[],offsets=new Map(),byElement=new Map(),origins=new Map(),center=ZERO;
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
   offsets=new Map();byElement=new Map();origins=new Map();const all=new Set();
   for(const panel of panels)for(const id of [...panel.shell_eids,...panel.stringer_eids]){byElement.set(id,panel.id);for(const n of elements.get(id)?.nodes||[])all.add(n);}
   // A geometric centroid of unique structural GRID positions, independent
   // of meshing duplication between skins and normal stringers.
   const structural=new Set();for(const e of elements.values())if(['quad','tria','bar'].includes(e.group.kind))for(const n of e.nodes)structural.add(n);
   const nodes=[...(structural.size?structural:all)],mean=[0,0,0],lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
   for(const n of nodes)for(let a=0;a<3;a++){const v=positions[3*n+a];mean[a]+=v/nodes.length;lo[a]=Math.min(lo[a],v);hi[a]=Math.max(hi[a],v);}
   center=nodes.length?(settings.origin==='midspan'?lo.map((v,a)=>(v+hi[a])/2):mean):ZERO;
   const bayNodes=new Map(),ribOrigins=ribCenters();
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
    const origin=settings.origin==='ribbay'?(bayOrigins.get(bayId(panel))||center):center;origins.set(panel.id,origin);
    let v=p.map((x,a)=>x-origin[a]),length=Math.hypot(...v);
    if(length<1e-12){v=[0,panel.skin==='lower'?-1:1,0];length=1;}
    offsets.set(panel.id,v.map(x=>settings.enabled?x/length*settings.distance:0));
   }
  }
  function configure(index,modelElements,modelPositions,ribLayout){panels=index?.panels||[];elements=modelElements||new Map();positions=modelPositions;ribs=ribLayout?.ribs||[];rebuild();}
  function restore(value){settings=normalize(value);rebuild();return capture();}
  function capture(){return{...settings};}
  function offsetPanel(id){return offsets.get(id)||ZERO;}
  function offsetElement(id){return offsetPanel(byElement.get(id));}
  function point(id,p){const offset=offsetElement(id);return p.map((v,a)=>v+offset[a]);}
  function applyMesh(mesh,panelId=mesh.metadata?.feGroup?.panel_id??mesh.explodedPanelId){
   const v=offsetPanel(panelId);if(mesh.position.x!==v[0]||mesh.position.y!==v[1]||mesh.position.z!==v[2])mesh.position.copyFromFloats(...v);
  }
  return{configure,restore,capture,offsetPanel,offsetElement,point,applyMesh,originPanel:id=>(origins.get(id)||center).slice(),get active(){return settings.enabled&&settings.distance>0&&panels.length>0;},get center(){return center.slice();}};
 }
 return{normalize,create};
});
