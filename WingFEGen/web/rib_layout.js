/* Physical master/secondary rib layout and live reference-plan editors. */
(function(root,factory){const common=typeof module==="object"&&module.exports,api=factory(root,common?require("./spar_view.js"):root.WingSparView,common?require("./planform_view.js"):root.WingPlanformView);if(common)module.exports=api;else root.WingRibLayout=api;})(globalThis,function(root,Spar,Planform){
 "use strict";
 const KEY="ribs.masters",LE_KEY="leading_edge.rib_orientations",RAD=Math.PI/180;
 const PARAM_KEYS=[...new Set([...Spar.PARAM_KEYS,"box.rib_pitch",KEY,LE_KEY,"leading_edge.enabled","leading_edge.start_rib","leading_edge.end_rib","leading_edge.disabled_bays","leading_edge.rib_orientation","leading_edge.rib_angle"])];
 const number=v=>Number.isFinite(v)?root.WingNumbers?root.WingNumbers.format(v,5):Number(v.toPrecision(6)).toString():"";
 const roundEven=v=>{const n=Math.floor(v);return v-n===.5?(n%2===0?n:n+1):Math.round(v);};
 const clone=v=>JSON.parse(JSON.stringify(v));
 function normalizeMasters(raw,endEta){
  if(raw===undefined)raw=[];if(!Array.isArray(raw)||raw.length>100)throw Error("Use at most 100 intermediate master ribs.");
  const rows=raw.map(row=>{
   if(!row||typeof row!=="object"||Array.isArray(row)||Object.keys(row).sort().join(",")!=="angle,eta,mode,pitch")throw Error("Each master rib needs eta, mode, angle and pitch.");
   if(typeof row.eta!=="number"||!Number.isFinite(row.eta)||row.eta<=0||row.eta>=endEta)throw Error("Intermediate master eta must lie between root 0 and the box End ETA.");
   if(!["flight_direction","rear_spar_angle"].includes(row.mode))throw Error("Choose flight direction or rear-spar angle for each master.");
   if(typeof row.angle!=="number"||!Number.isFinite(row.angle)||row.angle<=0||row.angle>=180||typeof row.pitch!=="number"||!Number.isFinite(row.pitch)||row.pitch<=0)throw Error("Master angles must be between 0 and 180 degrees, and outgoing rib pitches positive.");
   return{eta:row.eta,mode:row.mode,angle:row.angle,pitch:row.pitch};
  }).sort((a,b)=>a.eta-b.eta);
  const anchors=[0,...rows.map(r=>r.eta),endEta];if(anchors.some((eta,i)=>i&&eta-anchors[i-1]<=1e-10))throw Error("Master rib eta positions must be distinct, separated by more than 1e-10, including the fixed endpoints.");return rows;
 }
 function normalizeOrientations(raw){
  if(raw===undefined)raw=[];if(!Array.isArray(raw)||raw.length>100)throw Error("Use no more than 100 leading-edge rib overrides.");
  const rows=raw.map(row=>{if(!row||typeof row!=="object"||Object.keys(row).sort().join(",")!=="angle,mode,rib"||!Number.isSafeInteger(row.rib)||row.rib<1||row.rib>100001||!["flight_direction","front_spar_angle"].includes(row.mode)||typeof row.angle!=="number"||!Number.isFinite(row.angle)||row.angle<=0||row.angle>=180)throw Error("Each leading-edge override needs a rib number between 1 and 100001, a direction and an angle between 0 and 180 degrees.");return{rib:row.rib,mode:row.mode,angle:row.angle};}).sort((a,b)=>a.rib-b.rib);
  if(rows.some((r,i)=>i&&r.rib===rows[i-1].rib))throw Error("A physical rib can have only one leading-edge direction override.");return rows;
 }
 function geometry(params){const p={...params,"box.stringer_angle":0};if(Array.isArray(p["box.rear_spar_points"]))p["box.rear_spar_points"]=p["box.rear_spar_points"].map(row=>({...row,stringer_angle:0}));return Spar.derive(p);}
 function tangent(data,edge,eta=0){
  const points=data.edgeVertices[Spar.POINT_KEYS[edge]];let i=1;while(i<points.length-1&&points[i].eta<eta)i++;
  const a=points[i-1].position,b=points[i].position,dx=b[0]-a[0],dy=b[1]-a[1],length=Math.hypot(dx,dy);return[dx/length,dy/length];
 }
 function masterDelta(data,master){
  if(master.mode==="flight_direction")return 0;
  const [tx,ty]=tangent(data,1,master.eta),a=master.angle*RAD,dx=tx*Math.cos(a)-ty*Math.sin(a),dy=tx*Math.sin(a)+ty*Math.cos(a),delta=Math.atan2(dy,-dx);
  if(!(dx<0&&Math.abs(delta)<85*RAD))throw Error("Master rib angles must point toward the front spar and stay within 85 degrees of flight direction.");return delta;
 }
 function arc(data,a,b){
  const etas=[a,...data.edgeVertices[Spar.POINT_KEYS[1]].map(p=>p.eta).filter(eta=>eta>a&&eta<b),b],pieces=[];let length=0;
  for(let i=1;i<etas.length;i++){const p=Spar.sample(data,1,etas[i-1]).position,q=Spar.sample(data,1,etas[i]).position,l=Math.hypot(...q.map((v,j)=>v-p[j]));pieces.push({a:etas[i-1],b:etas[i],start:length,length:l});length+=l;}
  return{length,etaAt(f){const distance=Math.min(1,Math.max(0,f))*length,piece=pieces.find(p=>distance<=p.start+p.length)||pieces.at(-1);return piece.a+(piece.b-piece.a)*(distance-piece.start)/piece.length;}};
 }
 function physical(params){
  const area=params["planform.area"],ar=params["planform.aspect_ratio"],dihedral=params["planform.dihedral"],endEta=params["box.end_eta"],pitch=params["box.rib_pitch"];
  try{
   if(![area,ar,dihedral,endEta,pitch].every(v=>typeof v==="number"&&Number.isFinite(v))||area<=0||ar<=0||pitch<=0||endEta<=0||endEta>1||Math.abs(dihedral)>=89)throw Error("Set valid wing dimensions, box End ETA and a positive root rib pitch.");
   const rows=normalizeMasters(params[KEY],endEta),masters=[{eta:0,mode:"flight_direction",angle:90,pitch,fixed:true},...rows.map((r,i)=>({...r,row:i,fixed:false})),{eta:endEta,mode:"flight_direction",angle:90,pitch:null,fixed:true}],intervals=[];
   let data=null,bayCount=0;const errors=[];if(rows.length){data=geometry(params);if(!data.drawable&&!data.valid)throw Error(data.error);}
   const deltaFor=master=>{try{return data?masterDelta(data,master):0;}catch(error){errors.push(error.message);return 0;}};
   for(let i=1;i<masters.length;i++){
    const a=masters[i-1],b=masters[i],path=data?arc(data,a.eta,b.eta):null,length=path?path.length:Math.sqrt(area*ar)/2*Math.sqrt(1+Math.tan(dihedral*RAD)**2)*endEta,n=Math.max(1,roundEven(length/a.pitch));
    if(!Number.isSafeInteger(n)||length/a.pitch>100000||bayCount+n>100000)throw Error("Use no more than 100,000 physical rib bays in total or in any master interval.");
    a.number=bayCount+1;intervals.push({a,b,path,count:n,start:bayCount,deltaA:deltaFor(a),deltaB:deltaFor(b)});bayCount+=n;
   }
   masters.at(-1).number=bayCount+1;
   return{valid:errors.length===0,error:errors[0]||"",rows,masters,intervals,geometry:data,bayCount,ribCount:bayCount+1,endEta,at(index){
    if(!Number.isInteger(index)||index<1||index>bayCount+1)throw Error("Physical rib number is outside the box.");
    const interval=intervals.find(p=>index-1<=p.start+p.count)||intervals.at(-1),f=(index-1-interval.start)/interval.count,eta=interval.path?interval.path.etaAt(f):endEta*f,delta=interval.deltaA+(interval.deltaB-interval.deltaA)*f,master=masters.find(m=>m.number===index);
    return{number:index,eta,delta,direction:[-Math.cos(delta),Math.sin(delta),0],isMaster:!!master,master:master||null};
   }};
  }catch(error){return{valid:false,error:error.message,masters:[],intervals:[],bayCount:0,ribCount:0};}
 }
 function intersection(origin,direction,vertices,endEta=1){
  const hits=[];for(let i=1;i<vertices.length;i++){
   const a=vertices[i-1],b=vertices[i],p=a.position,q=b.position,ex=q[0]-p[0],ey=q[1]-p[1],den=direction[0]*ey-direction[1]*ex;if(Math.abs(den)<1e-14)continue;
   const px=p[0]-origin[0],py=p[1]-origin[1],t=(px*ey-py*ex)/den,u=(px*direction[1]-py*direction[0])/den,eta=a.eta+u*(b.eta-a.eta);
   if(t>=-1e-10&&u>=-1e-10&&u<=1+1e-10&&eta>=-1e-10&&eta<=endEta+1e-10&&!hits.some(h=>Math.abs(h.eta-eta)<1e-9))hits.push({eta:Math.max(0,Math.min(endEta,eta)),position:p.map((v,j)=>v+u*(q[j]-v)),distance:t});
  }return hits;
 }
 function derive(params,{maxRibs=2000,include=[]}={}){
  const data=geometry(params),layout=physical(params),result={...layout,geometry:data,drawable:!!(data.valid||data.drawable),ribs:[],error:layout.error||data.error||"",warning:"",valid:layout.valid&&data.valid};
  if(!layout.at||!result.drawable)return result;
  const indices=new Set([1,layout.ribCount,...layout.masters.map(m=>m.number),...include.filter(i=>Number.isInteger(i)&&i>=1&&i<=layout.ribCount)]),stride=Math.max(1,Math.ceil(layout.bayCount/maxRibs));
  for(let i=1;i<=layout.ribCount;i+=stride)indices.add(i);
  for(const index of [...indices].sort((a,b)=>a-b)){
   const rib=layout.at(index),rear=Spar.sample(data,1,rib.eta).position,hits=intersection(rear,rib.direction,data.edgeVertices[Spar.POINT_KEYS[0]],layout.endEta),hit=hits.length===1?hits[0]:null;
   const error=hit?"":`Rib ${index} must intersect the front spar exactly once within the box. Adjust its master position or angle.`;
   result.ribs.push({...rib,rear,front:hit?.position||Spar.sample(data,0,rib.eta).position,frontEta:hit?.eta??rib.eta,valid:!!hit,error});
   if(error)result.warning||=error;
  }
  for(let i=1;i<result.ribs.length;i++)if(result.ribs[i].frontEta<=result.ribs[i-1].frontEta+1e-12){result.warning||="Reference ribs cross or touch at the front spar. The mesh generator will validate the actual airfoil intersections.";result.ribs[i].valid=false;}
  if(result.warning)result.warning="Untwisted reference preview: "+result.warning+" Create FEM checks the actual surfaces.";
  result.sampledRibs=result.ribs.length<layout.ribCount;return applyGenerated(result,params._rib_geometry);
 }
 function applyGenerated(layout,payload){
  if(!payload||!Array.isArray(payload.ribs)||payload.ribs.length!==layout.ribCount)return layout;
  const point=p=>Array.isArray(p)&&p.length===3&&p.every(Number.isFinite),actual=new Map(payload.ribs.map(r=>[r.number,r]));
  if(layout.ribs.some(r=>{const q=actual.get(r.number);return!q||!point(q.front)||!point(q.rear)||Math.abs(q.eta-r.eta)>1e-8;}))return layout;
  return{...layout,generated:true,warning:"",ribs:layout.ribs.map(r=>{const q=actual.get(r.number);return{...r,valid:true,error:"",front:q.front,rear:q.rear,frontEta:q.front_eta,upper:q.upper,lower:q.lower,leading:point(q.leading)?q.leading:null,leFallback:!!q.le_fallback,leStatus:q.le_status||"Generated surface intersection",actual:q};})};
 }
 function leading(params,layout=derive(params)){
  let overrides;try{overrides=normalizeOrientations(params[LE_KEY]);}catch(error){return{...layout,valid:false,error:error.message};}
  const result={...layout,ribs:layout.ribs.map(r=>({...r})),overrides};if(!layout.drawable)return result;
  const data=layout.geometry,[tx,ty]=tangent(data,0),globalMode=params["leading_edge.rib_orientation"]||"flight_direction",globalAngle=params["leading_edge.rib_angle"]??90;
  if(params["leading_edge.enabled"]===true&&overrides.some(r=>r.rib>layout.ribCount)){result.valid=false;result.error||=`Leading-edge override numbers must be within ribs 1 to ${layout.ribCount}.`;}
  for(const rib of result.ribs){
   if(layout.generated&&rib.leading)continue;
   const row=overrides.find(r=>r.rib===rib.number),mode=row?.mode||globalMode,angle=row?.angle??globalAngle,a=angle*RAD,direction=mode==="flight_direction"?[-1,0,0]:[tx*Math.cos(a)-ty*Math.sin(a),tx*Math.sin(a)+ty*Math.cos(a),0],vertices=data.surfaceVertices[Planform.POINT_KEYS[0]],hits=intersection(rib.front,direction,vertices,layout.endEta);
   const fallback=hits.length===0,flight=fallback?intersection(rib.front,[-1,0,0],vertices,layout.endEta):hits,hit=flight.length===1?flight[0]:null;
   if(flight.length>1)result.warning||=`Untwisted leading-edge rib ${rib.number} has multiple reference intersections. Create FEM checks the actual surfaces.`;
   rib.leading=hit?.position||rib.front;rib.leadingEta=hit?.eta??rib.frontEta;rib.leOverride=!!row;rib.leMode=mode;rib.leAngle=angle;rib.leFallback=fallback;rib.leStatus=fallback?"No surface intersection: flight direction used":hit?"Reference intersection found":"No unique surface intersection";
  }return result;
 }
 function drawing(data,{selected=null,locked=false,transform=null}={}){
  if(!data.drawable)return"";const t=transform||Planform.editorTransform(data.geometry),map=t.map,poly=(points,cls)=>`<polyline class="${cls}" points="${points.map(p=>map(p).join(",")).join(" ")}"/>`;
  let svg='<title>Master ribs and interpolated physical ribs</title><desc>Drag intermediate master anchors on the rear spar. Drag the master rib line or a direction handle to change its orientation. Root and final ribs are fixed.</desc>'+`<polygon class="rl-box" points="${data.geometry.right.map(p=>map(p).join(",")).join(" ")}"/>`;
  for(const rib of data.ribs){const master=rib.isMaster,xy=map(rib.rear),front=map(rib.front);svg+=poly([rib.rear,rib.front],`rl-rib${master?" rl-master":""}${rib.valid?"":" rl-invalid"}`);
   if(master){const row=rib.master,editable=!row.fixed&&!locked,cls=selected===row.eta?" rl-selected":"";
    if(!row.fixed)svg+=`<line class="rl-line-handle" data-rib-eta="${row.eta}" data-rib-part="angle" x1="${xy[0]}" y1="${xy[1]}" x2="${front[0]}" y2="${front[1]}" role="button" tabindex="${locked?-1:0}" aria-disabled="${locked}" aria-label="Rotate master rib at eta ${number(row.eta)} by dragging this line"/>`;
    svg+=`<g data-rib-eta="${row.eta}" data-rib-part="anchor" class="rl-handle${cls}" role="button" tabindex="${editable?0:-1}" aria-disabled="${!editable}" aria-label="${row.fixed?row.eta===0?"Root master":"Final master":"Master at eta "+number(row.eta)}: move along rear spar"><circle cx="${xy[0]}" cy="${xy[1]}" r="7"/><text x="${xy[0]+10}" y="${xy[1]+17}">M${data.masters.indexOf(row)+1} / R${rib.number}</text></g>`;
    if(!row.fixed)svg+=`<g data-rib-eta="${row.eta}" data-rib-part="angle" class="rl-angle-handle${cls}" role="button" tabindex="${locked?-1:0}" aria-disabled="${locked}" aria-label="Master at eta ${number(row.eta)} orientation handle"><circle cx="${front[0]}" cy="${front[1]}" r="6"/></g>`;
   }
  }
  for(let edge=0;edge<2;edge++)svg+=poly(data.geometry.activeVertices[Spar.POINT_KEYS[edge]].map(p=>p.position),edge?"rl-rear":"rl-front");
  return svg;
 }
 function install(host,options={}){return editor(host,options,false);}
 function installLeadingEdge(host,options={}){return editor(host,options,true);}
 function editor(host,options,isLE){
  const doc=host.ownerDocument,key=isLE?LE_KEY:KEY,canonical=doc.getElementById("p-"+key);if(!canonical)return null;
  const section=doc.createElement("section");section.className="rib-layout-editor"+(isLE?" le-rib-editor":"");
  section.innerHTML=`<div class="rl-title"><h3>${isLE?"Individual leading-edge ribs":"Master rib layout"}</h3><button type="button" data-rl="help" aria-expanded="false" aria-label="Rib layout instructions">? Help</button></div>`+
   `<p class="rl-help" hidden>${isLE?"An override applies to one physical rib number. Unlisted ribs inherit the global direction below. Front-spar angles use the inboard front-spar datum; 90 degrees is perpendicular. A direction that misses the surface falls back to flight direction and is marked red. This live drawing is an untwisted reference preview; Create FEM confirms the actual airfoil intersections.":"Root and final master ribs stay at the box boundaries in flight direction. Add intermediate masters at their rear-spar eta. Each pitch sets the outgoing interval; secondary ribs divide its rear-spar distance evenly and interpolate the master directions. Drag a rear anchor to move a master. Drag the rib line or its round front handle to rotate it. Arrow keys provide small adjustments; Shift makes larger steps. Escape cancels a drag. Angles are measured from the local rear-spar segment immediately inboard of the master toward the nose; 90 degrees is perpendicular. This is an untwisted reference preview; the mesh generator uses the actual airfoil surfaces."}</p>`+
   `<div class="rl-preview"><svg id="${isLE?"leading-rib-editor-svg":"rib-layout-svg"}" viewBox="0 0 760 340" role="img" aria-label="${isLE?"Leading edge rib":"Master rib"} reference plan view"></svg><p class="rl-status" role="status"></p><p class="rl-error" role="alert" hidden></p></div><div class="rl-table-wrap"><table><thead><tr>${isLE?"<th>Rib</th>":"<th>Rib</th><th>Rear η</th>"}<th>Direction</th><th>Angle °</th>${isLE?"<th>Status</th>":"<th>Pitch m</th>"}<th></th></tr></thead><tbody></tbody></table></div><button type="button" data-rl="add">+ ${isLE?"Override rib":"Add master rib"}</button>`;
  host.appendChild(section);const tbody=section.querySelector("tbody"),svg=section.querySelector("svg"),error=section.querySelector(".rl-error"),status=section.querySelector(".rl-status"),add=section.querySelector('[data-rl="add"]');
  svg.dataset.viewKey=isLE?"leading-edge-ribs":"master-ribs";
  const viewport=globalThis.WingSVGViewport?.install(svg,{host:svg.parentElement,title:isLE?"Leading-edge ribs":"Master ribs",exportName:svg.dataset.viewKey+".svg",snapSelector:"polygon,polyline,.rl-leading,.rl-line-handle,.rl-handle circle,.rl-angle-handle circle",isGeometryTarget:target=>!!target.closest?.("[data-rib-part]"),onChange:options.onViewChange});
  if(!isLE)section.querySelector("th:nth-child(5)").title="Outgoing pitch in metres: physical ribs from this master to the next.";
  let rows=[],drag=null,destroyed=false,selected=null,lastCanonical="",lastData=null;
  const locked=()=>!!options.isLocked?.(),read=()=>{const params={...options.readValues?.()},generated=options.readGenerated?.();if(generated)params._rib_geometry=generated.rib_layout||generated;return params;},normalized=()=>isLE?normalizeOrientations(rows):normalizeMasters(rows,read()["box.end_eta"]),readDrafts=()=>{const params={...read(),[key]:rows.map(row=>({...row}))};let matches=false;try{const saved=JSON.parse(canonical.value);matches=JSON.stringify(normalized())===JSON.stringify(isLE?normalizeOrientations(saved):normalizeMasters(saved,params["box.end_eta"]));}catch(_){}if(drag||!matches)params._rib_geometry=null;return params;};
  const deriveDraft=()=>isLE?leading(readDrafts()):derive(readDrafts());
  function reload(){try{rows=JSON.parse(canonical.value||"[]");}catch(_){rows=[];}rows=Array.isArray(rows)?rows.map(r=>({...r})):[];lastCanonical=canonical.value;}
  function notify(){options.onEdit?.(key);}
  function commit(data=deriveDraft()){if(destroyed||!data?.valid||locked())return false;const json=JSON.stringify(normalized());if(canonical.value!==json){canonical.value=json;lastCanonical=json;}return true;}
  function field(value,name,index,type="number",disabled=false){const input=doc.createElement(type==="select"?"select":"input");input.dataset.field=name;input.dataset.row=String(index);input.setAttribute("aria-label",`${isLE?"Leading-edge":"Master"} row ${index+1} ${name}`);if(type==="select"){for(const [v,label]of[["flight_direction","Flight"],[isLE?"front_spar_angle":"rear_spar_angle",isLE?"Front angle":"Spar angle"]]){const option=doc.createElement("option");option.value=v;option.textContent=label;input.appendChild(option);}}else{input.type="number";input.step=name==="rib"?"1":"any";}input.value=value??"";input.disabled=disabled||locked();input.oninput=()=>{if(locked())return;rows[index][name]=type==="select"?input.value:input.value.trim()===""?NaN:Number(input.value);selected=rows[index].eta;const data=refresh(false);commit(data);notify();};input.onchange=()=>{if(name==="mode"){table();refresh(false);}else{const data=refresh(false);commit(data);}};return input;}
  function cell(row,content){const td=doc.createElement("td");if(typeof content==="string")td.textContent=content;else td.appendChild(content);row.appendChild(td);return td;}
  function table(){
   tbody.replaceChildren();const p=read();
   if(!isLE){const tr=doc.createElement("tr");tr.className="rl-fixed";cell(tr,"Root");cell(tr,"0");cell(tr,"Flight");cell(tr,"—");const input=field(p["box.rib_pitch"],"pitch",-1);input.setAttribute("aria-label","Root outgoing rib pitch in metres");input.oninput=()=>{const original=doc.getElementById("p-box.rib_pitch");if(!original||locked())return;original.value=input.value;options.onEdit?.("box.rib_pitch");refresh(false);};cell(tr,input);cell(tr,"—").title="Fixed endpoint";tbody.appendChild(tr);}
   rows.forEach((row,index)=>{const tr=doc.createElement("tr");tr.dataset.row=String(index);if(isLE)cell(tr,field(row.rib,"rib",index));else{cell(tr,"M"+(index+2)).className="rl-master-label";cell(tr,field(row.eta,"eta",index));}cell(tr,field(row.mode,"mode",index,"select"));cell(tr,field(row.angle,"angle",index,"number",row.mode==="flight_direction"));if(isLE){const td=cell(tr,"");td.className="rl-row-status";}else cell(tr,field(row.pitch,"pitch",index));const remove=doc.createElement("button");remove.type="button";remove.textContent="×";remove.setAttribute("aria-label",`Remove ${isLE?"leading-edge override":"master rib"} ${index+1}`);remove.disabled=locked();remove.onclick=()=>{if(locked())return;rows.splice(index,1);table();const data=refresh(false);commit(data);notify();};cell(tr,remove);tbody.appendChild(tr);});
   if(!isLE){const tr=doc.createElement("tr");tr.className="rl-fixed";for(const text of["Final",number(p["box.end_eta"]),"Flight","—","—","—"])cell(tr,text);tbody.appendChild(tr);}add.disabled=locked()||rows.length>=100;
  }
  function refresh(sync=true){if(destroyed)return null;if(sync&&!drag&&canonical.value!==lastCanonical){reload();table();}let data;try{data=deriveDraft();}catch(e){data={valid:false,drawable:false,error:e.message,ribs:[]};}lastData=data;error.hidden=data.valid&&!data.warning;error.classList.toggle("rl-warning",data.valid&&!!data.warning);error.textContent=data.error||data.warning||"";status.textContent=data.ribCount?`${data.ribCount} physical ribs · ${isLE?rows.length+" individual overrides":rows.length+2+" masters"} · ${data.generated?"Generated rib projection":"Untwisted reference preview"}${locked()?" · Mesh parameters locked":""}`:"Complete the dimensions and master definition to preview the ribs.";
   svg.innerHTML=drawing(data,{selected,locked:locked(),transform:drag?.transform});
   if(!isLE){const order=rows.map((row,index)=>({eta:row.eta,index})).sort((a,b)=>a.eta-b.eta);for(const cell of tbody.querySelectorAll(".rl-master-label")){const index=Number(cell.parentElement.dataset.row);cell.textContent="M"+(order.findIndex(row=>row.index===index)+2);}}
   if(isLE&&data.drawable){const map=Planform.editorTransform(data.geometry).map;for(const rib of data.ribs){const a=map(rib.front),b=map(rib.leading||rib.front);svg.insertAdjacentHTML("beforeend",`<line class="rl-leading${rib.leFallback?" rl-fallback":""}" data-leading-rib="${rib.number}" x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}"/>`);}for(const tr of tbody.querySelectorAll("tr[data-row]")){const row=rows[Number(tr.dataset.row)],rib=data.ribs.find(r=>r.number===row.rib),td=tr.querySelector(".rl-row-status");td.textContent=rib?rib.leFallback?"Flight fallback":"Override":"Out of range";td.classList.toggle("rl-fallback",!!rib?.leFallback);td.title=rib?.leStatus||"";}}
   if(data.drawable){const t=drag?.transform||Planform.editorTransform(data.geometry),o=t.map([0,0,0]);viewport?.setMetric?.({origin:{x:o[0],y:o[1]},x:{x:t.scale,y:0},y:{x:0,y:t.scale},unit:"m",gridSpacing:1});}
   viewport?.refresh();return data;
  }
  add.onclick=()=>{if(locked())return;const p=read();if(isLE){const used=new Set(rows.map(r=>r.rib));let rib=1;while(used.has(rib))rib++;rows.push({rib,mode:p["leading_edge.rib_orientation"]||"flight_direction",angle:p["leading_edge.rib_angle"]??90});}else{const end=p["box.end_eta"],etas=[0,...rows.map(r=>r.eta).filter(v=>Number.isFinite(v)&&v>0&&v<end),end].sort((a,b)=>a-b);let best=0;for(let i=1;i<etas.length-1;i++)if(etas[i+1]-etas[i]>etas[best+1]-etas[best])best=i;rows.push({eta:(etas[best]+etas[best+1])/2,mode:"flight_direction",angle:90,pitch:p["box.rib_pitch"]||.6});}table();const data=refresh(false);commit(data);notify();tbody.querySelector('tr[data-row="'+(rows.length-1)+'"] input')?.focus();};
  const local=event=>{if(viewport)return viewport.toDrawingPoint(event);const p=svg.createSVGPoint();p.x=event.clientX;p.y=event.clientY;return p.matrixTransform(svg.getScreenCTM().inverse());};
  function modify(part,index,point,transform,data){
   const row=rows[index],original=drag.original[index];
   if(part==="anchor"){
    const step=Number(((point.x-drag.start.x)/(transform.scale*data.geometry.semispan)).toFixed(6));
    row.eta=step===0?original.eta:Math.max(.000001,Math.min(read()["box.end_eta"]-.000001,original.eta+step));
   }else{
    // Generated rib endpoints can differ from their untwisted parameter line.
    // Apply only the gesture's angular change about the displayed rear point.
    const x=point.y-drag.rear[1],y=point.x-drag.rear[0];if(Math.hypot(x,y)<1e-8)return;
    let delta=Math.atan2(y,x)-drag.pointerAngle;delta=Math.atan2(Math.sin(delta),Math.cos(delta));
    const step=Number((delta/RAD).toFixed(3));
    if(step===0){row.mode=original.mode;row.angle=original.angle;}
    else{row.mode="rear_spar_angle";row.angle=((drag.parameterAngle+step)%360+360)%360;}
   }
   selected=row.eta;
  }
  svg.onpointerdown=event=>{const hit=event.target.closest("[data-rib-part]");if(isLE||locked()||!hit||hit.getAttribute("aria-disabled")==="true"||event.button!==0||event.ctrlKey||event.metaKey)return;const index=rows.findIndex(r=>r.eta===Number(hit.dataset.ribEta));if(index<0||!lastData.drawable)return;event.preventDefault();const transform=Planform.editorTransform(lastData.geometry),start=local(event),master=rows[index],displayed=lastData.ribs.find(r=>r.isMaster&&r.master?.eta===master.eta),rear=transform.map(displayed?.rear||Spar.sample(lastData.geometry,1,master.eta).position),[tx,ty]=tangent(lastData.geometry,1,master.eta);drag={index,part:hit.dataset.ribPart,original:rows.map(r=>({...r})),pointer:event.pointerId,transform,data:lastData,start,rear,pointerAngle:Math.atan2(start.x-rear[0],start.y-rear[1]),parameterAngle:master.mode==="flight_direction"?180-Math.atan2(ty,tx)/RAD:master.angle};svg.setPointerCapture(event.pointerId);};
  svg.onpointermove=event=>{if(!drag||event.pointerId!==drag.pointer)return;modify(drag.part,drag.index,local(event),drag.transform,drag.data);refresh(false);};
  function endDrag(cancel=false){if(!drag)return;const old=drag;drag=null;const changed=JSON.stringify(rows)!==JSON.stringify(old.original);if(cancel)rows=old.original;try{svg.releasePointerCapture(old.pointer);}catch(_){}table();const data=refresh(false);if(!cancel){commit(data);if(changed)notify();}}
  svg.onpointerup=()=>endDrag();svg.onpointercancel=()=>endDrag(true);
  svg.onkeydown=event=>{if(event.key==="Escape"){endDrag(true);return;}const hit=event.target.closest("[data-rib-part]");if(!hit||locked()||isLE||hit.getAttribute("aria-disabled")==="true")return;const index=rows.findIndex(r=>r.eta===Number(hit.dataset.ribEta));if(index<0)return;if(event.key==="Enter"){event.preventDefault();tbody.querySelector(`tr[data-row="${index}"] input`)?.focus();return;}if(!["ArrowLeft","ArrowRight","ArrowUp","ArrowDown"].includes(event.key))return;event.preventDefault();const direction=event.key==="ArrowLeft"||event.key==="ArrowUp"?-1:1;if(hit.dataset.ribPart==="anchor")rows[index].eta+=(event.shiftKey?.01:.001)*direction;else{rows[index].mode="rear_spar_angle";rows[index].angle+=(event.shiftKey?5:.5)*direction;}selected=rows[index].eta;table();const data=refresh(false);commit(data);notify();svg.querySelector(`[data-rib-eta="${selected}"][data-rib-part="${hit.dataset.ribPart}"]`)?.focus();};
  section.querySelector('[data-rl="help"]').onclick=event=>{const help=section.querySelector(".rl-help");help.hidden=!help.hidden;event.currentTarget.setAttribute("aria-expanded",String(!help.hidden));};
  const onExternal=event=>{if(PARAM_KEYS.some(k=>event.target?.id==="p-"+k)){if(event.target.id==="p-"+key){reload();table();}refresh();}},onLock=()=>{endDrag(true);table();refresh(false);},onEscape=event=>{if(event.key==="Escape"&&drag){event.preventDefault();endDrag(true);}};
  doc.addEventListener("input",onExternal);doc.addEventListener("change",onExternal);doc.addEventListener("keydown",onEscape);host.addEventListener("parameterlockchange",onLock);reload();table();refresh(false);
  return{section,viewport,captureView:()=>viewport?.capture(),restoreView:value=>viewport?.restore(value),readDrafts,refresh,validate:deriveDraft,assertValidDraft(){const data=refresh(false);if(!data.valid)throw Error((isLE?"Leading-edge ribs: ":"Master ribs: ")+data.error);commit(data);return data;},destroy(){destroyed=true;viewport?.destroy();doc.removeEventListener("input",onExternal);doc.removeEventListener("change",onExternal);doc.removeEventListener("keydown",onEscape);host.removeEventListener("parameterlockchange",onLock);section.remove();}};
 }
 return{KEY,LE_KEY,PARAM_KEYS,roundEven,normalizeMasters,normalizeOrientations,tangent,masterDelta,arc,physical,intersection,derive,applyGenerated,leading,drawing,install,installLeadingEdge};
});
