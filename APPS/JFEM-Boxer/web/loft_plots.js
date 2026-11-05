(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLoftPlots=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const NS='http://www.w3.org/2000/svg',WIDTH=640,HEIGHT=220,PAD={left:66,right:20,top:22,bottom:40};
 const configurations={thickness:{scale:100,unit:'t/c (%)',color:'#56bbff',step:.01,min:1e-8,max:1},twist:{scale:1,unit:'Twist (deg)',color:'#ffb454',step:1,min:-44.999,max:44.999},vertical_shift:{scale:1,unit:'Shift (% semi-span)',color:'#77d79b',step:.1,min:-Infinity,max:Infinity}};
 function extent(values,kind){
  const finite=values.filter(Number.isFinite);if(!finite.length)return[0,1];
  let lo=Math.min(0,...finite),hi=Math.max(0,...finite),span=hi-lo;
  if(span<1e-10){span=kind==='thickness'?.1:1;lo=-span/2;hi=span/2;}
  const extra=span*.15;return kind==='thickness'?[0,Math.max(.01,hi+extra)]:[lo-extra,hi+extra];
 }
 function roundValue(value,kind,formatter){
  const c=configurations[kind],clamped=Math.max(c.min,Math.min(c.max,value));
  let rounded=Number(formatter?formatter(clamped):clamped.toExponential(3));
  if(!Number.isFinite(rounded))rounded=clamped;
  return Math.max(c.min,Math.min(c.max,rounded));
 }
 function constrainEta(value,{initial,lower=0,upper=1}={},formatter){
  // Exact root/tip anchors keep the physical end stations. Interior handles
  // cannot cross their neighbours or create coincident interpolation anchors.
  if(initial===0||initial===1)return initial;
  const bounded=Math.max(lower,Math.min(upper,value)),round=value=>Number(formatter?formatter(value):value.toPrecision(5));
  const rounded=round(bounded);
  if(Number.isFinite(rounded)&&rounded>=lower&&rounded<=upper)return rounded;
  const edge=rounded<lower?lower:upper,direction=rounded<lower?1:-1;
  let increment=Math.max(1e-14,Math.abs(edge)*1e-5);
  for(let i=0;i<12;i++,increment*=2){const candidate=round(edge+direction*increment);if(candidate>=lower&&candidate<=upper)return candidate;}
  // Very closely spaced loaded stations may have no newly rounded value in
  // their interval. Retain their original eta rather than collapse a segment.
  return initial;
 }
 function profileBlendThickness(a,b,weight,airfoils){
  const xs=[...new Set([...a.xu,...a.xl,...b.xu,...b.xl])];
  let maximum=0;for(const x of xs){const ta=airfoils.tableOrdinate(a.xu,a.zu,x)-airfoils.tableOrdinate(a.xl,a.zl,x),tb=airfoils.tableOrdinate(b.xu,b.zu,x)-airfoils.tableOrdinate(b.xl,b.zl,x);maximum=Math.max(maximum,(1-weight)*ta+weight*tb);}return maximum;
 }
 function inheritedThickness(doc,airfoils){
  if(!airfoils)return null;
  const input=key=>doc.getElementById('p-'+key),value=key=>input(key)?.value;
  const options={n:Number(value('airfoil.n_points')||121),closed:input('airfoil.closed_trailing_edge')?.checked!==false};
  const profile=row=>row.source==='naca'||!row.source?airfoils.nacaProfile(row.code||'0012',options):typeof row.profile==='string'?JSON.parse(row.profile):row.profile;
  try{
   const sections=[{eta:0,source:value('airfoil.root_source'),code:value('airfoil.root'),profile:value('airfoil.root_profile')},...JSON.parse(value('airfoil.stations')||'[]'),{eta:1,source:value('airfoil.tip_source'),code:value('airfoil.tip'),profile:value('airfoil.tip_profile')}].map(row=>({eta:Number(row.eta),profile:profile(row)})).sort((a,b)=>a.eta-b.eta);
   for(const row of sections)airfoils.profileMetrics(row.profile);
   const cosine=value('airfoil.interpolation')==='cosine';
   return eta=>{let i=sections.findIndex(row=>row.eta>=eta);if(i<=0)return airfoils.profileMetrics(sections[i<0?sections.length-1:0].profile).maxThickness.value;const a=sections[i-1],b=sections[i],t=(eta-a.eta)/(b.eta-a.eta),w=cosine?(1-Math.cos(Math.PI*t))/2:t;return profileBlendThickness(a.profile,b.profile,w,airfoils);};
  }catch(_){return null;}
 }
 function install(host,{kind,field,readSchedule,readMethod,evaluate,readFallback,onChange,isLocked=()=>false}={}){
  let WIDTH=640;
  const doc=host.ownerDocument,win=doc.defaultView,c=configurations[kind];if(!c)throw Error('Unknown loft plot kind');
  const wrapper=doc.createElement('div');wrapper.className='loft-distribution';
  const svg=doc.createElementNS(NS,'svg');svg.classList.add('loft-distribution-plot');svg.dataset.loftPlot=kind;svg.setAttribute('viewBox',`0 0 ${WIDTH} ${HEIGHT}`);svg.setAttribute('role','group');svg.setAttribute('aria-label',c.unit+' as a function of eta');
  const note=doc.createElement('p');note.className='pick-note loft-plot-note';wrapper.append(svg,note);host.append(wrapper);
  let destroyed=false,drag=null,domain=[0,1],rows=[],listeners=[],lastRender=null;
  const el=(name,attrs,text)=>{const node=doc.createElementNS(NS,name);for(const [key,value]of Object.entries(attrs||{}))node.setAttribute(key,String(value));if(text!==undefined)node.textContent=text;return node;};
  const listen=(target,event,fn,options)=>{target.addEventListener(event,fn,options);listeners.push(()=>target.removeEventListener(event,fn,options));};
  const x=eta=>PAD.left+eta*(WIDTH-PAD.left-PAD.right),y=value=>PAD.top+(domain[1]-value)/(domain[1]-domain[0])*(HEIGHT-PAD.top-PAD.bottom);
  const label=value=>Number(value.toPrecision(4)).toLocaleString('en-US',{maximumSignificantDigits:4});
  const point=event=>{const matrix=svg.getScreenCTM();if(matrix){const p=svg.createSVGPoint();p.x=event.clientX;p.y=event.clientY;return p.matrixTransform(matrix.inverse());}const box=svg.getBoundingClientRect();return{x:(event.clientX-box.left)*WIDTH/box.width,y:(event.clientY-box.top)*HEIGHT/box.height};};
  function refresh(){
   if(destroyed)return;
   WIDTH=Math.max(280,svg.clientWidth||WIDTH);const box=`0 0 ${WIDTH} ${HEIGHT}`;if(svg.getAttribute('viewBox')!==box)svg.setAttribute('viewBox',box);
   let schedule,fallback;
   try{schedule=readSchedule();fallback=schedule.length?null:readFallback?.();rows=schedule;}catch(error){svg.replaceChildren();lastRender=null;note.textContent='Correct the station inputs to display this distribution.';return;}
   const sample=eta=>schedule.length?evaluate(schedule,eta,{kind,method:readMethod()}):fallback?.(eta);
   const etas=[...new Set([...Array.from({length:129},(_,i)=>i/128),...rows.map(row=>row.eta)])].sort((a,b)=>a-b),samples=etas.map(eta=>({eta,value:sample(eta)}));
   if(samples.some(p=>!Number.isFinite(p.value))){svg.replaceChildren();lastRender=null;note.textContent='Select valid airfoil sections to display the inherited thickness distribution.';return;}
   if(!drag)domain=extent(samples.map(p=>p.value),kind);
   const signature=JSON.stringify([WIDTH,domain,rows,samples.map(p=>p.value),readMethod(),isLocked()]);if(signature===lastRender)return;
   const focused=svg.contains(doc.activeElement)?doc.activeElement.dataset?.loftHandle:null;svg.replaceChildren();
   svg.append(el('rect',{x:PAD.left,y:PAD.top,width:WIDTH-PAD.left-PAD.right,height:HEIGHT-PAD.top-PAD.bottom,fill:'#101e2b',stroke:'#4b657a'}));
   for(let i=0;i<=5;i++){const eta=i/5,xx=x(eta),v=domain[0]+(domain[1]-domain[0])*i/5,yy=y(v);svg.append(el('line',{x1:xx,y1:PAD.top,x2:xx,y2:HEIGHT-PAD.bottom,stroke:'#344c60','stroke-width':1}),el('text',{x:xx,y:HEIGHT-PAD.bottom+20,'text-anchor':'middle',fill:'#c4daed','font-size':13},label(eta)),el('line',{x1:PAD.left,y1:yy,x2:WIDTH-PAD.right,y2:yy,stroke:'#344c60','stroke-width':1}),el('text',{x:PAD.left-9,y:yy+4,'text-anchor':'end',fill:'#c4daed','font-size':12},label(v*c.scale)));}
   svg.append(el('text',{x:PAD.left,y:15,fill:'#dceaf5','font-size':13},c.unit),el('text',{x:(WIDTH+PAD.left-PAD.right)/2,y:HEIGHT-5,'text-anchor':'middle',fill:'#dceaf5','font-size':13},'Eta (fraction of semi-span)'));
   if(domain[0]<0&&domain[1]>0)svg.append(el('line',{x1:PAD.left,y1:y(0),x2:WIDTH-PAD.right,y2:y(0),stroke:'#91a8ba','stroke-dasharray':'4 3'}));
   svg.append(el('path',{d:samples.map((p,i)=>(i?'L':'M')+x(p.eta).toFixed(3)+' '+y(p.value).toFixed(3)).join(' '),fill:'none',stroke:c.color,'stroke-width':2.5,'vector-effect':'non-scaling-stroke','data-loft-curve':kind}));
   rows.forEach((row,index)=>{const handle=el('circle',{cx:x(row.eta),cy:y(row[field]),r:6.5,fill:c.color,stroke:'#0c1720','stroke-width':2,tabindex:isLocked()?-1:0,role:'slider','aria-label':c.unit+' at eta '+label(row.eta),'aria-valuenow':row[field],'aria-valuetext':'Eta '+label(row.eta)+'; '+label(row[field]*c.scale)+' '+c.unit,'aria-disabled':isLocked()?'true':'false','data-loft-handle':index});if(Number.isFinite(c.min))handle.setAttribute('aria-valuemin',c.min);if(Number.isFinite(c.max))handle.setAttribute('aria-valuemax',c.max);handle.append(el('title',{},`Eta ${label(row.eta)}: ${label(row[field]*c.scale)} ${c.unit}. Drag horizontally for eta and vertically for value. Root/tip eta anchors stay at 0/1. Escape cancels.`));svg.append(handle);});
   note.textContent=rows.length?`${readMethod()==='cosine'?'Cosine':'Linear'} interpolation. Drag in X for eta and Y for value. Root/tip eta anchors stay at 0/1; interior points stay between their neighbours. Left/right arrows change eta (Alt: fine); up/down change the value. Escape cancels a drag.`:'Inherited distribution. Add stations to edit its control points.';
   lastRender=signature;if(focused!==null&&focused!==undefined&&!drag&&!isLocked())svg.querySelector(`[data-loft-handle="${focused}"]`)?.focus({preventScroll:true});
  }
  function commit(cancel=false){if(!drag)return;const previous=drag;drag=null;onChange(previous.index,cancel?previous.initial:previous.value,{eta:cancel?previous.initialEta:previous.eta,commit:!cancel,cancel});if(svg.hasPointerCapture?.(previous.pointerId))svg.releasePointerCapture(previous.pointerId);refresh();}
  listen(svg,'pointerdown',event=>{const target=event.target.closest?.('[data-loft-handle]');if(event.button!==0||!target||isLocked()||drag)return;const index=Number(target.dataset.loftHandle),row=rows[index];drag={index,initial:row[field],value:row[field],initialEta:row.eta,eta:row.eta,lower:index?rows[index-1].eta+1e-8:0,upper:index<rows.length-1?rows[index+1].eta-1e-8:1,pointerId:event.pointerId,start:point(event),domain:domain.slice()};svg.setPointerCapture(event.pointerId);event.preventDefault();event.stopPropagation();});
  listen(svg,'pointermove',event=>{if(!drag||event.pointerId!==drag.pointerId)return;if(isLocked()){commit(true);return;}const p=point(event),value=drag.initial-(p.y-drag.start.y)/(HEIGHT-PAD.top-PAD.bottom)*(drag.domain[1]-drag.domain[0]);drag.value=roundValue(value,kind,win.WingNumericInputs?.format);drag.eta=constrainEta(drag.initialEta+(p.x-drag.start.x)/(WIDTH-PAD.left-PAD.right),{initial:drag.initialEta,lower:drag.lower,upper:drag.upper},win.WingNumericInputs?.format);onChange(drag.index,drag.value,{eta:drag.eta,commit:false});refresh();event.preventDefault();});
  listen(svg,'pointerup',event=>{if(drag&&event.pointerId===drag.pointerId){commit(isLocked());event.preventDefault();event.stopPropagation();}});
  listen(svg,'pointercancel',()=>commit(true));listen(svg,'lostpointercapture',()=>{if(drag)commit(true);});
  listen(win,'keydown',event=>{if(event.key==='Escape'&&drag){commit(true);event.preventDefault();}});
  listen(svg,'keydown',event=>{if(event.key==='Escape'&&drag){commit(true);event.preventDefault();return;}const target=event.target.closest?.('[data-loft-handle]');if(!target||isLocked()||!['ArrowUp','ArrowDown','ArrowRight','ArrowLeft'].includes(event.key))return;const index=Number(target.dataset.loftHandle),row=rows[index],horizontal=['ArrowLeft','ArrowRight'].includes(event.key),sign=['ArrowUp','ArrowRight'].includes(event.key)?1:-1;const eta=horizontal?constrainEta(row.eta+sign*(event.altKey?.01:.1),{initial:row.eta,lower:index?rows[index-1].eta+1e-8:0,upper:index<rows.length-1?rows[index+1].eta-1e-8:1},win.WingNumericInputs?.format):row.eta,value=horizontal?row[field]:roundValue(row[field]+sign*c.step,kind,win.WingNumericInputs?.format);if(eta!==row.eta||value!==row[field])onChange(index,value,{eta,commit:true});refresh();svg.querySelector(`[data-loft-handle="${index}"]`)?.focus();event.preventDefault();event.stopPropagation();});
  let lastWidth=0;const observer=win.ResizeObserver?new win.ResizeObserver(()=>{const width=wrapper.clientWidth;if(width>0&&Math.abs(width-lastWidth)>1){lastWidth=width;refresh();}}):null;observer?.observe(wrapper);
  refresh();return{refresh,isInteracting:()=>!!drag,destroy(){commit(true);destroyed=true;observer?.disconnect();for(const detach of listeners)detach();wrapper.remove();}};
 }
 return{install,extent,roundValue,constrainEta,inheritedThickness,profileBlendThickness};
});
