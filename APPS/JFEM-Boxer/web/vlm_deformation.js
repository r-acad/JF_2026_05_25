/* Display-only VLM attachment to the same rib reference stations that receive
 * the aerodynamic loads. No geometry, pressure or solver input is modified. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingVlmDeformation=api;})(globalThis,function(){
 'use strict';
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 function rotate(vector,theta,linear=false){
  const turn=cross(theta,vector);if(linear)return vector.map((v,i)=>v+turn[i]);
  const a2=theta.reduce((s,v)=>s+v*v,0),a=Math.sqrt(a2),s=a2<1e-10?1-a2/6+a2*a2/120:Math.sin(a)/a,c=a2<1e-10?.5-a2/24+a2*a2/720:(1-Math.cos(a))/a2,second=cross(theta,turn);
  return vector.map((v,i)=>v+s*turn[i]+c*second[i]);
 }
 const xyzToView=p=>[p[1],p[2],p[0]],viewToXyz=p=>[p[2],p[0],p[1]];
 function attach(points,stations,baseline,{etas=null}={}){
  const useEta=etas&&etas.length===points.length/3&&etas.every(Number.isFinite)&&(stations||[]).every(s=>Number.isFinite(s.eta));
  const anchors=(stations||[]).filter(s=>Number.isInteger(s.node_index)&&s.node_index>=0&&3*s.node_index+2<baseline.length)
   .map(s=>({node:s.node_index,gid:s.gid,y:useEta?s.eta:baseline[3*s.node_index]})).sort((a,b)=>a.y-b.y);
  return Array.from({length:points.length/3},(_,i)=>{
   const p=Array.from(points.slice(3*i,3*i+3));if(!anchors.length)return{p,anchors:[]};
   const coordinate=useEta?etas[i]:p[0];
   let lo=0,hi=anchors.length-1;while(hi-lo>1){const mid=(lo+hi)>>1;if(anchors[mid].y<=coordinate)lo=mid;else hi=mid;}
   const width=anchors[hi].y-anchors[lo].y,t=width>1e-12?Math.max(0,Math.min(1,(coordinate-anchors[lo].y)/width)):0;
   return{p,anchors:[[anchors[lo],1-t],[anchors[hi],t]].filter(([,w])=>w>0).map(([a,w])=>({...a,w,
    lever:p.map((v,k)=>v-baseline[3*a.node+k])}))};
  });
 }
 function point(binding,baseline,positions,rotations,rotationScale=1,linear=true){
  const result=binding.p.slice();
  for(const a of binding.anchors){
   const theta=rotations?xyzToView(Array.from(rotations.slice(3*a.node,3*a.node+3))).map(v=>v*rotationScale):[0,0,0],lever=rotate(a.lever,theta,linear);
   for(let k=0;k<3;k++)result[k]+=a.w*(positions[3*a.node+k]-baseline[3*a.node+k]+lever[k]-a.lever[k]);
  }
  return result;
 }
 /** Interpolate rotated panel vectors, not an averaged rotation: this matches
  * the station weights used by the prescribed VLM-to-RBE3 transfer. */
 function force(vector,binding,{scale=1,followers=null,linear=false}={}){
  if(!followers||!binding.anchors.length)return vector.map(v=>v*scale);
  const result=[0,0,0];for(const a of binding.anchors){const theta=followers.get(Number(a.gid))||[0,0,0],f=rotate(vector,theta,linear);for(let k=0;k<3;k++)result[k]+=a.w*f[k]*scale;}
  return result;
 }
 return{rotate,attach,point,force,xyzToView,viewToXyz};
});
