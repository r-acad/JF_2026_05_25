/* Projected reference trapezoid and normalized edge control points.
 * Keep physical-x interpolation in step with geometry.jl.
 */
(function(root,factory){const api=factory(root);if(typeof module==="object"&&module.exports)module.exports=api;else root.WingPlanformView=api;})(typeof globalThis!=="undefined"?globalThis:this,function(root){
 "use strict";
 const POINT_KEYS=["planform.leading_edge_points","planform.trailing_edge_points"];
 const NUMBER_KEYS=["planform.area","planform.aspect_ratio","planform.taper_ratio","planform.sweep","planform.sweep_ref_xc","planform.root_ref_x","planform.root_ref_y","planform.root_ref_z","planform.dihedral","planform.twist_tip","planform.twist_axis_xc","box.end_eta"];
 const PARAM_KEYS=[...NUMBER_KEYS,...POINT_KEYS];
 const RAD=Math.PI/180,instances=new WeakMap();
 function nominalPointXc(key,params={}){return key==="planform.trailing_edge_points"?1:key==="box.front_spar_points"?(params["box.front_spar_xc"]??.2):key==="box.rear_spar_points"?(params["box.rear_spar_xc"]??.55):0;}
 function normalizePointRows(raw,key,params={}){
  if(!Array.isArray(raw)||raw.length>100)throw new Error(key+" must contain an array of at most 100 points.");
  const rear=key==="box.rear_spar_points",nominal=nominalPointXc(key,params),rows=[];
  for(const p of raw){const fields=p&&typeof p==="object"?Object.keys(p).sort().join(","):"",coordinate=p&&Object.hasOwn(p,"dxc")?"dxc":"xc",expected=["eta",coordinate].sort().join(","),withAngle=["eta",coordinate,"stringer_angle"].sort().join(",");
   if(!p||(fields!==expected&&!(rear&&fields===withAngle))||typeof p.eta!=="number"||!Number.isFinite(p.eta)||p.eta<0||p.eta>1||typeof p[coordinate]!=="number"||!Number.isFinite(p[coordinate]))throw new Error(key+": use eta between 0 and 1 and a finite dxc offset (or legacy xc, never both).");
   const dxc=p[coordinate]-(coordinate==="xc"?nominal:0);if(!Number.isFinite(dxc))throw new Error(key+": dxc must be finite.");const row={eta:p.eta===0?0:p.eta,dxc};
   if(rear){const angle=Object.hasOwn(p,"stringer_angle")?p.stringer_angle:0;if(typeof angle!=="number"||!Number.isFinite(angle))throw new Error("Rear spar: stringer angle must be finite.");row.stringer_angle=angle;}rows.push(row);
  }
  rows.sort((a,b)=>a.eta-b.eta);if(rows.some((p,i)=>i&&p.eta===rows[i-1].eta))throw new Error(key+": each point must have a different eta.");return rows;
 }
 function normalizePointParams(params){const out={...params};for(const key of [...POINT_KEYS,"box.front_spar_points","box.rear_spar_points"])if(Object.hasOwn(params,key))out[key]=normalizePointRows(params[key],key,params);return out;}
 // UI migration must preserve malformed/duplicate draft rows so users can
 // repair them. Acceptance remains exclusively in normalizePointRows/derive.
 function migratePointParams(params){const out={...params};for(const key of [...POINT_KEYS,"box.front_spar_points","box.rear_spar_points"]){if(!Array.isArray(params[key]))continue;const nominal=nominalPointXc(key,params);out[key]=params[key].map(point=>{if(!point||typeof point!=="object"||Object.hasOwn(point,"dxc")||!Object.hasOwn(point,"xc"))return point;const row={...point,dxc:typeof point.xc==="number"?point.xc-nominal:point.xc};delete row.xc;return row;});}return out;}
 function derive(params){
  const values={},errors=[],invalid=[];
  const names={area:"Wing area",aspect_ratio:"Aspect ratio",taper_ratio:"Taper ratio",sweep:"Sweep",sweep_ref_xc:"Sweep reference",root_ref_x:"Root reference x",root_ref_y:"Root reference y",root_ref_z:"Root reference z",dihedral:"Dihedral",twist_tip:"Tip twist",twist_axis_xc:"Twist axis"};
  for(const key of NUMBER_KEYS){if(key==="box.end_eta"&&params[key]===undefined)continue;const fallback=key==="planform.root_ref_y"||key==="planform.root_ref_z"?0:undefined,value=params[key]===undefined?fallback:params[key];values[key]=value;
   if(typeof value!=="number"||!Number.isFinite(value)){errors.push((names[key.slice(9)]||"Box end ETA")+" must be a finite number.");invalid.push(key);}}
  const fail=(key,condition,message)=>{if(!invalid.includes(key)&&!condition){errors.push(message);invalid.push(key);}};
  for(const key of ["area","aspect_ratio"])fail("planform."+key,values["planform."+key]>0,names[key]+" must be greater than zero.");
  fail("planform.taper_ratio",values["planform.taper_ratio"]>0&&values["planform.taper_ratio"]<=1,"Taper ratio must be greater than zero and no greater than one.");
  for(const key of ["sweep_ref_xc","twist_axis_xc"])fail("planform."+key,values["planform."+key]>=0&&values["planform."+key]<=1,names[key]+" must be between 0 and 1.");
  for(const key of ["sweep","dihedral"])fail("planform."+key,Math.abs(values["planform."+key])<89,names[key]+" must be between -89 and 89 degrees (exclusive).");
  fail("planform.twist_tip",Math.abs(values["planform.twist_tip"])<45,"Tip twist must be between -45 and 45 degrees (exclusive).");
  if(values["box.end_eta"]!==undefined)fail("box.end_eta",values["box.end_eta"]>0&&values["box.end_eta"]<=1,"Box end ETA must be greater than zero and no greater than one.");
  if(errors.length)return{valid:false,error:errors.join(" "),invalid};
  const S=values["planform.area"],AR=values["planform.aspect_ratio"],taper=values["planform.taper_ratio"],span=Math.sqrt(AR*S),semispan=span/2,rootChord=2*S/(span*(1+taper)),tipChord=taper*rootChord,mac=2/3*rootChord*(1+taper+taper*taper)/(1+taper);
  const sweep=values["planform.sweep"],sweepRef=values["planform.sweep_ref_xc"],dihedral=values["planform.dihedral"],rootReference=[values["planform.root_ref_x"],values["planform.root_ref_y"],values["planform.root_ref_z"]];
  const chord=eta=>rootChord*(1-(1-taper)*eta),reference=eta=>[rootReference[0]+eta*semispan*Math.tan(sweep*RAD),rootReference[1]+eta*semispan,rootReference[2]+eta*semispan*Math.tan(dihedral*RAD)];
  const at=(eta,xc)=>{const p=reference(eta);return[p[0]+chord(eta)*(xc-sweepRef),p[1],p[2]];};
  const points={rootLE:at(0,0),rootTE:at(0,1),tipLE:at(1,0),tipTE:at(1,1),rootReference,tipReference:reference(1)};
  const controls={},edgeVertices={};
  for(let e=0;e<POINT_KEYS.length;e++){
   const key=POINT_KEYS[e],label=e===0?"Leading edge":"Trailing edge",raw=params[key]===undefined?[]:params[key];
   let rows;try{rows=normalizePointRows(raw,key,params);}catch(error){return{valid:false,error:error.message,invalid:[key]};}
   controls[key]=rows;
   const anchored=rows.slice();if(!anchored.some(p=>p.eta===0))anchored.unshift({eta:0,dxc:0});if(!anchored.some(p=>p.eta===1))anchored.push({eta:1,dxc:0});
   edgeVertices[key]=anchored.map(p=>({...p,xc:e+p.dxc,delta:p.dxc*chord(p.eta),position:at(p.eta,e+p.dxc)}));
  }
  const edgeDelta=(edge,eta)=>{const vertices=edgeVertices[POINT_KEYS[edge]];let i=1;while(i<vertices.length-1&&vertices[i].eta<eta)i++;const a=vertices[i-1],b=vertices[i],f=(eta-a.eta)/(b.eta-a.eta);return a.delta+f*(b.delta-a.delta);};
  const edgeAt=(edge,eta)=>{const pos=at(eta,edge);pos[0]+=edgeDelta(edge,eta);return pos;};
  const breaks=[...new Set(Object.values(edgeVertices).flat().map(p=>p.eta))].sort((a,b)=>a-b);
  const actualChords=breaks.map(eta=>chord(eta)+edgeDelta(1,eta)-edgeDelta(0,eta));
  const surfaceError=actualChords.some(c=>!Number.isFinite(c)||c<=0)?"Leading and trailing edges must not cross or touch: the refined chord must stay positive at every station.":"";
  let actualHalfArea=0,chordSquaredIntegral=0;for(let i=1;i<breaks.length;i++){const dy=(breaks[i]-breaks[i-1])*semispan,a=actualChords[i-1],b=actualChords[i];actualHalfArea+=dy*(a+b)/2;chordSquaredIntegral+=dy*(a*a+a*b+b*b)/3;}
  const baseRight=[points.rootLE,points.tipLE,points.tipTE,points.rootTE],right=[...edgeVertices[POINT_KEYS[0]].map(p=>p.position),...edgeVertices[POINT_KEYS[1]].slice().reverse().map(p=>p.position)],left=right.map(p=>[p[0],2*rootReference[1]-p[1],p[2]]),endEta=values["box.end_eta"],boxEnd=endEta===undefined?null:{eta:endEta,leading:at(endEta,0),trailing:at(endEta,1),reference:reference(endEta),chord:chord(endEta)};
  const all=right.concat(left,baseRight),xmin=Math.min(...all.map(p=>p[0])),xmax=Math.max(...all.map(p=>p[0])),ymin=Math.min(...all.map(p=>p[1])),ymax=Math.max(...all.map(p=>p[1]));
  if(![span,semispan,rootChord,tipChord,mac,actualHalfArea,chordSquaredIntegral,...all.flat(),...points.tipReference,...(boxEnd?.leading||[]),...(boxEnd?.trailing||[])].every(Number.isFinite)||![span,rootChord,tipChord,xmax-xmin,ymax-ymin].every(v=>v>0))return{valid:false,error:"The dimensions cannot be resolved at these input magnitudes or root offsets.",invalid:PARAM_KEYS.slice()};
  return{valid:!surfaceError,drawable:true,error:surfaceError,invalid:surfaceError?POINT_KEYS.slice():[],version:2,coordinateSystem:"FE basic axes: x aft, y toward the modeled tip, z up; metres",basis:"Untwisted projected planform",area:S,halfArea:S/2,aspectRatio:AR,taper,span,semispan,rootChord,tipChord,mac,sweepDeg:sweep,sweepRef,dihedralDeg:dihedral,twistTipDeg:values["planform.twist_tip"],twistAxis:values["planform.twist_axis_xc"],points,right,left,baseRight,boxEnd,controls,edgeVertices,actualArea:actualHalfArea*2,actualHalfArea,actualAspectRatio:span*span/(2*actualHalfArea),actualTaper:actualChords.at(-1)/actualChords[0],actualRootChord:actualChords[0],actualTipChord:actualChords.at(-1),actualMAC:chordSquaredIntegral/actualHalfArea,bounds:{xmin,xmax,ymin,ymax}};
 }
 const number=value=>root.WingNumbers?root.WingNumbers.format(value,6):Number(value.toPrecision(6)).toString();
 function drawing(data,{mirror=false,id="planform"}={}){
  if(!data.valid)return"";
  const rootPoint=data.points.rootReference,minY=mirror?data.bounds.ymin:rootPoint[1],width=mirror?data.span:data.semispan,height=data.bounds.xmax-data.bounds.xmin,scale=Math.min(700/width,330/height),left=130+(700-width*scale)/2,top=125+(330-height*scale)/2;
  const map=p=>[left+(p[1]-minY)*scale,top+(p[0]-data.bounds.xmin)*scale],p=data.points,r=map(p.rootReference),t=map(p.tipReference),le=map(p.rootLE),te=map(p.rootTE),tl=map(p.tipLE),tt=map(p.tipTE);
  const text=(x,y,value,attr="")=>`<text x="${x}" y="${y}" ${attr}>${value}</text>`;
  const line=(a,b,cls="")=>`<line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" class="${cls}"/>`;
  const dim=(a,b)=>`<line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" class="pf-dimension" marker-start="url(#${id}-dim)" marker-end="url(#${id}-dim)"/>`;
  const poly=(points,cls)=>`<polygon points="${points.map(p=>map(p).join(",")).join(" ")}" class="${cls}"/>`;
  let svg=`<title>Dimensioned projected wing planform</title><desc>${data.basis}. Full span ${number(data.span)} metres, reference half-span ${number(data.semispan)} metres, base root chord ${number(data.rootChord)} metres, base tip chord ${number(data.tipChord)} metres. Sweep ${number(data.sweepDeg)} degrees at x/c ${number(data.sweepRef)}. Coordinates use the current root reference offsets.</desc><defs><marker id="${id}-dim" markerWidth="7" markerHeight="7" refX="3.5" refY="3.5" orient="auto-start-reverse"><path d="M7 0 L0 3.5 L7 7" fill="none" stroke="currentColor" stroke-width="1.2"/></marker><marker id="${id}-axis" markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto"><path d="M0 0 L7 3.5 L0 7 Z" fill="context-stroke"/></marker></defs>`;
  if(mirror)svg+=poly(data.left,"pf-mirror");svg+=poly(data.right,"pf-wing");svg+=poly(data.baseRight,"pf-base");
  svg+=line(le,te,"pf-root")+line(r,t,"pf-reference");if(mirror){const mirrored=[t[0]-data.span*scale,t[1]];svg+=line(r,mirrored,"pf-reference pf-left-reference");}
  const start=mirror?left:r[0],finish=t[0];
  svg+=line([start,(mirror?tl[1]:le[1])-7],[start,57],"pf-extension")+line([finish,tl[1]-7],[finish,57],"pf-extension")+dim([start,69],[finish,69])+text((start+finish)/2,49,(mirror?"Full projected span b = ":"Right reference half-span s = ")+number(mirror?data.span:data.semispan)+" m",'text-anchor="middle" class="pf-dim-label"');
  if(mirror)svg+=line([r[0],Math.max(te[1],tt[1])+9],[r[0],524],"pf-extension")+line([t[0],tt[1]+9],[t[0],524],"pf-extension")+dim([r[0],512],[t[0],512])+text((r[0]+t[0])/2,539,"Right reference half-span s = "+number(data.semispan)+" m",'text-anchor="middle" class="pf-dim-label"');
  const rootDim=le[0]-30,tipDim=tl[0]+47;
  svg+=line(le,[rootDim-9,le[1]],"pf-extension")+line(te,[rootDim-9,te[1]],"pf-extension")+dim([rootDim,le[1]],[rootDim,te[1]])+text(rootDim-11,(le[1]+te[1])/2,"Root chord = "+number(data.rootChord)+" m",`text-anchor="middle" class="pf-dim-label" transform="rotate(-90 ${rootDim-11} ${(le[1]+te[1])/2})"`);
  svg+=line(tl,[tipDim+9,tl[1]],"pf-extension")+line(tt,[tipDim+9,tt[1]],"pf-extension")+dim([tipDim,tl[1]],[tipDim,tt[1]])+text(tipDim+24,(tl[1]+tt[1])/2,"Tip chord = "+number(data.tipChord)+" m",`text-anchor="middle" class="pf-dim-label" transform="rotate(-90 ${tipDim+24} ${(tl[1]+tt[1])/2})"`);
  const arc=Math.min(62,Math.max(26,data.semispan*scale*.23)),angle=data.sweepDeg*RAD,arcEnd=[r[0]+arc*Math.cos(angle),r[1]+arc*Math.sin(angle)];
  svg+=line(r,[r[0]+arc+27,r[1]],"pf-angle-baseline");
  if(Math.abs(angle)>1e-9)svg+=`<path d="M ${r[0]+arc} ${r[1]} A ${arc} ${arc} 0 0 ${angle>0?1:0} ${arcEnd.join(" ")}" class="pf-angle"/>`;
  svg+=text(r[0]+arc+29,r[1]+(angle<0?-12:23),"Sweep "+number(data.sweepDeg)+"°",'class="pf-angle-label"');
  svg+=`<circle cx="${r[0]}" cy="${r[1]}" r="5" class="pf-origin"/>`+text(r[0]-10,r[1]-12,"R",'class="pf-origin-label" text-anchor="end"');
  if(data.boxEnd&&data.boxEnd.eta<1){const a=map(data.boxEnd.leading),b=map(data.boxEnd.trailing);svg+=line(a,b,"pf-box-end")+text((a[0]+b[0])/2,b[1]+23,"Box end η = "+number(data.boxEnd.eta),'class="pf-box-label" text-anchor="middle"');}
  svg+=text(500,586,"Projected reference planform • equal scale in x and y",'text-anchor="middle" class="pf-caption"');
  svg+=`<g class="pf-fe-axes"><line x1="66" y1="548" x2="114" y2="548" stroke="#4cc38a" marker-end="url(#${id}-axis)"/><line x1="66" y1="548" x2="66" y2="590" stroke="#ef5f6b" marker-end="url(#${id}-axis)"/><circle cx="66" cy="548" r="5" stroke="#56a8f5" fill="none"/><circle cx="66" cy="548" r="1.5" fill="#56a8f5"/>${text(121,553,"+y")}${text(58,609,"+x")}${text(47,533,"+z out")}</g>`;
  return svg;
 }
 function editorTransform(data){
  const height=Math.max(data.bounds.xmax-data.bounds.xmin,1e-12),scale=Math.min(660/data.semispan,230/height),left=66+(660-data.semispan*scale)/2,top=40+(230-height*scale)/2;
  return{scale,left,top,map:p=>[left+(p[1]-data.points.rootReference[1])*scale,top+(p[0]-data.bounds.xmin)*scale],unmap:(x,y)=>({eta:(x-left)/scale/data.semispan,x:data.bounds.xmin+(y-top)/scale})};
 }
 function editorDrawing(data,{transform=editorTransform(data),selected=null,locked=false,pointOrder=null}={}){
  if(!data.valid)return"";
  const map=transform.map,poly=(points,cls)=>`<polygon points="${points.map(p=>map(p).join(",")).join(" ")}" class="${cls}"/>`;
  let svg='<title>Editable wing planform, positive x aft and positive y towards the tip</title><desc>Drag leading and trailing edge points, or edit their eta and delta x/c offsets in the tables. The dashed outline is the base trapezoid.</desc>'+poly(data.right,"pf-wing")+poly(data.baseRight,"pf-base");
  for(let e=0;e<POINT_KEYS.length;e++)for(let i=0;i<data.controls[POINT_KEYS[e]].length;i++){
   const p=data.controls[POINT_KEYS[e]][i],v=data.edgeVertices[POINT_KEYS[e]].find(q=>q.eta===p.eta),xy=map(v.position),name=e===0?"Leading":"Trailing",active=selected?.edge===e&&selected?.eta===p.eta,orderIndex=pointOrder?.[POINT_KEYS[e]]?.findIndex(q=>q.eta===p.eta),labelIndex=orderIndex>=0?orderIndex:i;
   svg+=`<g class="pf-point ${e===0?"pf-leading":"pf-trailing"}${active?" pf-selected":""}" data-edge="${e}" data-index="${i}" data-eta="${p.eta}" tabindex="${locked?-1:0}" role="button" aria-disabled="${locked}" aria-label="${name} edge point ${labelIndex+1}: eta ${number(p.eta)}, delta x/c ${number(p.dxc)}. Arrow keys move; Shift for larger steps; Enter focuses table."><circle class="pf-point-hit" cx="${xy[0]}" cy="${xy[1]}" r="17"/><circle class="pf-point-dot" cx="${xy[0]}" cy="${xy[1]}" r="7"/><text x="${xy[0]+12}" y="${xy[1]+(e===0?-12:22)}">${e===0?"L":"T"}${labelIndex+1}</text></g>`;
  }
  svg+=`<text x="30" y="22" class="pf-editor-axis">+x aft ↓</text><text x="730" y="304" text-anchor="end" class="pf-editor-axis">+y toward tip →</text><text x="${transform.left}" y="304" class="pf-editor-axis">η = 0</text><text x="${transform.left+data.semispan*transform.scale}" y="325" text-anchor="end" class="pf-editor-axis">η = 1</text>`;
  return svg;
 }
 function createEditor(host,options,view,config={}){
  const keys=config.pointKeys||POINT_KEYS,deriveData=config.derive||derive,draw=config.drawing||editorDrawing,makeTransform=config.transform||editorTransform,edgeNames=config.edgeNames||["Leading edge","Trailing edge"],prefixes=config.prefixes||["L","T"],extraFields=config.extraFields||keys.map(()=>[]);
  const doc=host.ownerDocument,section=doc.createElement("section");section.className="planform-editor";section.setAttribute("aria-label","Planform perturbation editor");
  section.innerHTML='<div class="planform-editor-sticky"><div class="planform-editor-toolbar"><strong>Planform</strong><span class="pf-legend"><i></i>Refined <i class="base"></i>Base trapezoid</span></div><div class="planform-view-canvas planform-editor-canvas"><svg id="planform-editor-svg" viewBox="0 0 800 340" aria-label="Editable wing planform" role="group"></svg></div><p class="planform-editor-metrics" aria-live="polite"></p><p class="planform-editor-error" role="alert" hidden></p></div><p class="planform-editor-help">Define the trapezoid below, then refine either edge with points. Drag a point or edit its table row. <b>η</b> is the fraction of the projected half-span. <b>\u0394x/c</b> is the offset from the nominal edge, measured as a fraction of the <em>base trapezoid</em> chord: 0 follows that edge, +0.2 moves aft by 20% of the chord, and -0.2 moves forward. The offsets follow changes to the trapezoid. The aerodynamic and structural outer surfaces both follow this refined outline. Spar reference paths keep their independent base-trapezoid coordinates in Box; their heights, the skins, nose and fuel volume update with the surface.</p><div class="planform-point-tables"></div><p class="planform-editor-help">Straight segments join the points in physical space. Missing root/tip points have zero offset from the base edges. Add points at η = 0 or 1 to move these endpoints. Select a point and use arrow keys (Shift for a larger step), Enter for its table row, or Escape to cancel a drag.</p>';
  if(config.name){section.classList.add(config.className||"custom-point-editor");section.setAttribute("aria-label",config.name+" perturbation editor");section.querySelector("strong").textContent=config.name;section.querySelector("svg").id=config.svgId;section.querySelector("svg").setAttribute("aria-label",config.name+" diagram");}
  if(config.legend)section.querySelector(".pf-legend").innerHTML=config.legend;
  if(config.helpStart)section.querySelector(".planform-editor-help").innerHTML=config.helpStart;
  if(config.helpEnd)section.querySelectorAll(".planform-editor-help")[1].innerHTML=config.helpEnd;
  const heading=host.querySelector(".parameter-heading");if(heading)heading.insertAdjacentElement("afterend",section);else host.prepend(section);
  const svg=section.querySelector("svg"),error=section.querySelector(".planform-editor-error"),metrics=section.querySelector(".planform-editor-metrics"),tables=section.querySelector(".planform-point-tables"),sticky=section.querySelector(".planform-editor-sticky");
  // The workbench moves this drawing beside its tables. Carry its specific
  // styling with it instead of depending on the former section ancestor.
  if(config.className)sticky.classList.add(config.className);
  svg.dataset.viewKey=config.name?"spars":"planform";
  const viewport=globalThis.WingSVGViewport?.install(svg,{host:svg.parentElement,title:config.name||"Planform",exportName:svg.dataset.viewKey+".svg",snapSelector:"polygon,polyline,.pf-point-dot,.pf-box-end",isGeometryTarget:target=>!!target.closest?.("[data-edge]"),onChange:options.onViewChange});
  let selected=null,drag=null,lastValid=null,contextError="",notifiedDrafts=null;
  const supported=keys.every(key=>doc.getElementById("p-"+key));
  const locked=()=>!supported||!!options.isLocked?.(),read=()=>options.readValues();
  const canDraw=data=>data.valid||!!(config.editInvalid&&data.drawable);
  const setError=message=>{error.hidden=!message;error.textContent=message||"";};
  function readDrafts(){const params={...read()};for(let edge=0;edge<keys.length;edge++){const key=keys[edge],table=tables.querySelector(`[data-key="${key}"]`);params[key]=table?Array.from(table.querySelectorAll("tbody tr")).map(row=>{const result={};for(const field of ["eta","dxc",...extraFields[edge].map(f=>f.key)]){const input=row.querySelector(`[data-field="${field}"]`);result[field]=input.value.trim()===""?NaN:Number(input.value);}return result;}):params[key]||[];}return params;}
  function notifyDraftEdits(params){const next=Object.fromEntries(keys.map(key=>[key,JSON.stringify(params[key])])),changed=notifiedDrafts?keys.filter(key=>next[key]!==notifiedDrafts[key]):[];notifiedDrafts=next;for(const key of changed)options.onEdit?.(key);}
  function render(data,{fixed=null,message=""}={}){
   setError(message||(!data.valid?data.error+(config.editInvalid?" Continue editing the points or base parameters; FEM generation is blocked until the definition is valid.":""):contextError||( !supported?"Restart the generator and refresh to enable perturbation points.":"" )));
   section.classList.toggle("point-editor-invalid",!data.valid);
   sticky.classList.toggle("point-editor-invalid",!data.valid);
   if(canDraw(data)){if(data.valid)lastValid=data;svg.innerHTML=draw(data,{transform:fixed||undefined,selected,locked:locked(),pointOrder:drag?.latest||readDrafts()});metrics.textContent=(config.metrics?config.metrics(data,locked()):`Base area ${number(data.area)} m² · Refined area ${number(data.actualArea)} m² · Half-span ${number(data.semispan)} m${locked()?" · Planform locked":""}`)+(!data.valid?" · Invalid draft":"");}
   else{svg.replaceChildren();metrics.textContent="Correct the highlighted definition to draw the diagram.";}
   if(canDraw(data)){const t=fixed||editorTransform(data),o=t.map([0,0,0]);viewport?.setMetric?.({origin:{x:o[0],y:o[1]},x:{x:t.scale,y:0},y:{x:0,y:t.scale},unit:"m",gridSpacing:1});}
   viewport?.refresh();
   const drafts=readDrafts();
   for(const control of tables.querySelectorAll("input,button")){const group=control.closest(".planform-edge-table"),edge=Number(group.dataset.edge),row=control.closest("tr"),index=row?Array.from(row.parentElement.children).indexOf(row):-1,reason=config.fieldDisabled?.(edge,control.dataset.field,drafts[keys[edge]][index],drafts[keys[edge]])||"";control.disabled=locked()||!!reason||(control.matches(".planform-point-add")&&group.querySelectorAll("tbody tr").length>=100);if(control.dataset.field&&extraFields[edge].some(f=>f.key===control.dataset.field))control.title=reason||extraFields[edge].find(f=>f.key===control.dataset.field).help||"";}
   config.onRender?.(drafts,data);
  }
  function refresh(){if(drag)return;const data=deriveData(readDrafts());render(data);if(view.dialog?.open)view.refresh();}
  function tableFocus(edge,index,field="eta"){const input=tables.querySelectorAll("tbody")[edge]?.children[index]?.querySelector(`[data-field="${field}"]`);input?.focus();input?.select();}
  function editDraft(params,focus=null){
   if(commit(params,focus))return true;
   if(!config.editInvalid||locked())return false;
   // An intermediate repair need not fix every spar at once. Retain it in the
   // visible tables only; collectParams still requires a fully valid draft.
   setTables(params);refresh();notifyDraftEdits(params);if(focus)tableFocus(focus.edge,focus.index,focus.field);return true;
  }
  function addPoint(edge){
   if(locked())return;
   const p=readDrafts(),data=deriveData(p),key=keys[edge];
   if(!data.valid&&!config.editInvalid){render(data);return;}
   let vertices;
   if(canDraw(data))vertices=data.edgeVertices[key];
   else{
    // Blank coordinates, duplicate stations or degenerate base geometry must
    // not disable the tables. Seed a new editable row in the largest eta gap.
    const dxc=0;
    vertices=p[key].filter(v=>Number.isFinite(v.eta)&&v.eta>=0&&v.eta<=1).map(v=>({eta:v.eta,dxc:Number.isFinite(v.dxc)?v.dxc:dxc})).sort((a,b)=>a.eta-b.eta);
    if(!vertices.some(v=>v.eta===0))vertices.unshift({eta:0,dxc});
    if(!vertices.some(v=>v.eta===1))vertices.push({eta:1,dxc});
   }
   let best=1;for(let i=2;i<vertices.length;i++)if(vertices[i].eta-vertices[i-1].eta>vertices[best].eta-vertices[best-1].eta)best=i;
   const a=vertices[best-1],b=vertices[best],eta=(a.eta+b.eta)/2;
   let dxc=a.dxc/2+b.dxc/2;
   if(canDraw(data)){const chord=t=>data.rootChord*(1-(1-data.taper)*t);dxc=(a.dxc*chord(a.eta)/2+b.dxc*chord(b.eta)/2)/chord(eta);}
   p[key].push({eta,dxc,...Object.fromEntries(extraFields[edge].map(f=>[f.key,f.default]))});p[key].sort((a,b)=>a.eta-b.eta);editDraft(p,{edge,index:p[key].findIndex(v=>v.eta===eta)});
  }
  function setTables(params){
   tables.replaceChildren();
   for(let edge=0;edge<keys.length;edge++){
    const key=keys[edge],group=doc.createElement("section"),title=edgeNames[edge];group.className="planform-edge-table";group.dataset.edge=String(edge);
    const bar=doc.createElement("div");bar.className="planform-edge-heading";const h=doc.createElement("h3");h.textContent=title;const add=doc.createElement("button");add.type="button";add.className="planform-point-add";add.textContent="+ Add point";add.setAttribute("aria-label","Add "+title.toLowerCase()+" point");bar.append(h,add);group.appendChild(bar);
    const table=doc.createElement("table");table.dataset.key=key;table.innerHTML='<thead><tr><th scope="col">Point</th><th scope="col">η (span)</th><th scope="col">\u0394x/c (offset)</th><th scope="col"><span class="pf-sr-only">Remove</span></th></tr></thead><tbody></tbody>';for(const field of extraFields[edge]){const th=doc.createElement("th");th.scope="col";th.textContent=field.label;th.title=field.help||"";table.querySelector("thead tr").insertBefore(th,table.querySelector("thead tr").lastChild);}group.appendChild(table);
    if(config.edgeHelp?.[edge]){const note=doc.createElement("p");note.className="planform-edge-note";note.textContent=config.edgeHelp[edge];group.appendChild(note);}
    const rows=Array.isArray(params[key])?params[key].map(p=>({...p,dxc:p.dxc===undefined?p.xc-nominalPointXc(key,params):p.dxc})).sort((a,b)=>a.eta-b.eta):[];
    for(let i=0;i<rows.length;i++){
     const row=doc.createElement("tr"),name=doc.createElement("th");name.scope="row";name.textContent=prefixes[edge]+(i+1);row.appendChild(name);
     for(const field of ["eta","dxc",...extraFields[edge].map(f=>f.key)]){const extra=extraFields[edge].find(f=>f.key===field),td=doc.createElement("td"),input=doc.createElement("input");input.type="number";input.step="any";input.value=String(rows[i][field]===undefined?extra?.default:rows[i][field]);input.dataset.field=field;input.setAttribute("aria-label",`${title} point ${i+1} ${extra?.label||(field==="eta"?"eta":"delta x/c")}`);if(field==="eta"){input.min="0";input.max="1";}td.appendChild(input);row.appendChild(td);input.addEventListener("input",()=>{selected={edge,eta:Number(row.querySelector('[data-field="eta"]').value)};refresh();if(config.editInvalid&&!locked())notifyDraftEdits(readDrafts());});input.addEventListener("change",()=>{if(locked())return;commit(readDrafts(),null,true);});input.addEventListener("focus",()=>{selected={edge,eta:Number(row.querySelector('[data-field="eta"]').value)};refresh();});}
     const td=doc.createElement("td"),remove=doc.createElement("button");remove.type="button";remove.className="planform-point-remove";remove.textContent="×";remove.setAttribute("aria-label",`Remove ${title.toLowerCase()} point ${i+1}`);remove.onclick=()=>{if(locked())return;const p=readDrafts();p[key].splice(i,1);const focus={edge,index:Math.min(i,p[key].length-1)};if(!commit(p,focus)){setTables(p);refresh();if(config.editInvalid)notifyDraftEdits(p);tableFocus(focus.edge,focus.index);}};td.appendChild(remove);row.appendChild(td);table.querySelector("tbody").appendChild(row);
    }
    if(!rows.length){const empty=doc.createElement("p");empty.className="planform-edge-empty";empty.textContent=config.emptyText||"No perturbations: follows the base edge.";group.appendChild(empty);}
    add.onclick=()=>addPoint(edge);tables.appendChild(group);
   }
  }
  function commit(params,focus=null,keepTables=false){
   if(locked()){setTables(read());refresh();return false;}
   const data=deriveData(params);if(!data.valid){render(data);return false;}
   for(const key of keys){const canonical=doc.getElementById("p-"+key),serialized=JSON.stringify(data.controls[key]);if(canonical&&canonical.value!==serialized)canonical.value=serialized;}
   const focusEta=focus?params[keys[focus.edge]][focus.index]?.eta:undefined;selected=focus?{edge:focus.edge,eta:focusEta}:selected;if(!keepTables)setTables(data.controls);render(data);notifyDraftEdits(data.controls);if(view.dialog?.open)view.refresh();if(focus)tableFocus(focus.edge,data.controls[keys[focus.edge]].findIndex(p=>p.eta===focusEta),focus.field);return true;
  }
  function endDrag(cancel=false){if(!drag)return;const previous=drag;drag=null;try{svg.releasePointerCapture(previous.pointerId);}catch(_){}svg.classList.remove("dragging");if(cancel||locked()){setTables(previous.original);render(deriveData(previous.original));}else if(config.editInvalid){editDraft(previous.latest);}else if(!commit(previous.latest)){setTables(previous.original);render(deriveData(previous.original),{message:"Move was not applied. "+deriveData(previous.latest).error});}}
  function pointerReader(){const inverse=svg.getScreenCTM().inverse(),placement=viewport?.capture().viewport||{x:0,y:0,scale:1};return event=>({x:(inverse.a*event.clientX+inverse.c*event.clientY+inverse.e-placement.x)/placement.scale,y:(inverse.b*event.clientX+inverse.d*event.clientY+inverse.f-placement.y)/placement.scale});}
  svg.addEventListener("pointerdown",event=>{
   const target=event.target.closest("[data-edge]");if(!target||event.button!==0||event.ctrlKey||event.metaKey||locked())return;
   const params=readDrafts(),data=deriveData(params);if(!canDraw(data))return;
   const edge=Number(target.dataset.edge),eta=Number(target.dataset.eta),index=params[keys[edge]].findIndex(p=>p.eta===eta),vertex=data.edgeVertices[keys[edge]].find(p=>p.eta===eta);if(index<0||!vertex)return;
   event.preventDefault();selected={edge,eta};const transform=makeTransform(data);
   // Capture the grab offset and drawing geometry once. Wide hit targets and
   // text labels must move the point by the mouse displacement, never snap it
   // to the cursor. Freeze the screen-to-drawing map too: a validation warning
   // can resize the SVG while held, without changing the gesture coordinates.
   const readPointer=pointerReader();drag={pointerId:event.pointerId,index,edge,original:params,latest:params,data,transform,readPointer,start:readPointer(event),anchor:transform.map(vertex.position)};
   svg.setPointerCapture(event.pointerId);svg.classList.add("dragging");render(data,{fixed:drag.transform});
  });
  svg.addEventListener("pointermove",event=>{
   if(!drag||event.pointerId!==drag.pointerId)return;if(locked()){endDrag(true);return;}
   const local=drag.readPointer(event),dx=local.x-drag.start.x,dy=local.y-drag.start.y,params={...drag.original};
   for(const key of keys)params[key]=drag.original[key].map(p=>({...p}));
   const point=params[keys[drag.edge]][drag.index];
   if(dx!==0||dy!==0){
    const value=drag.transform.unmap(drag.anchor[0]+dx,drag.anchor[1]+dy),eta=dx===0?point.eta:Math.max(0,Math.min(1,value.eta)),baseChord=drag.data.rootChord*(1-(1-drag.data.taper)*eta),baseLE=drag.data.points.rootLE[0]+eta*(drag.data.points.tipLE[0]-drag.data.points.rootLE[0]);
    point.eta=eta;point.dxc=(value.x-baseLE)/baseChord-nominalPointXc(keys[drag.edge],drag.original);
   }
   selected.eta=point.eta;drag.latest=params;const data=deriveData(params);
   if(canDraw(data))render(data,{fixed:drag.transform});else{render(drag.data,{fixed:drag.transform,message:data.error});const g=doc.createElementNS("http://www.w3.org/2000/svg","circle");g.setAttribute("cx",String(drag.anchor[0]+dx));g.setAttribute("cy",String(drag.anchor[1]+dy));g.setAttribute("r","10");g.setAttribute("class","pf-invalid-point");(svg.querySelector("[data-svgview-geometry]")||svg).appendChild(g);viewport?.refresh();}
  });
  svg.addEventListener("pointerup",()=>endDrag());svg.addEventListener("pointercancel",()=>endDrag(true));svg.addEventListener("lostpointercapture",()=>{if(drag)endDrag(true);});
  svg.addEventListener("keydown",event=>{if(event.key==="Escape"&&drag){event.preventDefault();endDrag(true);return;}const target=event.target.closest("[data-edge]");if(!target||locked())return;const edge=Number(target.dataset.edge),params=readDrafts(),index=params[keys[edge]].findIndex(p=>p.eta===Number(target.dataset.eta));if(event.key==="Enter"){event.preventDefault();tableFocus(edge,index);return;}if(!["ArrowLeft","ArrowRight","ArrowUp","ArrowDown"].includes(event.key))return;event.preventDefault();const p=params[keys[edge]][index],step=event.shiftKey?.05:.005;if(event.key==="ArrowLeft"||event.key==="ArrowRight")p.eta=Math.max(0,Math.min(1,p.eta+(event.key==="ArrowRight"?step:-step)));else p.dxc+=event.key==="ArrowDown"?step:-step;selected={edge,eta:p.eta};if(editDraft(params)){svg.querySelector(`[data-edge="${edge}"][data-eta="${p.eta}"]`)?.focus();}});
  const cancelKey=event=>{if(event.key==="Escape"&&drag){event.preventDefault();endDrag(true);}};doc.addEventListener("keydown",cancelKey);
  host.addEventListener("parameterlockchange",()=>{endDrag(true);setTables(read());refresh();notifiedDrafts=Object.fromEntries(keys.map(key=>[key,JSON.stringify(readDrafts()[key])]));});
  setTables(read());refresh();notifyDraftEdits(readDrafts());
  return{section,sticky,viewport,captureView:()=>viewport?.capture(),restoreView:value=>viewport?.restore(value),readDrafts,refresh,setContextError(message){contextError=message||"";refresh();},destroy(){endDrag(true);viewport?.destroy();doc.removeEventListener("keydown",cancelKey);},externalChange(key){if(drag)endDrag(true);if(keys.includes(key)){setTables(read());notifiedDrafts=Object.fromEntries(keys.map(key=>[key,JSON.stringify(readDrafts()[key])]));}refresh();},validate(){return deriveData(readDrafts());},assertValidDraft(){const data=deriveData(readDrafts());if(!data.valid){render(data);throw new Error((config.name||"Planform")+": "+data.error);}if(!locked())commit(readDrafts(),null,true);return data;}};
 }
 function install(host,options){
  const doc=host.ownerDocument;if(host.querySelector(".planform-view-open"))return;
  let view=instances.get(doc);
  if(!view){
   const dialog=doc.createElement("dialog");dialog.id="planform-view-dialog";dialog.className="planform-view-dialog";dialog.setAttribute("aria-labelledby","planform-view-title");
   dialog.innerHTML='<div class="planform-view-header"><div><h2 id="planform-view-title">Dimensioned plan view</h2><p>Current form values · read-only reference geometry</p></div><button id="planform-view-close" type="button" aria-label="Close planform diagram">Close</button></div><p id="planform-view-error" class="planform-view-error" role="alert" hidden></p><div id="planform-view-content"><div class="planform-view-options"><label><input id="planform-view-mirror" type="checkbox"> Show mirrored half for full-span context</label><span>Dimensions in metres</span></div><div class="planform-view-layout"><div class="planform-view-canvas"><svg id="planform-view-svg" viewBox="0 0 1000 630" role="img" aria-label="Dimensioned base and refined planform, reference sweep line, box end and FE axes"></svg></div><aside id="planform-view-values" aria-label="Derived planform dimensions"></aside></div><p class="planform-view-note">The dashed outline is the untwisted base trapezoid used to define area and aspect ratio; the solid outline includes the edge perturbations. The structural skins and nose follow the refined surface. Spar reference paths are defined independently in base-trapezoid coordinates in Box; spar heights and attached skins follow the refined surface. The FE box ends at the selected box station; the aerodynamic/reference half-wing continues to the tip. The other half is mirrored context. Dihedral changes reference-line height; twist and airfoil thickness change the 3D loft without redefining reference area or span.</p><p class="planform-view-note">R is the base trapezoid root reference point at the chosen sweep x/c. The chord dimensions and sweep line refer to this base trapezoid; the table lists refined dimensions separately. The diagram includes its global offsets. Edit the trapezoid and perturbation points in the Planform pane; this window updates from those values.</p></div>';
   doc.body.appendChild(dialog);
   const svg=dialog.querySelector("svg"),error=dialog.querySelector("#planform-view-error"),content=dialog.querySelector("#planform-view-content"),values=dialog.querySelector("#planform-view-values"),mirror=dialog.querySelector("#planform-view-mirror");
   mirror.autocomplete="off";mirror.defaultChecked=false;mirror.checked=false;
   view={dialog,readValues:null,button:null,data:null,refresh(){
    let data;try{data=derive(view.readValues());}catch(e){data={valid:false,error:e.message};}view.data=data;error.hidden=data.valid;content.hidden=!data.valid;error.textContent=data.valid?"":"Cannot draw this planform. "+data.error;
    if(!data.valid){svg.replaceChildren();values.replaceChildren();return;}
    svg.innerHTML=drawing(data,{mirror:mirror.checked});values.replaceChildren();
    const heading=doc.createElement("h3");heading.textContent="Reference dimensions";values.appendChild(heading);
    const rows=[["Base full wing area",number(data.area)+" m²"],["Refined full wing area",number(data.actualArea)+" m\u00b2"],["Refined half area",number(data.actualHalfArea)+" m²"],["Base aspect ratio",number(data.aspectRatio)],["Refined aspect ratio",number(data.actualAspectRatio)],["Base taper ratio",number(data.taper)],["Refined taper ratio",number(data.actualTaper)],["Full projected span",number(data.span)+" m"],["Projected half-span",number(data.semispan)+" m"],["Base root / tip chord",number(data.rootChord)+" / "+number(data.tipChord)+" m"],["Refined root / tip chord",number(data.actualRootChord)+" / "+number(data.actualTipChord)+" m"],["Refined mean aero. chord",number(data.actualMAC)+" m"],["Reference-line sweep",number(data.sweepDeg)+"° at x/c "+number(data.sweepRef)],["Root R (x, y, z)",data.points.rootReference.map(number).join(", ")+" m"],["Tip reference (x, y, z)",data.points.tipReference.map(number).join(", ")+" m"],["Dihedral / tip twist",number(data.dihedralDeg)+"° / "+number(data.twistTipDeg)+"°"],["Box end",data.boxEnd?number(100*data.boxEnd.eta)+"% of half-span":"Not specified"]];
    const table=doc.createElement("table");for(const [key,value]of rows){const tr=doc.createElement("tr"),th=doc.createElement("th"),td=doc.createElement("td");th.textContent=key;td.textContent=value;tr.append(th,td);table.appendChild(tr);}values.appendChild(table);
   }};
   dialog.querySelector("#planform-view-close").onclick=()=>dialog.close();mirror.onchange=()=>view.refresh();
   dialog.addEventListener("close",()=>view.button?.isConnected&&view.button.focus());
   dialog.addEventListener("click",event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)dialog.close();}});
   for(const event of ["input","change"])doc.addEventListener(event,e=>{const key=PARAM_KEYS.find(key=>e.target?.id==="p-"+key);if(key){view.editor?.externalChange(key);if(dialog.open)view.refresh();}});
   instances.set(doc,view);
  }
  view.readValues=options.readValues;
  view.editor?.destroy();const editor=createEditor(host,options,view);view.editor=editor;view.readValues=editor.readDrafts;
  const button=doc.createElement("button");button.type="button";button.className="planform-view-open";button.id="btn-planform-view";button.dataset.parameterLockExempt="true";button.textContent="Dimensioned plan view";button.setAttribute("aria-haspopup","dialog");button.setAttribute("aria-controls","planform-view-dialog");
  if(options.openDimensionedView){button.removeAttribute("aria-haspopup");button.removeAttribute("aria-controls");button.textContent="Dimensioned plan view ↗";button.title="Open a synchronized drawing in a separate browser tab; move it to another monitor.";}
  button.onclick=()=>{if(options.openDimensionedView){options.openDimensionedView();return;}view.button=button;view.refresh();if(!view.dialog.open)view.dialog.showModal();view.dialog.querySelector("#planform-view-close").focus();};
  editor.sticky.querySelector(".planform-editor-toolbar").appendChild(button);
  if(view.dialog.open){view.button=button;view.refresh();}return editor;
 }
 return{PARAM_KEYS,POINT_KEYS,nominalPointXc,normalizePointRows,normalizePointParams,migratePointParams,derive,drawing,editorTransform,editorDrawing,createPointEditor:createEditor,install};
});
