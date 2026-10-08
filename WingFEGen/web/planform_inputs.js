/* Two input presentations for the same canonical base trapezoid. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingPlanformInputs=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const PARAM_KEYS=["planform.area","planform.aspect_ratio","planform.taper_ratio"];
 const METHODS=["area","dimensions"];
 function validateState(value){
  if(value==null)return{method:"area"};
  if(typeof value!=="object"||Array.isArray(value)||Object.keys(value).some(key=>key!=="method")||!METHODS.includes(value.method))throw new Error("Planform input method must be area or dimensions.");
  return{method:value.method};
 }
 function dimensions(params){
  const area=params[PARAM_KEYS[0]],aspect=params[PARAM_KEYS[1]],taper=params[PARAM_KEYS[2]];
  if(![area,aspect,taper].every(v=>typeof v==="number"&&Number.isFinite(v)&&v>0)||taper>1)return{valid:false,error:"Enter a positive area and aspect ratio, and taper ratio greater than zero and no greater than one."};
  const span=Math.sqrt(area*aspect),root=2*area/(span*(1+taper)),tip=taper*root;
  if(![span,root,tip].every(v=>Number.isFinite(v)&&v>0))return{valid:false,error:"The base dimensions cannot be represented at these input magnitudes."};
  return{valid:true,root,tip,span};
 }
 function parameters(values){
  const root=values.root,tip=values.tip,span=values.span;
  if(![root,tip,span].every(v=>typeof v==="number"&&Number.isFinite(v)&&v>0))return{valid:false,error:"Root chord, tip chord and full projected span must all be positive numbers."};
  if(tip>root)return{valid:false,error:"Tip chord must not exceed root chord (the supported taper ratio is at most 1)."};
  const mean=root/2+tip/2,area=span*mean,aspect=span/mean,taper=tip/root;
  const canonical={[PARAM_KEYS[0]]:area,[PARAM_KEYS[1]]:aspect,[PARAM_KEYS[2]]:taper};
  if(!dimensions(canonical).valid)return{valid:false,error:"These dimensions give an area, aspect ratio or taper that cannot be represented. Use smaller input magnitudes."};
  return{valid:true,canonical,root,tip,span};
 }
 function install(host,{readValues,onEdit,isLocked=()=>false}={}){
  const doc=host.ownerDocument,canonical=PARAM_KEYS.map(key=>doc.getElementById("p-"+key)),rows=PARAM_KEYS.map(key=>doc.getElementById("row-"+key));
  if(canonical.some(input=>!input))return null;
  const section=doc.createElement("section");section.className="planform-input-method";section.setAttribute("aria-label","Base planform input method");
  section.innerHTML='<label class="planform-method-label" for="planform-input-method">Define base trapezoid by<select id="planform-input-method" data-parameter-lock-exempt="true"><option value="area">Area, aspect ratio and taper</option><option value="dimensions">Root chord, tip chord and span</option></select></label><div class="planform-direct-inputs" hidden></div><p class="planform-method-note">Both methods define the same base trapezoid. Edge and spar perturbations keep their normalized offsets. Sweep, dihedral and twist below apply to either method.</p><p class="planform-direct-error" role="alert" hidden></p>';
  const selector=section.querySelector("select"),direct=section.querySelector(".planform-direct-inputs"),error=section.querySelector(".planform-direct-error"),inputs={};
  for(const[key,label]of[["root","Root chord (m)"],["tip","Tip chord (m)"],["span","Full projected span (m)"]]){
   const row=doc.createElement("label"),span=doc.createElement("span"),input=doc.createElement("input");row.className="planform-direct-row";span.textContent=label;input.id="planform-dimension-"+key;input.type="number";input.step="any";input.min="0";input.setAttribute("aria-label",label);input.setAttribute("aria-describedby","planform-dimension-help");row.append(span,input);direct.append(row);inputs[key]=input;
  }
  const help=doc.createElement("p");help.id="planform-dimension-help";help.className="planform-method-note";help.textContent="Span is the full projected tip-to-tip distance, twice the modeled half-span; it is not the sloping length along a dihedral wing. Chords describe the base trapezoid before perturbations.";direct.append(help);
  if(rows[0])rows[0].before(section);else host.append(section);
  const priorHidden=rows.map(row=>row?.hidden||false);
  let method="area",dirty=false,destroyed=false,lastSignature="";
  const read=()=>readValues?readValues():Object.fromEntries(PARAM_KEYS.map((key,i)=>[key,canonical[i].value.trim()===""?NaN:Number(canonical[i].value)]));
  const signature=()=>JSON.stringify(PARAM_KEYS.map((key,i)=>canonical[i].value));
  const readDirect=()=>Object.fromEntries(Object.entries(inputs).map(([key,input])=>[key,input.value.trim()===""?NaN:Number(input.value)]));
  function showError(message=""){error.textContent=message;error.hidden=!message;section.classList.toggle("invalid",!!message);}
  function sync(){
   const data=dimensions(read());for(const key of Object.keys(inputs))inputs[key].value=data.valid?String(data[key]):"";
   dirty=false;lastSignature=signature();return data;
  }
  function render(){
   selector.value=method;direct.hidden=method!=="dimensions";rows.forEach((row,i)=>{if(row)row.hidden=method==="dimensions"||priorHidden[i];});
   for(const input of Object.values(inputs))input.disabled=!!isLocked();
   if(method==="dimensions"){const result=parameters(readDirect());showError(result.valid?"":result.error+" The current model definition is unchanged until all three dimensions are valid.");}else showError();
  }
  function refresh(){if(destroyed)return;if(signature()!==lastSignature||isLocked()&&dirty)sync();render();}
  function commit(){
   if(isLocked()){sync();render();return false;}
   const result=parameters(readDirect());render();if(!result.valid)return false;
   let changed=false;for(let i=0;i<PARAM_KEYS.length;i++){const value=result.canonical[PARAM_KEYS[i]];if(Number(canonical[i].value)!==value||canonical[i].value.trim()===""){canonical[i].value=String(value);changed=true;}}
   dirty=false;lastSignature=signature();if(changed)onEdit?.("planform.area");return true;
  }
  const listeners=[];
  const listen=(target,name,listener)=>{target.addEventListener(name,listener);listeners.push(()=>target.removeEventListener(name,listener));};
  for(const input of Object.values(inputs)){
   listen(input,"input",()=>{dirty=true;commit();});
   listen(input,"change",()=>{if(dirty)commit();});
  }
  for(const input of canonical)for(const event of["input","change"])listen(input,event,refresh);
  listen(selector,"change",()=>{method=selector.value;sync();render();});
  listen(host,"parameterlockchange",refresh);
  sync();render();
  return{refresh,capture:()=>({method}),restore(value){method=validateState(value).method;sync();render();return{method};},
   assertValidDraft(){refresh();if(method!=="dimensions")return;if(!parameters(readDirect()).valid){render();throw new Error("Planform dimensions: "+parameters(readDirect()).error);}if(dirty&&!commit())throw new Error("Planform dimensions must be corrected before creating the model.");},
   destroy(){if(destroyed)return;destroyed=true;for(const remove of listeners)remove();rows.forEach((row,i)=>{if(row)row.hidden=priorHidden[i];});section.remove();}};
 }
 return{PARAM_KEYS,validateState,dimensions,parameters,install};
});
