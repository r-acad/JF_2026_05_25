/* Signed global-axis load components. Coordinates are FE XYZ, in metres. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLoadGlyphs=api;})(globalThis,function(){
 'use strict';
 const AXES=['X','Y','Z'],COLORS=['#ef5f6b','#4cc38a','#56a8f5'],VLM_COLOR='#e45ad4';
 const add=(a,b)=>a.map((v,i)=>v+b[i]),mul=(a,s)=>a.map(v=>v*s);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const unit=a=>mul(a,1/Math.hypot(...a));
 const basis=axis=>{const n=[0,0,0];n[axis]=1;const u=unit(cross(n,axis===2?[0,1,0]:[0,0,1]));return[n,u,cross(n,u)];};
 function components(vector,{kind='force',scale=1,diag=1,peak=1,multiplier=1}={}){
  if(!['force','moment'].includes(kind))throw Error('Load glyph kind must be force or moment.');
  if(!Number.isFinite(diag)||diag<=0||!Number.isFinite(scale)||scale<0||!Number.isFinite(multiplier)||multiplier<=0)throw Error('Load glyph dimensions must be finite and positive.');
  const result=[];
  for(let axis=0;axis<3;axis++){
   const value=Number(vector?.[axis]||0);if(!Number.isFinite(value)||value===0)continue;
   const[n,u,v]=basis(axis),sign=Math.sign(value),vertices=[];let radius;
   if(kind==='force'){
    const length=Math.abs(value)*scale;if(!(length>0))continue;
    const tip=mul(n,value*scale),direction=mul(n,sign),side=mul(u,sign),head=Math.min(length*.25,diag*.014),back=add(tip,mul(direction,-head));
    vertices.push([0,0,0],tip,tip,add(back,mul(side,head*.45)),tip,add(back,mul(side,-head*.45)));
   }else{
    if(!(Number.isFinite(peak)&&peak>0))continue;
    radius=diag*(.008+.022*Math.abs(value)/peak)*multiplier;
    const sweep=sign*Math.PI*1.55,point=t=>add(mul(u,radius*Math.cos(t)),mul(v,radius*Math.sin(t)));
    for(let i=0;i<24;i++)vertices.push(point(sweep*i/24),point(sweep*(i+1)/24));
    const tip=point(sweep),tangent=add(mul(u,-Math.sin(sweep)*sign),mul(v,Math.cos(sweep)*sign)),head=radius*.32,back=add(tip,mul(tangent,-head));
    vertices.push(tip,add(back,mul(unit(tip),head*.5)),tip,add(back,mul(unit(tip),-head*.5)));
   }
   result.push({axis:AXES[axis],component:axis,color:COLORS[axis],kind,value,unit:kind==='force'?'N':'N m',vector:n.map(c=>c*value),scale:kind==='force'?scale:undefined,radius,vertices});
  }
  return result;
 }
 function vectorArrow(vector,{scale=1,diag=1}={}){
  const magnitude=Math.hypot(...vector),length=magnitude*scale;if(!(Number.isFinite(length)&&length>0))return[];
  const direction=mul(vector,1/magnitude),side=unit(cross(direction,Math.abs(direction[2])<.9?[0,0,1]:[0,1,0]));
  const tip=mul(vector,scale),head=Math.min(length*.25,diag*.014),back=add(tip,mul(direction,-head));
  return[[0,0,0],tip,tip,add(back,mul(side,head*.45)),tip,add(back,mul(side,-head*.45))];
 }
 const decoded=(value,Type)=>value==null?null:value instanceof Type||Type===Float32Array&&value instanceof Float64Array?value:Array.isArray(value)?value:new Type(value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength));
 /** The backend normal is the normalized sum of the two diagonal triangle
  * area vectors. Pressure = dot(full resultant, normal) / physical area.
  * Preserve that signed normal force; never turn induced drag into pressure.
  */
 function panelNormalForces(vlm){
  const records=[],invalid=[];if(!vlm)return{records,invalid,peak:0};
  const xyz=decoded(vlm.xyz,Float32Array),conn=decoded(vlm.conn,Int32Array),forces=decoded(vlm.forces,Float32Array),centers=decoded(vlm.centers,Float32Array),pressure=decoded(vlm.pressure,Float32Array),area=decoded(vlm.area,Float32Array);
  let peak=0;
  for(let e=0;e<vlm.count;e++){
   const ids=Array.from(conn?.subarray?.(4*e,4*e+4)||conn?.slice(4*e,4*e+4)||[]),corners=ids.map(id=>Array.from(xyz?.subarray?.(3*id,3*id+3)||xyz?.slice(3*id,3*id+3)||[]));
   if(ids.length!==4||ids.some(id=>!Number.isInteger(id)||id<0)||corners.some(p=>p.length!==3||!p.every(Number.isFinite))){invalid.push(e+1);continue;}
   const edges=corners.slice(1).map(p=>p.map((v,k)=>v-corners[0][k])),size=Math.max(...edges.flat().map(Math.abs));
   if(!(size>0)){invalid.push(e+1);continue;}
   const[b,c,d]=edges.map(v=>mul(v,1/size)),na=cross(b,c),nb=cross(c,d),sum=add(na,nb),length=Math.hypot(...sum),areaSum=Math.hypot(...na)+Math.hypot(...nb);
   if(!(length>1e-10*areaSum)){invalid.push(e+1);continue;}
   const normal=mul(sum,1/length),resultant=Array.from(forces?.subarray?.(3*e,3*e+3)||forces?.slice(3*e,3*e+3)||[]),nativePressure=Number(pressure?.[e]),nativeArea=Number(area?.[e]);
   const usePressure=Number.isFinite(nativePressure)&&Number.isFinite(nativeArea)&&nativeArea>0;
   const value=usePressure?nativePressure*nativeArea:resultant.length===3&&resultant.every(Number.isFinite)?resultant.reduce((s,v,k)=>s+v*normal[k],0):NaN;
   if(!Number.isFinite(value)){invalid.push(e+1);continue;}
   let center=Array.from(centers?.subarray?.(3*e,3*e+3)||centers?.slice(3*e,3*e+3)||[]);
   if(center.length!==3||!center.every(Number.isFinite))center=[0,1,2].map(k=>corners.reduce((sum,p)=>sum+p[k]/4,0));
   peak=Math.max(peak,Math.abs(value));records.push({panel_id:e+1,position:center,normal,normal_force_N:value,force:mul(normal,value),resultant_force_N:resultant,pressure_Pa:Number.isFinite(nativePressure)?nativePressure:undefined,area_m2:Number.isFinite(nativeArea)&&nativeArea>0?nativeArea:areaSum*size*size/2,basis:usePressure?'pressure times area':'normal projection of full panel resultant'});
  }
  return{records,invalid,peak};
 }
 return{AXES,COLORS,VLM_COLOR,components,vectorArrow,panelNormalForces};
});
