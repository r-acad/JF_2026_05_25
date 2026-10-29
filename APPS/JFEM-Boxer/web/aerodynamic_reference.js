/* Physical BASIC reference geometry, projected into the independent 3D view. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAerodynamicReference=api;})(globalThis,function(root){
 'use strict';
 const NS='http://www.w3.org/2000/svg',rad=d=>d*Math.PI/180;
 const plus=(o,v,r=1)=>o.map((x,i)=>x+r*v[i]);
 function geometry(condition,origin,radius,frame='body'){
  const alpha=rad(condition.alpha||0),beta=rad(condition.beta||0),projection=[Math.cos(alpha),0,Math.sin(alpha)],velocity=[projection[0]*Math.cos(beta),-Math.sin(beta),projection[2]*Math.cos(beta)];
  const a0=rad(condition.stability_alpha||0),a=frame==='stability'?a0:alpha;
  const rows=frame==='construction'?[[1,0,0],[0,1,0],[0,0,1]]:frame==='body'?[[-1,0,0],[0,1,0],[0,0,-1]]:frame==='wind'?[[-Math.cos(alpha)*Math.cos(beta),Math.sin(beta),-Math.sin(alpha)*Math.cos(beta)],[Math.cos(alpha)*Math.sin(beta),Math.cos(beta),Math.sin(alpha)*Math.sin(beta)],[Math.sin(alpha),0,-Math.cos(alpha)]]:[[-Math.cos(a),0,-Math.sin(a)],[0,1,0],[Math.sin(a),0,-Math.cos(a)]];
  const glyphOrigin=plus(origin,velocity,-radius*3.8);
  const curve=(angle,basis,side,r)=>{const count=2*Math.max(1,Math.ceil(Math.abs(angle)*180/Math.PI/4))+1;return Array.from({length:count},(_,i)=>plus(glyphOrigin,basis.map((v,k)=>v*Math.cos(angle*i/(count-1))+side[k]*Math.sin(angle*i/(count-1))),r));};
  return{origin:origin.slice(),glyphOrigin,velocity,projection,
   frame,axes:rows.map(v=>[origin.slice(),plus(origin,v,radius*1.65)]),
   flow:[glyphOrigin.slice(),origin.slice()],
   alpha:{value:condition.alpha||0,points:curve(alpha,[1,0,0],[0,0,1],radius),rays:[[glyphOrigin.slice(),plus(glyphOrigin,[1,0,0],radius*1.12)],[glyphOrigin.slice(),plus(glyphOrigin,projection,radius*1.12)]],label:plus(glyphOrigin,[Math.cos(alpha/2),0,Math.sin(alpha/2)],radius)},
   beta:{value:condition.beta||0,points:curve(beta,projection,[0,-1,0],radius*1.35),rays:[[glyphOrigin.slice(),plus(glyphOrigin,projection,radius*1.48)],[glyphOrigin.slice(),plus(glyphOrigin,velocity,radius*1.48)]],label:plus(glyphOrigin,[projection[0]*Math.cos(beta/2),-Math.sin(beta/2),projection[2]*Math.cos(beta/2)],radius*1.35)}};
 }
 const FRAMES=['body','construction','aerodynamic','wind','stability'],SUFFIX={body:'B',construction:'C',aerodynamic:'A',wind:"W'",stability:'S'};
 function axisGeometry(condition,origin,radius,flags={}){
  return FRAMES.flatMap((frame,f)=>{const g=geometry(condition,origin,radius,frame),scale=[1, .85,1.18,1.36,1.55][f];return g.axes.flatMap((points,i)=>flags.axisVisibility?.[frame]?.[i]===false?[]:[{frame,axis:['X','Y','Z'][i],name:['X','Y','Z'][i]+'_'+SUFFIX[frame],points:[points[0],plus(origin,points[1].map((x,k)=>x-origin[k]),scale)],highlight:frame===(flags.axisFrame||'body')}]);});
 }
 let nextId=0;
 function install(svg,{scene:readScene,condition:readCase,flags:readFlags,background:readBackground=()=>'#091b29'}){
  const doc=svg.ownerDocument,prefix='aero-reference-'+(++nextId),add=(tag,parent=svg,attrs={},text)=>{const n=doc.createElementNS(NS,tag);for(const[k,v]of Object.entries(attrs))n.setAttribute(k,v);if(text!==undefined)n.textContent=text;parent.append(n);return n;};
  let key='',projectionKey='',items=[];
  function clear(){key='';projectionKey='';items=[];svg.replaceChildren();svg.style.display='none';}
  function build(c,flags){
   svg.replaceChildren();items=[];const light=[1,3,5].reduce((n,i)=>n+parseInt(readBackground().slice(i,i+2),16),0)>460,flowColor=light?'#173a58':'#e7f5ff',alphaColor=light?'#9b5600':'#ffd078',betaColor=light?'#8136aa':'#e3aaff';const origin=c.reference||[0,0,0],g=geometry(c.condition||{},origin,Math.max(c.span_m*.1,c.mac_m*.35),flags.axisFrame||'body'),defs=add('defs');
   const marker=(name,color)=>{const id=prefix+'-'+name,m=add('marker',defs,{id,viewBox:'0 0 8 8',refX:7,refY:4,markerWidth:6,markerHeight:6,markerUnits:'userSpaceOnUse',orient:'auto-start-reverse'});add('path',m,{d:'M0 0 8 4 0 8Z',fill:color});return'url(#'+id+')';};
   const path=(points,color,{arrow=false,dimension=false,dashed=false,axis=null}={})=>{const attrs={fill:'none',stroke:color,'stroke-width':dimension?2:1.7};if(arrow||dimension){const ref=marker('arrow-'+items.length,color);attrs['marker-end']=ref;if(dimension)attrs['marker-start']=ref;}if(axis){attrs['data-frame']=axis.frame;attrs['data-axis']=axis.axis;attrs['data-world-from']=JSON.stringify(points[0]);attrs['data-world-to']=JSON.stringify(points[1]);attrs['stroke-width']=axis.highlight?3:1.6;}if(dashed)attrs['stroke-dasharray']='4 4';const node=add('path',svg,attrs);items.push({node,points});};
   const label=(point,text,color,dy=0,angleName=null)=>{const leader=add('path',svg,{stroke:color,'stroke-width':.8,fill:'none'}),node=add('text',svg,{fill:color,'text-anchor':'middle','font-size':12,'font-weight':600,stroke:readBackground(),'stroke-width':3,'paint-order':'stroke'},text);if(angleName){leader.setAttribute('data-angle-leader',angleName);leader.setAttribute('data-world-anchor',JSON.stringify(point));node.setAttribute('data-angle-label',angleName);}items.push({node,points:[point],dy,leader,angleName});};
   if(flags.flowAngles)for(const name of ['alpha','beta']){const dim=g[name];if(Math.abs(dim.value)>1e-9){const sector=add('path',svg,{fill:name==='alpha'?alphaColor:betaColor,'fill-opacity':.2,stroke:'none','data-angle-sector':name});items.push({node:sector,points:[g.glyphOrigin,...dim.points,g.glyphOrigin]});}}
   if(flags.referenceAxes){for(const axis of axisGeometry(c.condition||{},origin,Math.max(c.span_m*.1,c.mac_m*.35),flags)){const i=['X','Y','Z'].indexOf(axis.axis),color=(light?['#b53724','#1f7941','#2759a5']:['#ff8c80','#82e09e','#84bfff'])[i];path(axis.points,color,{arrow:true,axis,dashed:axis.frame==='construction'||axis.frame==='stability'});label(axis.points[1],axis.name,color,-8);}
    for(const [side,text,color]of [['right','Right wing (+Y_B)',light?'#17633a':'#91e9b2'],['left','Left wing (-Y_B)',light?'#155174':'#9fd4ef']]){const ps=(c.panels||[]).filter(p=>p.side===side);if(!ps.length)continue;const tip=ps.reduce((a,p)=>p.eta>a.eta?p:a,ps[0]);label(tip.position,text,color,18);}
   }
   if(flags.flowAngles){label(g.alpha.rays[0][1],'-X_B',alphaColor,-8);path(g.flow,flowColor,{arrow:true});label(plus(g.glyphOrigin,g.velocity,Math.max(c.span_m*.1,c.mac_m*.35)*2),(g.beta.value>1e-9?'-V: wind from right':g.beta.value< -1e-9?'-V: wind from left':'-V (relative wind)'),flowColor,-8);for(const[name,color,dy]of[['alpha',alphaColor,18],['beta',betaColor,-14]]){const dim=g[name];dim.rays.forEach(points=>path(points,color,{dashed:true}));if(Math.abs(dim.value)>1e-9)path(dim.points,color,{dimension:true});label(dim.label,(name==='alpha'?'\u03b1':'\u03b2')+' = '+Number(dim.value.toPrecision(5))+'\u00b0',color,dy,name);}}
   svg.setAttribute('aria-label',(flags.axisFrame||'body')+' reference axes and freestream angles: alpha '+g.alpha.value+' degrees, beta '+g.beta.value+' degrees');
  }
  function render(){
   const scene=readScene(),c=readCase(),flags=readFlags();if(!scene||!c||!flags.referenceAxes&&!flags.flowAngles){if(key)clear();return;}
   const fresh=JSON.stringify([c.reference,c.span_m,c.mac_m,c.condition?.alpha,c.condition?.beta,flags.referenceAxes,flags.axisFrame,flags.axisVisibility,flags.flowAngles,c.condition?.stability_alpha,readBackground()]);if(key!==fresh){build(c,flags);key=fresh;projectionKey='';}
   const B=root.BABYLON,engine=scene.getEngine(),canvas=engine.getRenderingCanvas(),width=canvas.clientWidth,height=canvas.clientHeight,viewport=scene.activeCamera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight());// A static camera/condition needs no SVG mutations on subsequent frames.
   const projected=JSON.stringify([fresh,width,height,viewport.x,viewport.y,viewport.width,viewport.height,...scene.getTransformMatrix().m]);if(projected===projectionKey)return;projectionKey=projected;svg.style.display='block';svg.setAttribute('viewBox','0 0 '+width+' '+height);
   const occupied=[];
   for(const item of items){const points=item.points.map(p=>B.Vector3.Project(new B.Vector3(p[1],p[2],p[0]),B.Matrix.IdentityReadOnly,scene.getTransformMatrix(),viewport));if(points.some(p=>!Number.isFinite(p.x+p.y+p.z)||p.z<0||p.z>1)){item.node.setAttribute('visibility','hidden');item.leader?.setAttribute('visibility','hidden');continue;}item.node.removeAttribute('visibility');const xy=points.map(p=>[p.x/engine.getRenderWidth()*width,p.y/engine.getRenderHeight()*height]);if(item.node.tagName==='text'){
     const size=item.node.textContent.length*7+6,base=[xy[0][0],xy[0][1]+item.dy],candidates=[[0,0],[28,0],[-28,0],[0,-20],[0,20],[52,-18],[-52,18],[74,0],[-74,0]],rect=(x,y)=>({left:x-size/2,right:x+size/2,top:y-13,bottom:y+5});
     const offset=candidates.find(([dx,dy])=>{const r=rect(base[0]+dx,base[1]+dy);return r.left>=3&&r.right<=width-3&&r.top>=3&&r.bottom<=height-3&&!occupied.some(b=>r.left<b.right+3&&r.right>b.left-3&&r.top<b.bottom+3&&r.bottom>b.top-3);})||[0,0],x=base[0]+offset[0],y=base[1]+offset[1];occupied.push(rect(x,y));item.node.setAttribute('x',x);item.node.setAttribute('y',y);item.leader.removeAttribute('visibility');const leaderEnd=[x,y-4],dx=xy[0][0]-x,dy=xy[0][1]-(y-4);if(item.angleName){const half=Math.max(1,(size-8)/2),t=Math.min(1,half/Math.max(Math.abs(dx),1),8/Math.max(Math.abs(dy),1));leaderEnd[0]+=dx*t;leaderEnd[1]+=dy*t;}item.leader.setAttribute('d',item.angleName||offset.some(Boolean)?'M'+xy[0].join(' ')+'L'+leaderEnd.join(' '):'');
    }else item.node.setAttribute('d',xy.map((p,i)=>(i?'L':'M')+p.join(' ')).join(' '));}
  }
  clear();return{render,clear};
 }
 return{geometry,axisGeometry,install};
});
