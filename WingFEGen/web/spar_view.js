/* Independent structural spar paths, defined in the base trapezoid chord. */
(function(root,factory){const api=factory(root,typeof module==="object"&&module.exports?require("./planform_view.js"):root.WingPlanformView);if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSparView=api;})(typeof globalThis!=="undefined"?globalThis:this,function(root,P){
 "use strict";
 const POINT_KEYS=["box.front_spar_points","box.rear_spar_points"],ANCHOR_KEYS=["box.front_spar_xc","box.rear_spar_xc"];
 const PARAM_KEYS=[...P.PARAM_KEYS,...ANCHOR_KEYS,...POINT_KEYS,"box.stringer_angle"],views=new WeakMap();
 const number=value=>root.WingNumbers?root.WingNumbers.format(value,6):Number(value.toPrecision(6)).toString();
 function sample(data,edge,eta){
  const vertices=data.edgeVertices[POINT_KEYS[edge]];if(!vertices||!Number.isFinite(eta)||eta<0||eta>1)throw new Error("Spar samples need edge 0 or 1 and eta between 0 and 1.");
  let i=1;while(i<vertices.length-1&&vertices[i].eta<eta)i++;const a=vertices[i-1],b=vertices[i],f=(eta-a.eta)/(b.eta-a.eta),c=data.rootChord*(1-(1-data.taper)*eta),untouched=data.controls[POINT_KEYS[edge]].length===0,q=untouched?data.anchors[edge]*c:a.q+f*(b.q-a.q),xc=untouched?data.anchors[edge]:q/c,reference=data.points.rootReference;
  return{eta,xc,q,position:[reference[0]+eta*data.semispan*Math.tan(data.sweepDeg*Math.PI/180)+(xc-data.sweepRef)*c,reference[1]+eta*data.semispan,reference[2]+eta*data.semispan*Math.tan(data.dihedralDeg*Math.PI/180)]};
 }
 function derive(params){
  const data=P.derive(params);if(!data.valid&&!data.drawable)return data;
  // Finite paths remain useful for editing even when they are not meshable.
  // Keep validation strict, but return their geometry with the error below.
  const errors=data.valid?[]:[data.error],invalid=data.valid?[]:data.invalid.slice();
  const report=(message,keys)=>{errors.push(message);invalid.push(...keys);};
  const anchors=ANCHOR_KEYS.map(k=>params[k]);
  if(!anchors.every(v=>typeof v==="number"&&Number.isFinite(v)))return{valid:false,error:"Base spar locations must be finite numbers.",invalid:ANCHOR_KEYS.slice()};
  if(!(anchors[0]>0&&anchors[0]<anchors[1]&&anchors[1]<1))report("Base spar locations must satisfy 0 < front spar x/c < rear spar x/c < 1.",ANCHOR_KEYS);
  const chord=eta=>data.rootChord*(1-(1-data.taper)*eta),at=(eta,xc)=>{const reference=data.points.rootReference;return[reference[0]+eta*data.semispan*Math.tan(data.sweepDeg*Math.PI/180)+(xc-data.sweepRef)*chord(eta),reference[1]+eta*data.semispan,reference[2]+eta*data.semispan*Math.tan(data.dihedralDeg*Math.PI/180)];};
  const controls={},edgeVertices={};
  for(let e=0;e<POINT_KEYS.length;e++){
   const key=POINT_KEYS[e],label=e===0?"Front spar":"Rear spar",raw=params[key]===undefined?[]:params[key];
   let rows;try{rows=P.normalizePointRows(raw,key,params);}catch(error){return{valid:false,error:error.message,invalid:[key]};}controls[key]=rows;
   const vertices=rows.slice();if(!vertices.some(p=>p.eta===0))vertices.unshift({eta:0,dxc:0});if(!vertices.some(p=>p.eta===1))vertices.push({eta:1,dxc:0});
   edgeVertices[key]=vertices.map(p=>({...p,xc:anchors[e]+p.dxc,q:(anchors[e]+p.dxc)*chord(p.eta),position:at(p.eta,anchors[e]+p.dxc)}));
  }
  const geometry={...data,edgeVertices,controls,anchors},sampleAt=(edge,eta)=>sample(geometry,edge,eta),endEta=params["box.end_eta"]===undefined?1:params["box.end_eta"];
  const edgeOffset=(edge,eta)=>{const v=data.edgeVertices[P.POINT_KEYS[edge]];let i=1;while(i<v.length-1&&v[i].eta<eta)i++;const a=v[i-1],b=v[i],f=(eta-a.eta)/(b.eta-a.eta);return a.delta+f*(b.delta-a.delta);};
  const breaks=[...new Set([0,endEta,...Object.values(edgeVertices).flat().map(p=>p.eta),...Object.values(data.edgeVertices).flat().map(p=>p.eta)])].sort((a,b)=>a-b),stations=breaks.map(eta=>{const leading=edgeOffset(0,eta),trailing=chord(eta)+edgeOffset(1,eta),front=sampleAt(0,eta),rear=sampleAt(1,eta);return{eta,front,rear,leading,trailing,surfaceFront:(front.q-leading)/(trailing-leading),surfaceRear:(rear.q-leading)/(trailing-leading)};});
  if(stations.some(s=>s.eta<=endEta&&!(s.leading<s.front.q&&s.front.q<s.rear.q&&s.rear.q<s.trailing)))report("Within the modeled box, both spars must remain inside the refined wing surface without crossing or touching. Change the spar points or the wing outline.",[...POINT_KEYS,...P.POINT_KEYS]);
  const stringerSegments=[],rearPoints=controls[POINT_KEYS[1]],rearVertices=edgeVertices[POINT_KEYS[1]];
  if(rearPoints.length)for(let i=1;i<rearVertices.length;i++){
   const a=rearVertices[i-1],b=rearVertices[i],explicit=rearPoints.find(p=>p.eta===b.eta),angle=explicit?explicit.stringer_angle:rearPoints.at(-1).stringer_angle,dy=(b.eta-a.eta)*data.semispan,dx=dy*Math.tan(data.sweepDeg*Math.PI/180)-data.sweepRef*(chord(b.eta)-chord(a.eta))+b.q-a.q,datumAngle=Math.atan2(dx,dy)*180/Math.PI,absoluteAngle=datumAngle+angle,active=a.eta<endEta;
   if(active&&!(Number.isFinite(absoluteAngle)&&Math.abs(absoluteAngle)<89))report(`Rear-spar stringer angle on eta ${number(a.eta)} to ${number(b.eta)} gives an absolute direction of ${number(absoluteAngle)} degrees; its magnitude must be below 89 degrees.`,[POINT_KEYS[1]]);
   stringerSegments.push({startEta:a.eta,endEta:b.eta,angle,datumAngle,absoluteAngle,active});
  }else{
   const angle=params["box.stringer_angle"]===undefined?0:params["box.stringer_angle"],slope=Math.tan(data.sweepDeg*Math.PI/180)+(anchors[1]-data.sweepRef)*(data.tipChord-data.rootChord)/data.semispan,datumAngle=Math.atan(slope)*180/Math.PI,absoluteAngle=datumAngle+angle;
   if(typeof angle!=="number"||!Number.isFinite(angle)||!Number.isFinite(absoluteAngle)||Math.abs(absoluteAngle)>=89)report("The global stringer angle gives an absolute direction at or beyond 89 degrees to the span axis.",["box.stringer_angle"]);
   stringerSegments.push({startEta:0,endEta:1,angle,datumAngle,absoluteAngle,active:true});
  }
  const activeVertices={};
  for(let edge=0;edge<2;edge++){const key=POINT_KEYS[edge];activeVertices[key]=edgeVertices[key].filter(p=>p.eta<endEta).concat(sampleAt(edge,endEta));}
  const right=[...activeVertices[POINT_KEYS[0]].map(p=>p.position),...activeVertices[POINT_KEYS[1]].slice().reverse().map(p=>p.position)],sparEnd={eta:endEta,front:sampleAt(0,endEta),rear:sampleAt(1,endEta)},rootWidth=(sampleAt(1,0).xc-sampleAt(0,0).xc)*data.rootChord,endWidth=sparEnd.rear.q-sparEnd.front.q;
  const all=[...data.right,...data.baseRight,...Object.values(edgeVertices).flat().map(p=>p.position)];const bounds={...data.bounds,xmin:Math.min(...all.map(p=>p[0])),xmax:Math.max(...all.map(p=>p[0]))};
  if(!all.flat().every(Number.isFinite)||!Number.isFinite(bounds.xmax-bounds.xmin))return{valid:false,error:"Spar points cannot be represented at these magnitudes.",invalid:POINT_KEYS.slice()};
  return{...data,valid:errors.length===0,drawable:true,error:errors[0]||"",invalid:[...new Set(invalid)],controls,edgeVertices,activeVertices,stations,sparEnd,rootWidth,endWidth,anchors,right,stringerSegments,surfaceRight:data.right,surfaceVertices:data.edgeVertices,bounds,basis:"Independent base-chord spar reference paths inside the refined wing surface"};
 }
 function drawing(data,{transform=P.editorTransform(data),selected=null,locked=false,pointOrder=null}={}){
  if(!data.valid&&!data.drawable)return"";const map=transform.map,poly=(p,cls)=>`<polygon points="${p.map(v=>map(v).join(",")).join(" ")}" class="${cls}"/>`,line=(p,cls)=>`<polyline points="${p.map(v=>map(v.position).join(",")).join(" ")}" class="${cls}"/>`;
  let svg='<title>Independent front and rear spar reference paths with the refined wing surface</title><desc>Drag spar points or edit their eta and delta x/c offsets. The actual skin and spar heights follow the refined surface; the reference paths stay independent.</desc>'+poly(data.surfaceRight,"sf-surface")+poly(data.baseRight,"pf-base")+poly(data.right,"sf-box");
  for(let edge=0;edge<2;edge++){
   const key=POINT_KEYS[edge],name=edge===0?"Front":"Rear",prefix=edge===0?"F":"R";
   svg+=line(data.edgeVertices[key],`sf-spar sf-${edge===0?"front":"rear"} sf-extension`)+line(data.activeVertices[key],`sf-spar sf-${edge===0?"front":"rear"}`);
   for(let i=0;i<data.controls[key].length;i++){
    const p=data.controls[key][i],v=data.edgeVertices[key].find(q=>q.eta===p.eta),xy=map(v.position),active=selected?.edge===edge&&selected?.eta===p.eta,order=pointOrder?.[key]?.findIndex(q=>q.eta===p.eta),label=order>=0?order:i;
    svg+=`<g class="pf-point sf-point sf-${edge===0?"front":"rear"}${active?" pf-selected":""}" data-edge="${edge}" data-index="${i}" data-eta="${p.eta}" tabindex="${locked?-1:0}" role="button" aria-disabled="${locked}" aria-label="${name} spar point ${label+1}: eta ${number(p.eta)}, delta x/c ${number(p.dxc)}.${edge===1?" Stringer angle "+number(p.stringer_angle)+" degrees.":""} Arrow keys move; Enter focuses table."><circle class="pf-point-hit" cx="${xy[0]}" cy="${xy[1]}" r="17"/><circle class="pf-point-dot" cx="${xy[0]}" cy="${xy[1]}" r="7"/><text x="${xy[0]+12}" y="${xy[1]+(edge===0?-12:22)}">${prefix}${label+1}</text></g>`;
   }
  }
  const a=map(data.sparEnd.front.position),b=map(data.sparEnd.rear.position);svg+=`<line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" class="pf-box-end"/><text x="${b[0]-8}" y="${b[1]+24}" text-anchor="end" class="sf-end-label">Box end η ${number(data.sparEnd.eta)}</text>`;
  svg+=`<text x="30" y="22" class="pf-editor-axis">+x aft ↓</text><text x="730" y="304" text-anchor="end" class="pf-editor-axis">+y toward tip →</text><text x="${transform.left}" y="304" class="pf-editor-axis">η = 0</text><text x="${transform.left+data.semispan*transform.scale}" y="325" text-anchor="end" class="pf-editor-axis">η = 1</text>`;return svg;
 }
 function install(host,options){
  const doc=host.ownerDocument;let view=views.get(doc);
  if(!view){view={editor:null};for(const event of ["input","change"])doc.addEventListener(event,e=>{const key=PARAM_KEYS.find(k=>e.target?.id==="p-"+k);if(key)view.editor?.externalChange(key);});views.set(doc,view);}
  view.editor?.destroy();view.editor=P.createPointEditor(host,options,view,{pointKeys:POINT_KEYS,derive,drawing,editInvalid:true,name:"Spar paths",className:"spar-editor",svgId:"spar-editor-svg",edgeNames:["Front spar","Rear spar"],prefixes:["F","R"],extraFields:[[],[{key:"stringer_angle",label:"Stringer angle (deg)",default:0,help:"Incoming segment: preceding rear point (or root) to this point. The final angle continues from the final point to the tip, relative to that rear-spar segment."}]],fieldDisabled:(edge,field,point,rows)=>edge===1&&field==="stringer_angle"&&point?.eta===0&&rows.some(p=>p.eta>0)?"Unused root angle: the next positive-eta point defines the incoming segment. A sole root point defines the full span.":"",edgeHelp:["","Each angle applies from the preceding point (or root) to this point, relative to that rear-spar segment. After the final point, its angle continues toward the tip relative to the final segment. New points default to 0 degrees. A root-point angle is used only when it is the sole rear point; otherwise its field is disabled."],onRender:params=>{const legacy=doc.getElementById("row-box.stringer_angle");if(legacy)legacy.hidden=(params[POINT_KEYS[1]]||[]).length>0;},emptyText:"No perturbations: follows the base spar location.",legend:'<i class="sf-front"></i>Front <i class="sf-rear"></i>Rear <i class="surface"></i>Wing surface <i class="base"></i>Base trapezoid',metrics:(data,locked)=>`Root box width ${number(data.rootWidth)} m · End width ${number(data.endWidth)} m${locked?" · Mesh parameters locked":""}`,helpStart:'This is the untwisted reference plan view. Define the base spar positions below, then refine each path with points. <b>η</b> is the fraction of the projected half-span. <b>\u0394x/c</b> is the offset from the corresponding nominal spar location, measured in <em>base trapezoid</em> chord fractions: 0 follows the nominal spar, +0.2 moves aft and -0.2 forward by 20% of the chord. Offsets follow changes to the nominal spar and the base trapezoid. The structural skins, nose and spar heights follow the refined wing surface. Both spars must fit inside that surface throughout the modeled box.',helpEnd:'Straight segments join spar points in physical space. Missing root/tip points have zero offset from the nominal spar locations. The solid paths stop at Box end η; dashed extensions show the definition toward the tip. Drag a point, use the tables, or use arrow keys (Shift for larger steps), Enter for the table, and Escape to cancel a drag. The <b>Mesh lock</b> protects these parameters.'});return view.editor;
 }
 return{POINT_KEYS,PARAM_KEYS,derive,sample,drawing,install};
});
