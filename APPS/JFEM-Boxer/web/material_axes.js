/* Shell material directions, distinct from geometric element frames. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMaterialAxes=api;})(globalThis,function(){
  'use strict';
  const dot=(a,b)=>a.reduce((v,x,i)=>v+x*b[i],0),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
  function projected(a,z){const d=dot(a,z),v=a.map((x,i)=>x-d*z[i]),n=Math.hypot(...v);return n>1e-12?v.map(x=>x/n):null;}
  function frame({x,y,z,edge,coordinate,theta=0}){
    const base=coordinate?(projected(coordinate.x,z)||projected(coordinate.y,z)):projected(edge,z)||x;
    if(!base)return null;
    const t=coordinate?0:theta*Math.PI/180,side=cross(z,base),mx=base.map((v,i)=>v*Math.cos(t)+side[i]*Math.sin(t));
    return {x:mx,y:cross(z,mx),z};
  }
  function axes(state,g,helpers){
    if(!['quad','tria'].includes(g.kind)||!g.axes)return null;
    const {asF32,asI32,groupIds}=helpers,ids=groupIds(g);
    if(!state.data?.imported_deck)return {...g.axes,labels:Array.from(ids,id=>'E '+id+' · MCID '+id)};
    if(!g.material_orientation)return null; // Old imported payloads cannot establish THETA/MCID reliably.
    const cids=asI32(g.material_orientation.mcid),specified=g.material_orientation.mcid_specified?asI32(g.material_orientation.mcid_specified):null,angles=asF32(g.material_orientation.theta),conn=asI32(g.conn),xyz=asF32(state.data.nodes.xyz),stride=g.n_per_elem||(g.kind==='quad'?4:3);
    const source=Object.fromEntries(['x','y','z'].map(k=>[k,asF32(g.axes[k])])),out={...g.axes,x:new Float32Array(g.count*3),y:new Float32Array(g.count*3),z:source.z,labels:[]};
    const systems=helpers.coordinateSystems||new Map((state.data.coordinate_systems?.systems||[]).map(c=>[c.id,c]));
    for(let i=0;i<g.count;i++){
      const usesCoordinate=cids[i]>0||cids[i]===0&&specified?.[i]===1;
      const coordinate=usesCoordinate?(cids[i]===0?{x:[1,0,0],y:[0,1,0]}:systems.get(cids[i])):null,a=conn[i*stride]*3,b=conn[i*stride+1]*3;
      out.labels.push('E '+ids[i]+' · '+(usesCoordinate?'MCID '+cids[i]+(cids[i]===0?' · BASIC':''):'θ '+Number(angles[i].toPrecision(5))+'° · element G1–G2'));
      if(usesCoordinate&&!coordinate)continue;
      const f=frame({x:Array.from(source.x.slice(i*3,i*3+3)),y:Array.from(source.y.slice(i*3,i*3+3)),z:Array.from(source.z.slice(i*3,i*3+3)),edge:[0,1,2].map(j=>xyz[b+j]-xyz[a+j]),coordinate,theta:angles[i]});
      if(f){out.x.set(f.x,i*3);out.y.set(f.y,i*3);}
    }
    return out;
  }
  return {frame,axes};
});
