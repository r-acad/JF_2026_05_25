/* Root applied-load envelopes. Plot axes are distinct from the physical axes. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPotatoPlots=api;})(globalThis,function(){
 'use strict';
 const SPECS=[
  {key:'bending-torque',x:'torque',y:'bending',title:'Bending moment versus torque',xlabel:'Torque M_y (N m)',ylabel:'Bending M_x (N m)'},
  {key:'shear-bending',x:'bending',y:'shear',title:'Shear force versus bending moment',xlabel:'Bending M_x (N m)',ylabel:'Shear V_z (N)'},
  {key:'shear-torque',x:'torque',y:'shear',title:'Shear force versus torque',xlabel:'Torque M_y (N m)',ylabel:'Shear V_z (N)'}
 ];
 const format=n=>Number(n.toPrecision(5)).toString();
 function rootPoint(c){
  const s=c?.loads?.spanwise,force=s?.applied_force_N,moment=s?.root_moment_Nm_about_reference;
  if(!force||!moment||![force[2],moment[0],moment[1]].every(Number.isFinite))return null;
  return{id:Number(c.id),name:c.label||'Load case '+c.id,shear:force[2],bending:moment[0],torque:moment[1]};
 }
 const color=id=>`hsl(${((Number(id)*137.508)%360+360)%360} 72% 65%)`;
 function validateState(value){
  if(value==null)return{selected:null,labels:'none'};
  if(typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['selected','labels'].includes(k))||!['none','names','values'].includes(value.labels)||value.selected!==null&&(!Array.isArray(value.selected)||value.selected.some(id=>!Number.isSafeInteger(id)||id<1)||new Set(value.selected).size!==value.selected.length))throw Error('Invalid Potato plot settings.');
  return{selected:value.selected===null?null:[...value.selected],labels:value.labels};
 }
 function range(values){let min=Math.min(0,...values),max=Math.max(0,...values);const pad=(max-min||1)*.12;return[min-pad,max+pad];}
 function create(host,onChange=()=>{}){
  const doc=host.ownerDocument,NS='http://www.w3.org/2000/svg';let cases=[],stale=false,state=validateState(null);
  const el=(tag,cls,text)=>{const n=doc.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
  const svgEl=(tag,attrs,text)=>{const n=doc.createElementNS(NS,tag);for(const[k,v]of Object.entries(attrs||{}))n.setAttribute(k,v);if(text!==undefined)n.textContent=text;return n;};
  function chart(points,spec){
   const card=el('section','potato-chart'),heading=el('h3','',spec.title),svg=svgEl('svg',{viewBox:'0 0 720 420',role:'img','aria-label':spec.title});
   const[xmin,xmax]=range(points.map(p=>p[spec.x])),[ymin,ymax]=range(points.map(p=>p[spec.y])),left=88,top=28,width=598,height=320;
   const x=n=>left+(n-xmin)/(xmax-xmin)*width,y=n=>top+height-(n-ymin)/(ymax-ymin)*height;
   svg.append(svgEl('rect',{x:left,y:top,width,height,class:'potato-frame'}));
   for(let i=0;i<=5;i++){
    const a=xmin+i*(xmax-xmin)/5,b=ymin+i*(ymax-ymin)/5;
    svg.append(svgEl('line',{x1:x(a),x2:x(a),y1:top,y2:top+height,class:'potato-grid'}),svgEl('text',{x:x(a),y:top+height+20,'text-anchor':'middle',class:'potato-tick'},format(a)));
    svg.append(svgEl('line',{x1:left,x2:left+width,y1:y(b),y2:y(b),class:'potato-grid'}),svgEl('text',{x:left-10,y:y(b)+4,'text-anchor':'end',class:'potato-tick'},format(b)));
   }
   svg.append(svgEl('line',{x1:x(0),x2:x(0),y1:top,y2:top+height,class:'potato-zero'}),svgEl('line',{x1:left,x2:left+width,y1:y(0),y2:y(0),class:'potato-zero'}));
   svg.append(svgEl('text',{x:left+width/2,y:405,'text-anchor':'middle',class:'potato-axis'},spec.xlabel),svgEl('text',{x:18,y:top+height/2,transform:`rotate(-90 18 ${top+height/2})`,'text-anchor':'middle',class:'potato-axis'},spec.ylabel));
   for(const p of points){
    const dot=svgEl('circle',{cx:x(p[spec.x]),cy:y(p[spec.y]),r:6,fill:color(p.id),'data-case-id':p.id,'data-x-value':p[spec.x],'data-y-value':p[spec.y],tabindex:0});
    const description=`${p.name}: ${spec.xlabel} = ${format(p[spec.x])}, ${spec.ylabel} = ${format(p[spec.y])}`;dot.setAttribute('aria-label',description);dot.append(svgEl('title',{},description));svg.append(dot);
    if(state.labels!=='none'){const right=x(p[spec.x])>left+width*.6;svg.append(svgEl('text',{x:x(p[spec.x])+(right?-9:9),y:y(p[spec.y])+(y(p[spec.y])<top+30?19:-9),'text-anchor':right?'end':'start',fill:color(p.id),class:'potato-point-label'},state.labels==='names'?p.name:`(${format(p[spec.x])}, ${format(p[spec.y])})`));}
   }
   card.dataset.chart=spec.key;card.append(heading,svg);return card;
  }
  function render(){
   host.replaceChildren();const points=cases.map(rootPoint).filter(Boolean),selected=state.selected===null?new Set(cases.map(c=>Number(c.id))):new Set(state.selected);
   const toolbar=el('div','potato-toolbar'),label=el('label','','Point labels '),select=el('select');select.id='potato-labels';
   for(const[value,text]of[['none','None'],['names','Case names'],['values','Actual values']]){const option=el('option','',text);option.value=value;select.append(option);}select.value=state.labels;select.onchange=()=>{state.labels=select.value;render();onChange();};label.append(select);toolbar.append(label);
   for(const[text,value]of[['Select all',null],['Clear selection',[]]]){const button=el('button','mini',text);button.onclick=()=>{state.selected=value;render();onChange();};toolbar.append(button);}host.append(toolbar);
   const legend=el('fieldset','potato-legend'),title=el('legend','','Load cases / legend');legend.append(title);
   for(const c of cases){const row=el('label','potato-case'),check=el('input'),swatch=el('i');check.type='checkbox';check.checked=selected.has(Number(c.id));check.dataset.caseId=c.id;check.disabled=!rootPoint(c);check.onchange=()=>{if(check.checked)selected.add(Number(c.id));else selected.delete(Number(c.id));state.selected=[...selected];render();onChange();};swatch.style.background=color(c.id);row.append(check,swatch,doc.createTextNode((c.label||'Load case '+c.id)+(rootPoint(c)?'':' — root loads unavailable')));legend.append(row);}host.append(legend);
   const message=el('p',stale?'plot-status stale':'pick-note',stale?'Parameters changed — points use the last generated loads. Create FEM to synchronize.':'Root applied loads, including aerodynamic, structure, fuel and engine contributions. Positive physical axes: shear Z, bending X, torque Y; moments use the same root reference as Load plots.');message.setAttribute('role','status');host.append(message);
   const shown=points.filter(p=>selected.has(p.id));
   if(!shown.length)host.append(el('p','pick-note',cases.length?'Select at least one case with generated root loads.':'Create FEM to generate the load-case points.'));
   const charts=el('div','potato-charts');for(const spec of SPECS)charts.append(chart(shown,spec));host.append(charts);
  }
  render();return{update(next,dirty){cases=next||[];stale=!!dirty;render();},capture:()=>validateState(state),restore(value){state=validateState(value);render();},dispose(){host.replaceChildren();}};
 }
 return{SPECS,rootPoint,color,range,validateState,create};
});
