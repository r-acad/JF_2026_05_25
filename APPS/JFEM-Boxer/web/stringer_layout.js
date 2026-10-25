/* Stringer directions and their live structural plan view. */
(function(root,factory){const api=factory(root,typeof module==='object'&&module.exports?require('./spar_view.js'):root.WingSparView,typeof module==='object'&&module.exports?require('./planform_view.js'):root.WingPlanformView);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingStringerLayout=api;})(globalThis,function(root,Spar,Planform){
 'use strict';
 const PARAM_KEYS=[...new Set([...Spar.PARAM_KEYS,'box.stringer_pitch','mesh.stringer_runout_ratio','box.rib_pitch','ribs.masters','mesh.elements_between_ribs'])];
 const number=v=>root.WingNumbers?root.WingNumbers.format(v,5):Number(v.toPrecision(6)).toString();
 const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function ribAPI(){return root.WingRibLayout||(typeof require==='function'?require('./rib_layout.js'):null);}
 function segments(points){
  const ordered=points.map((p,index)=>({...p,index})).sort((a,b)=>a.eta-b.eta),rows=[];
  ordered.forEach((p,i)=>rows.push({index:p.index,start:i?ordered[i-1].eta:0,end:p.eta===0&&ordered.length===1?1:p.eta,angle:p.stringer_angle??0,unused:p.eta===0&&ordered.length>1}));
  if(ordered.length&&ordered.at(-1).eta>0&&ordered.at(-1).eta<1)rows.push({index:ordered.at(-1).index,start:ordered.at(-1).eta,end:1,angle:ordered.at(-1).stringer_angle??0,inherited:true});
  return rows;
 }
 function sampledIndices(count,limit){
  if(count<=limit)return Array.from({length:count},(_,i)=>i);
  if(limit<2)return[0];
  return Array.from({length:limit},(_,i)=>Math.round(i*(count-1)/(limit-1)));
 }
 function referencePaths(params,geometry,maxPaths){
  const pitch=params['box.stringer_pitch'],ratio=params['mesh.stringer_runout_ratio']??.75,tolerance=1e-10*Math.max(geometry.rootChord,pitch);
  if(!Number.isFinite(pitch)||pitch<=0)throw Error('Stringer pitch must be a positive number.');
  if(!Number.isFinite(ratio)||ratio<=0||ratio>1)throw Error('Run-out threshold must be greater than zero and no greater than one.');
  if(!geometry.stringerSegments.every(segment=>Number.isFinite(segment.absoluteAngle)&&Math.abs(segment.absoluteAngle)<89))throw Error(geometry.error||'Stringer directions must remain within 89 degrees of the span axis.');
  const count=Math.max(0,Math.floor(geometry.rootWidth/pitch+1e-10)-1);
  if(!Number.isSafeInteger(count))throw Error('Stringer count cannot be represented at this pitch.');
  const offset=eta=>{let value=0;for(const segment of geometry.stringerSegments){const end=Math.min(eta,segment.endEta);if(end>segment.startEta)value+=(end-segment.startEta)*geometry.semispan*Math.tan(segment.absoluteAngle*Math.PI/180);if(eta<=segment.endEta)break;}return value;};
  const endEta=geometry.sparEnd.eta,stations=[...new Set([0,endEta,...Object.values(geometry.edgeVertices).flat().map(v=>v.eta),...geometry.stringerSegments.flatMap(s=>[s.startEta,s.endEta])].filter(v=>v>=0&&v<=endEta))].sort((a,b)=>a-b),margin=(geometry.rootWidth-(count-1)*pitch)/2,rootFront=Spar.sample(geometry,0,0).position[0],rootY=geometry.points.rootReference[1],rootZ=geometry.points.rootReference[2],clearance=pitch*ratio;
  const point=(rootX,eta)=>[rootX+offset(eta),rootY+eta*geometry.semispan,rootZ+eta*geometry.semispan*Math.tan(geometry.dihedralDeg*Math.PI/180)],gaps=(rootX,eta)=>{const x=rootX+offset(eta);return[x-Spar.sample(geometry,0,eta).position[0],Spar.sample(geometry,1,eta).position[0]-x];};
  const Rib=ribAPI(),ribs=Rib?.physical(params),subdivisions=params['mesh.elements_between_ribs']??3;
  if(!ribs?.valid)throw Error(ribs?.error||'Define valid physical ribs before previewing stringer run-outs.');
  if(!Number.isSafeInteger(subdivisions)||subdivisions<1)throw Error('Elements per rib bay must be a positive whole number.');
  function snapRunout(rootX,hit){
   const trigger=point(rootX,hit.eta),vertices=stations.map(eta=>({eta,position:point(rootX,eta)}));
   // Ribs may be inclined: find the actual reference-line intersection,
   // rather than rounding the stringer ETA to the rear-spar rib anchor.
   let lo=1,hi=ribs.ribCount;while(lo<hi){const mid=Math.ceil((lo+hi)/2),rib=ribs.at(mid),rear=Spar.sample(geometry,1,rib.eta).position,side=(trigger[0]-rear[0])*rib.direction[1]-(trigger[1]-rear[1])*rib.direction[0];if(side>=-1e-10)lo=mid;else hi=mid-1;}
   const rib=ribs.at(Math.min(lo,ribs.ribCount-1)),next=ribs.at(rib.number+1),rear=Spar.sample(geometry,1,rib.eta).position,hits=Rib.intersection(rear,rib.direction,vertices,endEta);
   if(hits.length!==1)throw Error('A stringer must intersect its preceding rib datum once. Adjust the rib or stringer angles.');
   const end=hits[0],arc=Rib.arc(geometry,rib.eta,next.eta),nominal=ribs.rows.length?arc.etaAt(1/subdivisions):rib.eta+(next.eta-rib.eta)/subdivisions;
   // The generated mesh can add rows at geometry kinks. Inclined master-rib
   // meshes resolve spar/stringer kinks locally instead of inserting rows.
   const inclined=rib.delta!==0||next.delta!==0,breaks=[...Object.values(geometry.surfaceVertices||{}).flat().map(p=>p.eta),...(!inclined?stations:[])],connectorEta=Math.min(nominal,...breaks.filter(eta=>eta>rib.eta+1e-12&&eta<nominal)),f=(connectorEta-rib.eta)/(next.eta-rib.eta),delta=rib.delta+(next.delta-rib.delta)*f,direction=[-Math.cos(delta),Math.sin(delta),0],connectorRear=Spar.sample(geometry,1,connectorEta).position;
   let target=connectorRear;if(hit.edge===0){const targets=Rib.intersection(connectorRear,direction,geometry.edgeVertices[Spar.POINT_KEYS[0]],endEta);if(targets.length!==1)throw Error('The run-out connector row must meet the front spar once.');target=targets[0].position;}
   return{eta:end.eta,triggerEta:hit.eta,rib:rib.number,edge:hit.edge,points:[end.position,target]};
  }
  const paths=[];
  for(const i of sampledIndices(count,maxPaths)){
   const rootX=rootFront+margin+i*pitch,points=[point(rootX,0)];let runout=null;
   for(let j=1;j<stations.length;j++){
    const a=stations[j-1],b=stations[j],ga=gaps(rootX,a),gb=gaps(rootX,b),hits=[];
    for(let edge=0;edge<2;edge++)if(gb[edge]<clearance-tolerance){const eta=ga[edge]<=clearance?a:a+(b-a)*(ga[edge]-clearance)/(ga[edge]-gb[edge]);hits.push({eta,edge});}
    if(hits.length){hits.sort((a,b)=>a.eta-b.eta);runout=snapRunout(rootX,hits[0]);points.splice(0,points.length,...stations.filter(eta=>eta<runout.eta-1e-12).map(eta=>point(rootX,eta)),runout.points[0]);break;}
    points.push(point(rootX,b));
   }
   paths.push({index:i+1,side:'reference',label:'S'+(i+1),points,runout});
  }
  return{paths,count,sampled:paths.length<count};
 }
 function generatedPaths(payload,maxPaths){
  const all=payload?.annotations?.stringers,xyz=payload?.xyz;
  if(!Array.isArray(all)||!xyz||!Number.isSafeInteger(xyz.length)||xyz.length%3)return null;
  const paths=[];
  for(const i of sampledIndices(all.length,maxPaths)){
   const source=all[i];if(!source||!Array.isArray(source.nodes)||source.nodes.length<2||!['upper','lower'].includes(source.side))throw Error('Generated stringer paths are incomplete. Recreate the FEM.');
   let points=source.nodes.map(node=>{if(!Number.isSafeInteger(node)||node<0||3*node+2>=xyz.length)throw Error('Generated stringer node lies outside the model. Recreate the FEM.');const p=[xyz[3*node],xyz[3*node+1],xyz[3*node+2]];if(!p.every(Number.isFinite))throw Error('Generated stringer coordinates must be finite.');return p;}),runout=null;
   if(Array.isArray(source.runout_nodes)&&source.runout_nodes.length){const first=source.nodes.indexOf(source.runout_nodes[0]),tail=source.nodes.slice(first);if(first<0||tail.length!==source.runout_nodes.length||tail.some((node,i)=>node!==source.runout_nodes[i]))throw Error('Generated run-out nodes must follow the end of the stringer attachment path. Recreate the FEM.');runout={points:points.slice(first),generated:true};points=points.slice(0,first+1);}
   paths.push({index:source.index,side:source.side,label:source.label||String(source.index),points,runout});
  }
  return{paths,count:all.length,sampled:paths.length<all.length};
 }
 function derive(params,{generated=null,maxPaths=400}={}){
  if(!Number.isSafeInteger(maxPaths)||maxPaths<2||maxPaths>2000)throw Error('Preview path limit must be between 2 and 2000.');
  const geometry=Spar.derive(params),result={valid:geometry.valid,drawable:!!(geometry.valid||geometry.drawable),error:geometry.error||'',geometry,paths:[],pathCount:0,sampled:false,generated:false,ribs:[]};
  if(!result.drawable)return result;
  const layout=ribAPI()?.derive({...params,_rib_geometry:generated?.rib_layout},{maxRibs:400});result.ribs=layout?.ribs||[];
  try{
   const reference=referencePaths(params,geometry,maxPaths),actual=generatedPaths(generated,maxPaths),paths=actual||reference;
   result.paths=paths.paths;result.pathCount=paths.count;result.sampled=paths.sampled;result.generated=!!actual;
  }catch(error){result.valid=false;result.error||=error.message;}
  return result;
 }
 function drawing(data,{transform=null,selected=null}={}){
  if(!data.drawable)return'';transform||=Planform.editorTransform(data.geometry);const map=transform.map;
  let svg='<title>Stringer layout with lifting-surface outline, spars and ribs</title><desc>'+escape(data.generated?'Projection of the actual generated upper and lower stringer attachment paths; dashed lines are fixed-area run-out connectors.':'Untwisted reference stringer paths end at the preceding physical rib datum of a threshold-triggered bay. Dashed connectors join the spar immediately outboard. Create FEM for the actual upper and lower surface intersections.')+'</desc>'+Spar.referenceDrawing(data.geometry,{transform,ribs:data.ribs});
  for(const path of data.paths){const id=path.side+'-'+path.index,active=id===selected;
   svg+=`<polyline class="sl-path sl-${path.side}${active?' sl-selected':''}" data-stringer="${escape(id)}" points="${path.points.map(p=>map(p).join(',')).join(' ')}" tabindex="0" role="button" aria-label="${escape(path.label)} ${path.side} stringer; select to highlight"><title>${escape(path.label)} - ${path.side==='reference'?'untwisted reference':path.side+' skin'}${path.runout&&!path.runout.generated?' - ends at rib R'+path.runout.rib+', eta '+number(path.runout.eta)+'; threshold at eta '+number(path.runout.triggerEta):''}</title></polyline>`;
   if(path.runout)svg+=`<polyline class="sl-runout${active?' sl-selected':''}" points="${path.runout.points.map(p=>map(p).join(',')).join(' ')}"><title>${escape(path.label)} ${path.runout.generated?'generated':'reference'} 5 mm² connector from rib datum to ${path.runout.generated?'spar':path.runout.edge?'rear spar':'front spar'} immediately outboard</title></polyline>`;
  }
  return svg;
 }
 function install(host,{read,onEdit,isLocked=()=>false,readValues,readGenerated,onViewChange}={}){
  const doc=host.ownerDocument,section=doc.createElement('section');section.className='stringer-segment-angles stringer-layout-editor';
  section.innerHTML='<div class="sl-preview"><div class="sl-preview-title"><h3>Stringer plan view</h3></div><div class="sl-canvas structural-plan-canvas"><svg id="stringer-layout-svg" viewBox="0 0 800 340" role="group" aria-label="Stringer paths, ribs, spars and refined lifting-surface outline"></svg></div><p class="structural-plan-legend"><i class="surface"></i>Lifting surface <i class="base"></i>Base trapezoid <i class="front"></i>Front spar <i class="rear"></i>Rear spar <i class="rib"></i>Ribs <i class="sl-upper"></i>Upper <i class="sl-lower"></i>Lower <i class="sl-reference"></i>Reference <i class="sl-connector"></i>Run-out connector</p><p class="sl-status" role="status"></p><p class="sl-preview-error" role="alert" hidden></p></div><div class="sl-angle-editor"><h3>Spanwise stringer directions</h3><p class="pick-note">Choose the local rear spar, local front spar or Global Y as the angle reference. Zero follows the selected spar, or runs normal to the symmetry plane for Global Y; positive sweeps aft. Angle intervals are defined by the rear-spar eta points in Structure - Spars. The last angle continues to the tip. Pitch, angle and run-out edits update the reference paths immediately; Create FEM gives the actual upper and lower attachment paths.</p><div data-angles></div><p data-angle-error role="alert" hidden></p></div>';const heading=host.querySelector('.parameter-heading');if(heading)heading.after(section);else host.append(section);
  const referenceRow=doc.getElementById('row-box.stringer_angle_reference'),referenceParent=referenceRow?.parentNode,referenceNext=referenceRow?.nextSibling;if(referenceRow)section.querySelector('.sl-angle-editor h3').after(referenceRow);
  const output=section.querySelector('[data-angles]'),error=section.querySelector('[data-angle-error]'),svg=section.querySelector('svg'),status=section.querySelector('.sl-status'),previewError=section.querySelector('.sl-preview-error');
  svg.dataset.viewKey='stringer-layout';
  // Stringer paths are selectable, not draggable geometry controls. Permit
  // window zoom over their lines; remember a short click before the viewport
  // captures the pointer and retargets the browser's click event to the SVG.
  let pointerSelection=null;
  const rememberSelection=event=>{pointerSelection=event.button===0?{id:event.target.closest?.('[data-stringer]')?.dataset.stringer,x:event.clientX,y:event.clientY}:null;};
  svg.addEventListener('pointerdown',rememberSelection,true);
  const viewport=root.WingSVGViewport?.install(svg,{host:svg.parentElement,title:'Stringer layout',exportName:'stringer-layout.svg',snapSelector:'polygon,polyline,.pf-box-end,.sf-rib-datum line',isGeometryTarget:()=>false,onChange:onViewChange});
  let destroyed=false,selected=null,lastData=null;
  function refreshDrawing(){
   if(destroyed)return;
   let data;try{data=derive(readValues?readValues():{}, {generated:readGenerated?.()});}catch(e){data={valid:false,drawable:false,error:e.message,paths:[]};}lastData=data;
   previewError.hidden=data.valid;previewError.textContent=data.error||'';
   svg.innerHTML=drawing(data,{selected});
   if(data.drawable&&Spar.contextGeometry){const context=Spar.contextGeometry(readValues?readValues():{});svg.insertAdjacentHTML('beforeend',Spar.contextDrawing(context,{transform:Planform.editorTransform(data.geometry),includeSpars:false,includeRibs:false}));}
   if(data.drawable){const t=Planform.editorTransform(data.geometry),o=t.map([0,0,0]);viewport?.setMetric({origin:{x:o[0],y:o[1]},x:{x:t.scale,y:0},y:{x:0,y:t.scale},unit:'m',horizontalLabel:'\u0394y',verticalLabel:'\u0394x',gridSpacing:1});}
   const chosen=data.paths?.find(path=>path.side+'-'+path.index===selected);
   status.textContent=data.drawable?(data.generated?'Generated attachment paths':'Untwisted reference preview')+' - '+data.pathCount+' '+(data.generated?'upper/lower paths':'physical stringers')+(data.sampled?' - '+data.paths.length+' evenly sampled for this drawing':'')+(chosen?' - Selected '+chosen.label:'')+(data.generated?'':' - Ends snap to physical rib datums; dashed connectors join the spar immediately outboard. Create FEM for actual surface intersections.'):'Complete the planform, spars, pitch and angles to preview the stringers.';
   viewport?.refresh();
  }
  function refresh(){
   if(destroyed)return;refreshDrawing();
   const points=read?.()||[],legacy=doc.getElementById('row-box.stringer_angle');if(legacy)legacy.hidden=points.length>0;
   // Preserve focused angle drafts, while always updating the drawing above.
   if(output.contains(doc.activeElement))return;
   output.replaceChildren();error.hidden=true;
   if(!points.length){const p=doc.createElement('p');p.className='pick-note';p.textContent='No rear-spar perturbation points: the default angle applies along the full span using the selected reference.';output.append(p);return;}
   const table=doc.createElement('table');table.className='stringer-angle-table';table.innerHTML='<thead><tr><th>Span eta</th><th>Angle (deg)</th></tr></thead><tbody></tbody>';
   for(const row of segments(points)){
    const tr=doc.createElement('tr'),label=doc.createElement('th'),value=doc.createElement('td');label.scope='row';label.textContent=row.unused?'Root point (unused)':String(row.start)+' - '+String(row.end);tr.append(label,value);
    if(row.inherited){value.dataset.inheritedPoint=String(row.index);value.textContent=String(row.angle)+' - same as previous';}
    else{const input=doc.createElement('input');input.type='number';input.step='any';input.value=Number.isFinite(row.angle)?String(row.angle):'';input.dataset.pointIndex=String(row.index);input.setAttribute('aria-label','Stringer angle for rear point '+(row.index+1));input.disabled=isLocked()||row.unused;
     input.addEventListener('change',()=>{if(isLocked())return;const angle=Number(input.value);if(!input.value.trim()||!Number.isFinite(angle)){error.textContent='Enter a finite stringer angle in degrees.';error.hidden=false;return;}const next=(read?.()||[]).map(p=>({...p}));if(!next[row.index])return;next[row.index].stringer_angle=angle;error.hidden=true;onEdit?.(next);refreshDrawing();for(const inherited of output.querySelectorAll('[data-inherited-point]'))if(Number(inherited.dataset.inheritedPoint)===row.index)inherited.textContent=String(angle)+' - same as previous';});value.append(input);}
    table.tBodies[0].append(tr);
   }output.append(table);
  }
  function select(event){const hit=event.target.closest?.('[data-stringer]'),id=hit?.dataset.stringer||(event.type==='click'&&event.button===0&&pointerSelection&&Math.hypot(event.clientX-pointerSelection.x,event.clientY-pointerSelection.y)<5?pointerSelection.id:null);pointerSelection=null;if(!id)return;if(event.type==='keydown'&&!['Enter',' '].includes(event.key))return;if(event.type==='keydown')event.preventDefault();selected=selected===id?null:id;refreshDrawing();}
  const onExternal=event=>{if(PARAM_KEYS.some(key=>event.target?.id==='p-'+key))refresh();},onLock=()=>{for(const input of section.querySelectorAll('[data-point-index]'))input.disabled=isLocked()||!!segments(read?.()||[]).find(r=>r.index===Number(input.dataset.pointIndex)&&!r.inherited)?.unused;refreshDrawing();};
  doc.addEventListener('input',onExternal);doc.addEventListener('change',onExternal);host.addEventListener('parameterlockchange',onLock);svg.addEventListener('click',select);svg.addEventListener('keydown',select);
  refresh();return{refresh,refreshDrawing,section,viewport,captureView:()=>viewport?.capture(),restoreView:value=>viewport?.restore(value),data:()=>lastData,destroy(){destroyed=true;if(referenceRow&&referenceParent)referenceParent.insertBefore(referenceRow,referenceNext?.parentNode===referenceParent?referenceNext:null);viewport?.destroy();svg.removeEventListener('pointerdown',rememberSelection,true);doc.removeEventListener('input',onExternal);doc.removeEventListener('change',onExternal);host.removeEventListener('parameterlockchange',onLock);section.remove();}};
 }
 return{PARAM_KEYS,segments,referencePaths,generatedPaths,derive,drawing,install};
});
