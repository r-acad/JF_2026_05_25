(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingLoft=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const MAX_STATIONS=100,definitions=[{kind:"thickness",field:"tc",title:"Thickness distribution",label:"Target t/c",step:"0.01",empty:"No schedule: retain the thickness of the selected and blended airfoil sections.",note:"Target t/c is a chord fraction: 0.12 = 12%. Values outside the anchors stay constant."},{kind:"twist",field:"twist",title:"Twist distribution",label:"Twist (deg)",step:"1",empty:"No schedule: use the original linear root-to-tip twist defined by Tip twist.",note:"This schedule replaces Tip twist. Angles are in degrees; values outside the anchors stay constant."},{kind:"vertical_shift",field:"shift_percent",title:"Vertical shift",label:"Vertical shift (% semi-span)",step:"0.1",empty:"No schedule: no vertical translation. Positive values raise the loft along BASIC +Z; negative values lower it.",note:"Translation along BASIC +Z: Δz = semi-span × shift / 100. Applied after thickness and twist; values outside the anchors stay constant."}];
 const definitionFor=kind=>definitions.find(definition=>definition.kind===kind),roundGenerated=value=>Number(Number(value).toPrecision(4));
 const key=kind=>"loft."+kind+"_stations",methodKey=kind=>"loft."+kind+"_interpolation";
 const helpParagraphs=["Eta is the fraction of semi-span: 0 is the root and 1 is the tip. Each schedule is optional and independent of the airfoil shape stations. Enter distinct positions from 0 to 1. The rows are saved in eta order. Outside the first and last positions the nearest scheduled value is held constant; one row defines a constant value over the span.","Between adjacent stations, t=(eta−eta_i)/(eta_j−eta_i) and v=(1−w)v_i+w v_j. Linear uses w=t. Cosine uses w=(1−cos(pi*t))/2 and has zero interpolation slope at each anchor. Both reproduce every scheduled value. These interpolation choices affect only their own thickness, twist or vertical-shift schedule.","Target thickness is the chordwise maximum t/c of the blended section, not a thickness in metres. For example, 0.12 means 12% of the local chord. The generator preserves the midcamber m=(z_upper+z_lower)/2 and scales thickness about it: z_new=m+s(z_old−m), where s=(target t/c)/(current maximum t/c). Airfoil selection and its separate spanwise blending still determine the camber and shape.","Twist values are angles in degrees, rotated about the chosen Twist axis x/c. A nonempty twist schedule replaces the original root-zero to Tip twist law. Clear the twist schedule to return to that original law; the stored Tip twist value is preserved."];
 helpParagraphs.push("Vertical shift is a signed percentage of the projected semi-span s (not local chord or airfoil thickness): delta_z(eta)=s*shift_percent(eta)/100. For a 10 m semi-span, +2% raises a section by 0.2 m. Translation is along BASIC +Z, normal to the planform XY plane, after thickness rescaling and twist. It moves the whole section without changing its thickness or twist. Negative percentages lower it. Empty means zero shift; a single station applies one constant shift, and values outside the first/last stations are clamped to their nearest value.");
 function normalizeSchedule(value,kind){
  const field=definitionFor(kind)?.field;if(!field)throw Error("Unknown loft schedule.");const name=kind.replaceAll("_"," ");
  if(!Array.isArray(value))throw Error("The "+name+" schedule must be a station table.");
  if(value.length>MAX_STATIONS)throw Error("Use no more than "+MAX_STATIONS+" "+name+" stations.");
  const rows=value.map((row,i)=>{if(!row||typeof row!=="object"||Array.isArray(row)||Object.keys(row).some(k=>!["eta",field].includes(k)))throw Error("Invalid "+name+" station "+(i+1)+".");
   if(typeof row.eta!=="number"||!Number.isFinite(row.eta)||row.eta<0||row.eta>1)throw Error("Each "+name+" station needs eta between 0 and 1.");
   if(typeof row[field]!=="number"||!Number.isFinite(row[field]))throw Error("Each "+name+" station needs a finite "+(field==="tc"?"target t/c":field==="twist"?"twist angle":"vertical shift percentage")+".");
   if(field==="tc"&&!(row.tc>0&&row.tc<=1))throw Error("Target t/c must be greater than 0 and at most 1 (0.12 means 12% of chord).");
   if(field==="twist"&&Math.abs(row.twist)>=45)throw Error("Each twist angle must be strictly between −45 and 45 degrees.");
   return{eta:row.eta,[field]:row[field]};}).sort((a,b)=>a.eta-b.eta);
  for(let i=1;i<rows.length;i++)if(rows[i].eta-rows[i-1].eta<1e-8)throw Error("The "+name+" stations need distinct eta positions, at least 1e−8 apart.");
  return rows;
 }
 function interpolateSchedule(value,eta,{kind="thickness",method="linear"}={}){
  const rows=normalizeSchedule(value,kind),field=definitionFor(kind).field;
  if(!Number.isFinite(eta))throw Error("Eta must be finite.");if(!["linear","cosine"].includes(method))throw Error("Choose Linear or Cosine interpolation.");if(!rows.length)return kind==="vertical_shift"?0:null;
  if(eta<=rows[0].eta)return rows[0][field];if(eta>=rows.at(-1).eta)return rows.at(-1)[field];
  const right=rows.findIndex(row=>row.eta>=eta),a=rows[right-1],b=rows[right],t=(eta-a.eta)/(b.eta-a.eta),w=method==="cosine"?(1-Math.cos(Math.PI*t))/2:t;
  return(1-w)*a[field]+w*b[field];
 }
 function validationMessage(doc=globalThis.document){return doc?.querySelector(".loft-editor[data-invalid-message]:not([data-invalid-message=''])")?.dataset.invalidMessage||"";}
 function install(host,{onEdit,onHelp,isLocked=()=>false}={}){
  if(host.__wingLoft)return host.__wingLoft;const doc=host.ownerDocument,sections=[],listeners=[];let destroyed=false;
  const make=(tag,cls,text)=>{const el=doc.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;};
  const listen=(el,type,fn)=>{el?.addEventListener(type,fn);listeners.push(()=>el?.removeEventListener(type,fn));};
  const introduction=make("p","group-note","Set optional spanwise thickness, twist and vertical-shift schedules. Empty schedules retain the original airfoil thickness and tip-twist behavior, with no vertical translation."),help=make("button","mini","?");help.type="button";help.title="How thickness, twist and vertical shift are applied, including equations, endpoint behavior and the original tip-twist fallback.";help.setAttribute("aria-label","Help: lifting-surface loft");help.onclick=()=>onHelp?.({title:"Lifting-surface loft schedules",paragraphs:helpParagraphs.slice()});introduction.append(" ",help);host.insertBefore(introduction,host.children[1]||null);
  const tipRow=doc.getElementById("row-planform.twist_tip"),tipWasHidden=tipRow?.hidden||false;
  const twistRows=[tipRow,doc.getElementById("row-planform.twist_axis_xc")].filter(Boolean).map(row=>({row,parent:row.parentNode,next:row.nextSibling}));
  function defaultThickness(station){try{const A=globalThis.WingAirfoils,source=doc.getElementById("p-airfoil."+station+"_source")?.value;const profile=source==="naca"?A.nacaProfile(doc.getElementById("p-airfoil."+station)?.value||"0012"):JSON.parse(doc.getElementById("p-airfoil."+station+"_profile")?.value||"null");return A.profileMetrics(profile).maxThickness.value;}catch(_){return .12;}}
  for(const definition of definitions){
   const {kind,field}=definition,stored=doc.getElementById("p-"+key(kind));if(!stored)continue;
   const storedRow=doc.getElementById("row-"+key(kind));if(storedRow)storedRow.hidden=true;
   const section=make("fieldset","loft-editor"),legend=make("legend","",definition.title),note=make("p","pick-note"),error=make("p","loft-error"),list=make("div","loft-station-list"),actions=make("div","loft-actions"),add=make("button","mini","+ Add station"),clear=make("button","mini ghost","Clear schedule");section.dataset.loftKind=kind;error.setAttribute("role","alert");error.hidden=true;add.type=clear.type="button";add.dataset.loftAdd=kind;clear.dataset.loftClear=kind;actions.append(add,clear);section.append(legend,note,error,list,actions);
   const methodRow=doc.getElementById("row-"+methodKey(kind)),method=doc.getElementById("p-"+methodKey(kind));if(methodRow)section.append(methodRow);if(method){method.title=helpParagraphs[1];for(const option of method.options)option.title=option.value==="cosine"?"w=(1−cos(pi*t))/2; zero blend slope at the station anchors.":"w=t; constant rate within each station interval.";}
   if(kind==="twist")for(const {row}of twistRows)section.append(row);
   host.append(section);const rows=[];let serial=0,parseError="";
   const draft=()=>rows.map(row=>({eta:row.eta.value.trim()===""?null:Number(row.eta.value),[field]:row.value.value.trim()===""?null:Number(row.value.value)})).sort((a,b)=>(a.eta??Infinity)-(b.eta??Infinity));
   function validate(){let message=parseError;try{if(!message)normalizeSchedule(draft(),kind);}catch(e){message=e.message;}section.dataset.invalidMessage=message;error.textContent=message;error.hidden=!message;return message;}
   function controls(){const locked=isLocked(key(kind));for(const row of rows)for(const node of[row.eta,row.value,row.remove])node.disabled=locked;add.disabled=locked||rows.length>=MAX_STATIONS;clear.disabled=locked||!rows.length;if(method)method.disabled=locked||!rows.length;note.textContent=rows.length?definition.note:definition.empty;if(kind==="twist"&&tipRow)tipRow.hidden=rows.length>0;}
   function orderRows(){const focused=doc.activeElement;for(const row of [...rows].sort((a,b)=>Number(a.eta.value)-Number(b.eta.value)))list.append(row.el);if(focused&&section.contains(focused)&&doc.activeElement!==focused)focused.focus({preventScroll:true});}
   function sync(notify=true){parseError="";stored.value=JSON.stringify(draft());validate();controls();if(notify)onEdit?.(key(kind));}
   function addRow(value){const rowEl=make("div","loft-station-row"),etaLabel=make("label","","Eta "),valueLabel=make("label","",definition.label+" "),eta=make("input"),number=make("input"),remove=make("button","mini ghost","Remove");eta.type=number.type="number";eta.min="0";eta.max="1";eta.step="0.1";eta.value=value.eta??"";eta.setAttribute("aria-label",definition.title+" eta");number.step=definition.step;number.value=value[field]??"";number.setAttribute("aria-label",definition.label);if(field==="tc"){number.min="0";number.max="1";number.title="Maximum chordwise thickness divided by local chord; 0.12 means 12%.";}if(field==="shift_percent")number.title="Signed percentage of projected semi-span. +2 means a translation of 0.02 times semi-span along BASIC +Z, after thickness and twist.";remove.type="button";remove.setAttribute("aria-label","Remove "+kind.replaceAll("_"," ")+" station");rowEl.dataset.loftRow=String(++serial);etaLabel.append(eta);valueLabel.append(number);rowEl.append(etaLabel,valueLabel,remove);list.append(rowEl);const row={el:rowEl,eta,value:number,remove};rows.push(row);for(const input of[eta,number])listen(input,"input",()=>{if(!isLocked(key(kind)))sync();});for(const input of[eta,number])listen(input,"change",()=>{if(!validate())orderRows();});remove.onclick=()=>{if(isLocked(key(kind)))return;rows.splice(rows.indexOf(row),1);rowEl.remove();sync();};return row;}
   try{const initial=JSON.parse(stored.value||"[]");for(const value of normalizeSchedule(initial,kind))addRow(value);}catch(e){parseError="Cannot read saved "+kind.replaceAll("_"," ")+" schedule: "+e.message;}
   add.onclick=()=>{
    if(isLocked(key(kind))||rows.length>=MAX_STATIONS)return;
    if(!rows.length){const tip=Number(doc.getElementById("p-planform.twist_tip")?.value||0);addRow({eta:0,[field]:roundGenerated(kind==="thickness"?defaultThickness("root"):0)});addRow({eta:1,[field]:roundGenerated(kind==="thickness"?defaultThickness("tip"):kind==="twist"?tip:0)});}
    else{
     let values;try{values=normalizeSchedule(draft(),kind);}catch(_){return;}
     const unique=[...new Set([0,...values.map(v=>v.eta),1])].sort((a,b)=>a-b),gaps=unique.slice(1).map((end,i)=>({start:unique[i],end})).sort((a,b)=>(b.end-b.start)-(a.end-a.start));
     const gap=gaps.find(({start,end})=>{const eta=roundGenerated((start+end)/2);return eta-start>=1e-8&&end-eta>=1e-8;});
     if(!gap)return;const eta=roundGenerated((gap.start+gap.end)/2);
     addRow({eta,[field]:roundGenerated(interpolateSchedule(values,eta,{kind,method:method?.value||"linear"}))});
    }
    orderRows();sync();
   };
   clear.onclick=()=>{if(isLocked(key(kind)))return;for(const row of rows)row.el.remove();rows.length=0;sync();};listen(method,"change",()=>{if(!isLocked(key(kind)))onEdit?.(methodKey(kind));});validate();controls();sections.push({kind,stored,section,draft,validate,controls,methodRow,restoreBefore:storedRow});
  }
  listen(host,"parameterlockchange",()=>sections.forEach(s=>s.controls()));
  const api={readDrafts:()=>Object.fromEntries(sections.map(s=>[key(s.kind),s.draft()])),assertValidDraft(){for(const s of sections){const message=s.validate();if(message)throw Error(message);}},refresh(){if(!destroyed)for(const s of sections){s.validate();s.controls();}},destroy(){destroyed=true;for(const detach of listeners)detach();for(const {row,parent,next}of [...twistRows].reverse())parent.insertBefore(row,next?.parentNode===parent?next:null);for(const s of sections){if(s.methodRow)host.insertBefore(s.methodRow,s.restoreBefore||null);s.section.remove();}if(tipRow)tipRow.hidden=tipWasHidden;introduction.remove();delete host.__wingLoft;}};host.__wingLoft=api;return api;
 }
 return{install,normalizeSchedule,interpolateSchedule,validationMessage,helpParagraphs,MAX_STATIONS};
});
