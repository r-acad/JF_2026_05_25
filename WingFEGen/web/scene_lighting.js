/* Scene-owned studio lighting. Directions are saved in FE global XYZ. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSceneLighting=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const PRESETS={balanced:{ambient:.92,key:.82,fill:.56,keyDirection:[-.5,-.7,-1],fillDirection:[.6,.35,.8]},soft:{ambient:1.05,key:.5,fill:.42,keyDirection:[-.25,-.5,-1],fillDirection:[.4,.5,.7]},technical:{ambient:.78,key:1,fill:.7,keyDirection:[-.8,-.5,-1],fillDirection:[.5,.7,.8]}};
 const clone=value=>JSON.parse(JSON.stringify(value));
 function normalize(value){
  if(value!=null&&(typeof value!=="object"||Array.isArray(value)))throw Error("Lighting settings must be an object.");
  const input=value||{},preset=input.preset??"balanced";
  if(![...Object.keys(PRESETS),"custom"].includes(preset))throw Error("Unknown lighting preset.");
  const defaults=PRESETS[preset]||PRESETS.balanced,result={preset};
  for(const key of["ambient","key","fill"]){const number=input[key]??defaults[key];if(typeof number!=="number"||!Number.isFinite(number)||number<0||number>3)throw Error("Light intensities must be between 0 and 3.");result[key]=number;}
  for(const key of["keyDirection","fillDirection"]){const direction=input[key]??defaults[key];if(!Array.isArray(direction)||direction.length!==3||!direction.every(x=>typeof x==="number"&&Number.isFinite(x)&&Math.abs(x)<=100)||Math.hypot(...direction)<1e-9)throw Error("Light directions need three finite components and cannot be zero.");result[key]=direction.slice();}
  return result;
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,host=null,onChange=()=>{}}){
  if(!B||!scene)throw Error("Lighting needs a Babylon scene.");
  const hemi=new B.HemisphericLight("wing-studio-ambient",new B.Vector3(0,1,0),scene),key=new B.DirectionalLight("wing-studio-key",new B.Vector3(0,-1,0),scene),fill=new B.DirectionalLight("wing-studio-fill",new B.Vector3(0,1,0),scene),lights=[hemi,key,fill];
  hemi.groundColor=new B.Color3(.55,.58,.63);key.diffuse=new B.Color3(1,.985,.965);fill.diffuse=new B.Color3(.93,.97,1);
  let state=normalize(),root=null,disposed=false,observer=null;const controls=new Map();
  function capture(){return clone(state);}
  function sync(){for(const[name,input]of controls){if(name==="preset")input.value=state.preset;else if(name.includes(".")){const[k,i]=name.split(".");input.value=state[k][+i];}else input.value=state[name];}}
  function apply(value,{notify=false}={}){if(disposed)throw Error("Lighting controller is disposed.");const next=normalize(value);state=next;hemi.intensity=next.ambient;key.intensity=next.key;fill.intensity=next.fill;for(const[light,name]of[[key,"keyDirection"],[fill,"fillDirection"]]){const p=next[name];light.direction.copyFromFloats(p[1],p[2],p[0]);light.direction.normalize();}sync();if(notify)onChange(capture());return capture();}
  function mount(target){
   if(disposed)throw Error("Lighting controller is disposed.");root?.remove();controls.clear();host=target;if(!host)return;
   const doc=host.ownerDocument,el=(tag,text)=>{const node=doc.createElement(tag);if(text)node.textContent=text;return node;};root=el("section");root.className="scene-lighting";root.setAttribute("aria-label","Scene lighting");
   const heading=el("h3","Lighting"),presetLabel=el("label","Studio preset"),preset=el("select");preset.setAttribute("aria-label","Lighting preset");for(const[value,label]of[["balanced","Bright balanced"],["soft","Soft studio"],["technical","Technical contrast"],["custom","Custom"]]){const option=el("option",label);option.value=value;preset.append(option);}presetLabel.append(preset);controls.set("preset",preset);preset.onchange=()=>{if(preset.value==="custom")apply({...capture(),preset:"custom"},{notify:true});else apply({preset:preset.value},{notify:true});};root.append(heading,presetLabel);
   const error=el("p");error.className="scene-lighting-error";error.setAttribute("role","alert");error.hidden=true;
   function edit(name,value){try{const next=capture();next.preset="custom";if(name.includes(".")){const[k,i]=name.split(".");next[k][+i]=value;}else next[name]=value;apply(next,{notify:true});error.hidden=true;}catch(problem){error.textContent=problem.message;error.hidden=false;}}
   for(const[name,label]of[["ambient","Ambient brightness"],["key","Main light"],["fill","Fill light"]]){const row=el("label",label),input=el("input");input.type="number";input.min="0";input.max="3";input.step="0.05";input.setAttribute("aria-label",label);input.oninput=()=>edit(name,input.value===""?NaN:Number(input.value));controls.set(name,input);row.append(input);root.append(row);}
   const directions=el("details"),summary=el("summary","Light directions (global X, Y, Z)");directions.append(summary);
   for(const[name,label]of[["keyDirection","Main direction"],["fillDirection","Fill direction"]]){const group=el("fieldset"),legend=el("legend",label);group.append(legend);for(let i=0;i<3;i++){const row=el("label",["X","Y","Z"][i]),input=el("input");input.type="number";input.min="-100";input.max="100";input.step="0.1";input.setAttribute("aria-label",label+" "+["X","Y","Z"][i]);input.oninput=()=>edit(name+"."+i,input.value===""?NaN:Number(input.value));controls.set(name+"."+i,input);row.append(input);group.append(row);}directions.append(group);}
   directions.append(el("p","Directions describe the travel of light in global axes."));root.append(directions,error);host.append(root);sync();return root;
  }
  function dispose(){if(disposed)return;disposed=true;if(observer)scene.onDisposeObservable.remove(observer);for(const light of lights)light.dispose();root?.remove();root=null;controls.clear();}
  observer=scene.onDisposeObservable.addOnce(dispose);apply();if(host)mount(host);
  return{lights,capture,restore:value=>apply(value),apply,reset:()=>apply(),mount,dispose};
 }
 return{create,normalize,PRESETS:clone(PRESETS)};
});
