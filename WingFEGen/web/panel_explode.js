/* View-only rigid panel translations; never modify FE or result coordinates. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPanelExplode=api;})(globalThis,function(){
 'use strict';
 const ZERO=Object.freeze([0,0,0]);
 function normalize(value){
  if(value!=null&&(typeof value!=='object'||Array.isArray(value)))throw Error('Panel explosion settings must be an object.');
  const v=value||{},enabled=v.enabled??false,origin=v.origin??'centroid',distance=v.distance??1;
  if(typeof enabled!=='boolean'||!['centroid','midspan'].includes(origin)||typeof distance!=='number'||!Number.isFinite(distance)||distance<0||distance>10000)throw Error('Panel explosion needs a valid origin and distance from 0 to 10000 m.');
  return{enabled,origin,distance};
 }
 function create(){
  let settings=normalize(),panels=[],elements=new Map(),positions=null,offsets=new Map(),byElement=new Map(),center=ZERO;
  function rebuild(){
   offsets=new Map();byElement=new Map();const all=new Set();
   for(const panel of panels)for(const id of [...panel.shell_eids,...panel.stringer_eids]){byElement.set(id,panel.id);for(const n of elements.get(id)?.nodes||[])all.add(n);}
   // A geometric centroid of unique structural GRID positions, independent
   // of meshing duplication between skins and normal stringers.
   const structural=new Set();for(const e of elements.values())if(['quad','tria','bar'].includes(e.group.kind))for(const n of e.nodes)structural.add(n);
   const nodes=[...(structural.size?structural:all)],mean=[0,0,0],lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
   for(const n of nodes)for(let a=0;a<3;a++){const v=positions[3*n+a];mean[a]+=v/nodes.length;lo[a]=Math.min(lo[a],v);hi[a]=Math.max(hi[a],v);}
   center=nodes.length?(settings.origin==='midspan'?lo.map((v,a)=>(v+hi[a])/2):mean):ZERO;
   for(const panel of panels){
    const members=new Set();for(const id of panel.shell_eids)for(const n of elements.get(id)?.nodes||[])members.add(n);
    if(!members.size)for(const id of panel.stringer_eids)for(const n of elements.get(id)?.nodes||[])members.add(n);
    const p=[0,0,0];for(const n of members)for(let a=0;a<3;a++)p[a]+=positions[3*n+a]/members.size;
    let v=p.map((x,a)=>x-center[a]),length=Math.hypot(...v);
    if(length<1e-12){v=[0,panel.skin==='lower'?-1:1,0];length=1;}
    offsets.set(panel.id,v.map(x=>settings.enabled?x/length*settings.distance:0));
   }
  }
  function configure(index,modelElements,modelPositions){panels=index?.panels||[];elements=modelElements||new Map();positions=modelPositions;rebuild();}
  function restore(value){settings=normalize(value);rebuild();return capture();}
  function capture(){return{...settings};}
  function offsetPanel(id){return offsets.get(id)||ZERO;}
  function offsetElement(id){return offsetPanel(byElement.get(id));}
  function point(id,p){const offset=offsetElement(id);return p.map((v,a)=>v+offset[a]);}
  function applyMesh(mesh,panelId=mesh.metadata?.feGroup?.panel_id??mesh.explodedPanelId){
   const v=offsetPanel(panelId);if(mesh.position.x!==v[0]||mesh.position.y!==v[1]||mesh.position.z!==v[2])mesh.position.copyFromFloats(...v);
  }
  return{configure,restore,capture,offsetPanel,offsetElement,point,applyMesh,get active(){return settings.enabled&&settings.distance>0&&panels.length>0;},get center(){return center.slice();}};
 }
 return{normalize,create};
});
