/* Signed global-axis load components. Coordinates are FE XYZ, in metres. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLoadGlyphs=api;})(globalThis,function(){
 'use strict';
 const AXES=['X','Y','Z'],COLORS=['#ef5f6b','#4cc38a','#56a8f5'];
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
 return{AXES,COLORS,components};
});
