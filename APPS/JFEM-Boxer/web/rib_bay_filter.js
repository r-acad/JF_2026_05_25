/* Whole-element display selection between the actual generated rib planes.
 * Coordinates and connectivity are read-only; results keep their original IDs. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRibBayFilter=api;})(globalThis,function(){
 'use strict';
 const sub=(a,b)=>a.map((v,i)=>v-b[i]),dot=(a,b)=>a.reduce((v,x,i)=>v+x*b[i],0);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const triple=v=>Array.isArray(v)&&v.length===3&&v.every(Number.isFinite);
 function normalize(value){
  if(value==null)return{enabled:false,rib:1};
  if(typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['enabled','rib'].includes(k))||typeof value.enabled!=='boolean'||!Number.isSafeInteger(value.rib)||value.rib<1)throw Error('Invalid rib-bay display filter.');
  return{enabled:value.enabled,rib:value.rib};
 }
 function plane(rib,leading=false){
  const prefix=leading&&triple(rib.leading_edge_datum_origin)?'leading_edge_datum_':'datum_';
  const origin=rib[prefix+'origin'],u=rib[prefix+'u'],v=rib[prefix+'v'];
  if(!triple(origin)||!triple(u)||!triple(v))return null;
  const n=cross(u,v),length=Math.hypot(...n);return length>1e-12?{origin,normal:n.map(x=>x/length)}:null;
 }
 function bays(data){
  if(!data||data.imported_deck)return[];
  const ribs=(data.annotations?.ribs||[]).filter(r=>Number.isSafeInteger(r.index)&&plane(r)).sort((a,b)=>a.index-b.index),result=[];
  for(let i=0;i+1<ribs.length;i++)if(ribs[i+1].index===ribs[i].index+1)result.push({rib:ribs[i].index,next:ribs[i+1].index,first:ribs[i],last:ribs[i+1]});
  return result;
 }
 function boundaries(bay,leading){
  const a=plane(bay.first,leading),b=plane(bay.last,leading),delta=sub(b.origin,a.origin);
  if(dot(a.normal,delta)<0)a.normal=a.normal.map(x=>-x);
  if(dot(b.normal,delta)>0)b.normal=b.normal.map(x=>-x);
  return[a,b];
 }
 function intersects(points,planes,tolerance){
  if(!points.length)return false;
  const d=points.map(p=>planes.map(plane=>dot(sub(p,plane.origin),plane.normal)));
  // A complete rib (including its own stiffeners) belongs to both neighboring
  // bays. A skin touching a rib only at its edge belongs to its own bay.
  if([0,1].some(k=>d.every(row=>Math.abs(row[k])<=tolerance)))return true;
  if([0,1].some(k=>d.every(row=>row[k]<=tolerance)))return false;
  if(d.some(row=>row.every(v=>v>tolerance)))return true;
  // Test convex combinations of vertices. This includes members spanning the
  // whole bay even when neither end lies inside; no physical member is cut.
  for(let i=0;i<d.length;i++)for(let j=i+1;j<d.length;j++){
   let low=0,high=1;
   for(let k=0;k<2;k++){
    const start=d[i][k]-tolerance,change=d[j][k]-d[i][k];
    if(Math.abs(change)<1e-15){if(start<=0){high=-1;break;}}
    else if(change>0)low=Math.max(low,-start/change);else high=Math.min(high,-start/change);
   }
   if(high>low&&high>0&&low<1)return true;
  }
  return false;
 }
 function select(data,elements,positions,rib,diag=1){
  const bay=bays(data).find(row=>row.rib===rib);if(!bay)return null;
  const main=boundaries(bay,false),leading=boundaries(bay,true),tolerance=Math.max(diag*2e-7,1e-9),allowed=new Set(),nodes=new Set();
  const point=n=>[positions[3*n+2],positions[3*n],positions[3*n+1]];
  for(const [id,element]of elements){
   const name=element.group?.base_group||element.group?.name||'',planes=/^LE_/.test(name)?leading:main;
   if(intersects(Array.from(element.nodes,point),planes,tolerance)){allowed.add(id);for(const n of element.nodes)nodes.add(n);}
  }
  // Free GRID/constraint markers inside the bay also remain available.
  for(let n=0;n<positions.length/3;n++)if(main.every(p=>dot(sub(point(n),p.origin),p.normal)>=-tolerance))nodes.add(n);
  return{bay,allowed,nodes};
 }
 function create({state,document,onChange}){
  const enabled=document.getElementById('show-rib-bay-only'),selectControl=document.getElementById('rib-bay-select'),note=document.getElementById('rib-bay-note');
  let settings=normalize(),selection=null,lastData=null,lastPositions=null,lastCount=-1,combined=null,combinedBase=null;
  function refresh(force=false){
   if(!force&&lastData===state.data&&lastPositions===state.baseline&&lastCount===state.elements.size)return;
   lastData=state.data;lastPositions=state.baseline;lastCount=state.elements.size;combined=null;combinedBase=null;
   const options=bays(state.data);selectControl.replaceChildren();
   for(const row of options)selectControl.add(new Option('R '+row.rib+' to R '+row.next,String(row.rib)));
   if(state.data&&!options.some(row=>row.rib===settings.rib))settings={enabled:false,rib:options[0]?.rib||1};
   enabled.checked=settings.enabled;enabled.disabled=!options.length;selectControl.disabled=!options.length;selectControl.value=String(settings.rib);
   selection=settings.enabled&&state.baseline?select(state.data,state.elements,state.baseline,settings.rib,state.diag):null;
   note.textContent=!state.data?'Create FEM to select a physical rib bay.':!options.length?'This model has no generated physical rib-plane metadata. Rib-bay filtering is unavailable.':selection?selection.allowed.size+' elements in R '+selection.bay.rib+' to R '+selection.bay.next+'. Both bounding ribs and whole members crossing the bay are included.':'Choose a rib bay and enable the filter. Layer switches and result colors remain active.';
  }
  function changed(){settings={enabled:enabled.checked,rib:Number(selectControl.value)||1};refresh(true);onChange?.();}
  enabled.onchange=changed;selectControl.onchange=changed;
  document.getElementById('rib-bay-show-all').onclick=()=>{enabled.checked=false;changed();};
  return{refresh,capture:()=>({...settings}),restore(value){settings=normalize(value);refresh(true);},invalidate(){lastData=null;lastPositions=null;selection=null;combined=null;},
   get active(){return!!selection;},get nodes(){return selection?.nodes||null;},get allowed(){return selection?.allowed||null;},includesRib(index){return!selection||index===selection.bay.rib||index===selection.bay.next;},
   combine(ids){if(!selection)return ids;if(!ids)return selection.allowed;if(ids!==combinedBase||!combined){combinedBase=ids;combined=new Set([...ids].filter(id=>selection.allowed.has(id)));}return combined;}};
 }
 return{normalize,plane,bays,boundaries,intersects,select,create};
});
