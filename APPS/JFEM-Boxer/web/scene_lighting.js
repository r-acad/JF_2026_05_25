/* Scene-owned studio lighting. Directions are saved in FE global XYZ. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSceneLighting=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 // Balance fixed studio lights with camera fill so the underside remains
 // readable without clipping saturated colours or erasing face contrast.
 // Custom intensities in an existing Study still override these defaults.
 const PRESETS={balanced:{ambient:.3,key:.3,fill:.2,headlight:.48,keyDirection:[-.5,-.7,-1],fillDirection:[.6,.35,.8]},soft:{ambient:.38,key:.18,fill:.18,headlight:.44,keyDirection:[-.25,-.5,-1],fillDirection:[.4,.5,.7]},technical:{ambient:.24,key:.43,fill:.16,headlight:.4,keyDirection:[-.8,-.5,-1],fillDirection:[.5,.7,.8]}};
 const PREVIOUS_PRESETS={balanced:{ambient:.32,key:.8,fill:.24,headlight:.35,keyDirection:[-.5,-.7,-1],fillDirection:[.6,.35,.8]},soft:{ambient:.44,key:.58,fill:.28,headlight:.3,keyDirection:[-.25,-.5,-1],fillDirection:[.4,.5,.7]},technical:{ambient:.23,key:.88,fill:.18,headlight:.28,keyDirection:[-.8,-.5,-1],fillDirection:[.5,.7,.8]}};
 const LEGACY_PRESETS={balanced:{ambient:.92,key:.82,fill:.56,keyDirection:[-.5,-.7,-1],fillDirection:[.6,.35,.8]},soft:{ambient:1.05,key:.5,fill:.42,keyDirection:[-.25,-.5,-1],fillDirection:[.4,.5,.7]},technical:{ambient:.78,key:1,fill:.7,keyDirection:[-.8,-.5,-1],fillDirection:[.5,.7,.8]}};
 const clone=value=>JSON.parse(JSON.stringify(value));
 function normalize(value){
  if(value!=null&&(typeof value!=="object"||Array.isArray(value)))throw Error("Lighting settings must be an object.");
  let input=value||{};const preset=input.preset??"balanced";
  if(![...Object.keys(PRESETS),"custom"].includes(preset))throw Error("Unknown lighting preset.");
  const legacy=LEGACY_PRESETS[preset],previous=PREVIOUS_PRESETS[preset];
  const matches=record=>record&&Object.entries(record).every(([key,expected])=>(key==='headlight'&&input[key]===undefined)||(Array.isArray(expected)?
    Array.isArray(input[key])&&input[key].length===expected.length&&expected.every((x,i)=>input[key][i]===x):input[key]===expected));
  // Studies capture expanded preset values. Upgrade only an exact old named
  // preset; a custom preset or any edited intensity/direction is intentional.
  if(input.preset===preset&&matches(previous))input={preset,shadows:input.shadows,selfShadows:input.selfShadows};
  else if(input.preset===preset&&matches(legacy))input={preset,shadows:input.shadows,selfShadows:input.selfShadows,...(input.headlight===undefined?{}:{headlight:input.headlight})};
  const defaults=PRESETS[preset]||PRESETS.balanced,result={preset};
  for(const name of ['shadows','selfShadows']){if(input[name]!==undefined&&typeof input[name]!== 'boolean')throw Error('Shadow switches must be boolean.');result[name]=input[name]??false;}
  for(const key of["ambient","key","fill","headlight"]){const number=input[key]??(key==="headlight"&&preset==="custom"?0:defaults[key]);if(typeof number!=="number"||!Number.isFinite(number)||number<0||number>3)throw Error("Light intensities must be between 0 and 3.");result[key]=number;}
  for(const key of["keyDirection","fillDirection"]){const direction=input[key]??(key==="headlight"&&preset==="custom"?0:defaults[key]);if(!Array.isArray(direction)||direction.length!==3||!direction.every(x=>typeof x==="number"&&Number.isFinite(x)&&Math.abs(x)<=100)||Math.hypot(...direction)<1e-9)throw Error("Light directions need three finite components and cannot be zero.");result[key]=direction.slice();}
  return result;
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,host=null,onChange=()=>{}}){
  if(!B||!scene)throw Error("Lighting needs a Babylon scene.");
  const hemi=new B.HemisphericLight("wing-studio-ambient",new B.Vector3(0,1,0),scene),key=new B.DirectionalLight("wing-studio-key",new B.Vector3(0,-1,0),scene),fill=new B.DirectionalLight("wing-studio-fill",new B.Vector3(0,1,0),scene),headlight=new B.DirectionalLight("wing-studio-headlight",new B.Vector3(0,0,-1),scene),lights=[hemi,key,fill,headlight];
  // Neutral light colours preserve the hue of numerical colour scales.
  hemi.groundColor=new B.Color3(.72,.72,.72);key.diffuse=B.Color3.White();fill.diffuse=B.Color3.White();headlight.diffuse=B.Color3.White();headlight.specular=B.Color3.Black();
  // The default camera depth range clips an off-origin FE model. The shadow
  // depth range is fitted below to both casters and the receiving ground.
  key.autoCalcShadowZBounds=false;
  let state=normalize(),root=null,disposed=false,observer=null,frameObserver=null;const controls=new Map();
  let shadows=null,shadowGround=null,shadowGroundSource=null,shadowMaterial=null,shadowStamp='';
  const meshAdded=scene.onNewMeshAddedObservable.add(()=>{shadowStamp='';}),meshRemoved=scene.onMeshRemovedObservable.add(()=>{shadowStamp='';});
  // Only physical FE faces/sections and the current aerodynamic surface cast
  // shadows. Load arrows, constraints, selection markers, axes and reference
  // overlays can also use lit materials, but are display annotations.
  const surface=mesh=>!mesh.metadata?.wingViewHelper&&(['quad','tria','bar'].includes(mesh.metadata?.feGroup?.kind)||mesh.name==='AERO_SURFACE')&&mesh.getTotalIndices?.()>0&&mesh.material&&!mesh.material.disableLighting&&mesh.getClassName?.()!=='LinesMesh';
  function groundShadowMaterial(){
   // Sample the generator's regular depth map, with a small nine-tap edge
   // filter. Unlike BackgroundMaterial.shadowOnly, this receiver writes the
   // depth-peeling outputs used by translucent structural meshes. Its black
   // alpha is 0.55 * (1 - darkness), leaving ground colours/reflections intact.
   const shader={vertexSource:`precision highp float;attribute vec3 position;uniform mat4 worldViewProjection;uniform mat4 world;uniform mat4 shadowMatrix;varying vec4 shadowPosition;void main(){shadowPosition=shadowMatrix*world*vec4(position,1.0);gl_Position=worldViewProjection*vec4(position,1.0);}`,
    fragmentSource:`precision highp float;
#include<oitDeclaration>
uniform sampler2D shadowSampler;uniform vec2 shadowDepth;uniform float shadowTexel;uniform float packedDepth;varying vec4 shadowPosition;
float depthAt(vec2 uv){vec4 value=texture2D(shadowSampler,uv);return mix(value.r,dot(value,vec4(1.0/16581375.0,1.0/65025.0,1.0/255.0,1.0)),packedDepth);}
void main(){vec2 uv=shadowPosition.xy/shadowPosition.w*.5+.5;float receiverDepth=(shadowPosition.z+shadowDepth.x)/shadowDepth.y;float occlusion=0.0;
 if(receiverDepth>=0.0&&receiverDepth<=1.0&&uv.x>=0.0&&uv.x<=1.0&&uv.y>=0.0&&uv.y<=1.0){for(int x=-1;x<=1;x++){for(int y=-1;y<=1;y++){occlusion+=step(depthAt(uv+vec2(float(x),float(y))*shadowTexel),receiverDepth);}}occlusion/=9.0;}
 vec4 color=vec4(0.0,0.0,0.0,.4125*occlusion);gl_FragColor=color;
#include<oitFragment>
#ifdef ORDER_INDEPENDENT_TRANSPARENCY
 if(fragDepth==nearestDepth){frontColor.rgb+=color.rgb*color.a*alphaMultiplier;frontColor.a=1.0-alphaMultiplier*(1.0-color.a);}else{backColor+=color;}
#endif
}`};
   const material=new B.ShaderMaterial('ground-shadow-only',scene,shader,{attributes:['position'],uniforms:['worldViewProjection','world','shadowMatrix','shadowDepth','shadowTexel','packedDepth'],samplers:['shadowSampler','oitDepthSampler','oitFrontColorSampler'],needAlphaBlending:true});
   material.alpha=.55;material.backFaceCulling=false;material.disableDepthWrite=true;
   material.customShaderNameResolve=(_name,_uniforms,_buffers,_samplers,defines)=>{if(scene.useOrderIndependentTransparency){defines.push('#define ORDER_INDEPENDENT_TRANSPARENCY');if(!scene.getEngine().getCaps().textureFloatLinearFiltering)defines.push('#define ORDER_INDEPENDENT_TRANSPARENCY_16BITS');}return shader;};
   material.onBindObservable.add(()=>{const effect=material.getEffect();if(shadows){const map=shadows.getShadowMapForRendering();effect.setTexture('shadowSampler',map);effect.setMatrix('shadowMatrix',shadows.getTransformMatrix());effect.setFloat2('shadowDepth',key.getDepthMinZ(scene.activeCamera),key.getDepthMinZ(scene.activeCamera)+key.getDepthMaxZ(scene.activeCamera));effect.setFloat('shadowTexel',1/map.getSize().width);effect.setFloat('packedDepth',map.textureType===B.Constants.TEXTURETYPE_UNSIGNED_BYTE?1:0);}if(scene.useOrderIndependentTransparency)scene.depthPeelingRenderer.bind(effect);});
   return material;
  }
  function fitShadowDepth(casters,ground){
   const direction=key.direction,center=B.Vector3.Zero();let count=0;
   for(const mesh of casters)if(mesh.isEnabled()&&mesh.isVisible){mesh.computeWorldMatrix();center.addInPlace(mesh.getBoundingInfo().boundingBox.centerWorld);count++;}
   if(!count)return;center.scaleInPlace(1/count);
   let low=Infinity,high=-Infinity;
   for(const mesh of [...casters,...(ground?.isEnabled()?[ground]:[])])if(mesh.isEnabled()&&mesh.isVisible){
    mesh.computeWorldMatrix();for(const point of mesh.getBoundingInfo().boundingBox.vectorsWorld){const value=B.Vector3.Dot(point.subtract(center),direction);low=Math.min(low,value);high=Math.max(high,value);}
   }
   const margin=Math.max(1e-6,(high-low)*.02);
   key.position.copyFrom(center.add(direction.scale(low-margin)));key.shadowMinZ=0;key.shadowMaxZ=high-low+2*margin;
  }
  function updateShadows(force=false){
   const wanted=(state.shadows||state.selfShadows)&&key.intensity>0&&key.isEnabled();
   if(!wanted){if(shadows){shadows.dispose();shadows=null;}shadowGround?.setEnabled(false);for(const mesh of scene.meshes)if(surface(mesh))mesh.receiveShadows=false;shadowStamp='';return;}
   // Poisson sampling retains a regular depth texture for the receiver;
   // Babylon's native self-shadow shader reads the same map.
   if(!shadows){shadows=new B.ShadowGenerator(2048,key);shadows.usePoissonSampling=true;shadows.transparencyShadow=true;shadows.forceBackFacesOnly=false;shadows.bias=.0005;shadows.normalBias=.01;shadows.setDarkness(.25);}
   const stamp=scene.meshes.length+':'+state.selfShadows;
   if(force||stamp!==shadowStamp){const casters=scene.meshes.filter(surface);shadows.getShadowMap().renderList=casters;for(const mesh of casters)mesh.receiveShadows=state.selfShadows;shadowStamp=stamp;}
   const ground=scene.meshes.find(mesh=>mesh.metadata?.plane==='ground');
   fitShadowDepth(shadows.getShadowMap().renderList,ground);
   if(ground!==shadowGroundSource){shadowGround?.dispose();shadowGround=null;shadowGroundSource=ground;
    if(ground){shadowMaterial??=groundShadowMaterial();
     // Bind the depth texture in each pass and emit the same OIT outputs as
     // the ground guide, instead of using an unsupported shadow-only material.
     shadowGround=ground.clone('ground-shadow-receiver',ground.parent,true);shadowGround.material=shadowMaterial;shadowGround.metadata={wingViewHelper:true,groundShadow:true};shadowGround.isPickable=false;shadowGround.receiveShadows=true;
    }
   }
   if(shadowGround&&ground){shadowGround.setEnabled(state.shadows&&ground.isEnabled()&&ground.metadata.ground_style!=='wireframe');shadowGround.position.copyFrom(ground.position);shadowGround.scaling.copyFrom(ground.scaling);shadowGround.rotation.copyFrom(ground.rotation);
    const box=ground.getBoundingInfo().boundingBox,side=(scene.activeCamera?.globalPosition.y??box.centerWorld.y+1)>=box.centerWorld.y?1:-1;
    shadowGround.position.y+=side*Math.max(1e-7,box.maximumWorld.subtract(box.minimumWorld).length()*1e-5);
   }
  }
  function capture(){return clone(state);}
  function sync(){for(const[name,input]of controls){if(input.type==='checkbox')input.checked=state[name];else if(name==="preset")input.value=state.preset;else if(name.includes(".")){const[k,i]=name.split(".");input.value=state[k][+i];}else input.value=state[name];}}
  function apply(value,{notify=false}={}){if(disposed)throw Error("Lighting controller is disposed.");const next=normalize(value);state=next;hemi.intensity=next.ambient;key.intensity=next.key;fill.intensity=next.fill;headlight.intensity=next.headlight;for(const[light,name]of[[key,"keyDirection"],[fill,"fillDirection"]]){const p=next[name];light.direction.copyFromFloats(p[1],p[2],p[0]);light.direction.normalize();}updateShadows(true);sync();if(notify)onChange(capture());return capture();}
  function mount(target){
   if(disposed)throw Error("Lighting controller is disposed.");root?.remove();controls.clear();host=target;if(!host)return;
   const doc=host.ownerDocument,el=(tag,text)=>{const node=doc.createElement(tag);if(text)node.textContent=text;return node;};root=el("section");root.className="scene-lighting";root.setAttribute("aria-label","Scene lighting");
   const heading=el("h3","Lighting"),presetLabel=el("label","Studio preset"),preset=el("select");preset.setAttribute("aria-label","Lighting preset");for(const[value,label]of[["balanced","Balanced studio"],["soft","Soft studio"],["technical","Technical contrast"],["custom","Custom"]]){const option=el("option",label);option.value=value;preset.append(option);}presetLabel.append(preset);controls.set("preset",preset);preset.onchange=()=>{if(preset.value==="custom")apply({...capture(),preset:"custom"},{notify:true});else apply({...capture(),...PRESETS[preset.value],preset:preset.value},{notify:true});};root.append(heading,presetLabel);
   for(const[name,label,tip]of [["shadows","Shadows","Cast the model shadow onto the visible ground. Requires the main directional light."],["selfShadows","Self shadows","Allow structural faces to cast shadows on each other. Can add rendering cost on very large models."]]){const row=el("label",label),input=el("input");row.title=tip;input.type="checkbox";input.onchange=()=>apply({...capture(),[name]:input.checked},{notify:true});controls.set(name,input);row.prepend(input);root.append(row);}
   const error=el("p");error.className="scene-lighting-error";error.setAttribute("role","alert");error.hidden=true;
   function edit(name,value){try{const next=capture();next.preset="custom";if(name.includes(".")){const[k,i]=name.split(".");next[k][+i]=value;}else next[name]=value;apply(next,{notify:true});error.hidden=true;}catch(problem){error.textContent=problem.message;error.hidden=false;}}
   for(const[name,label]of[["ambient","Ambient brightness"],["key","Main light"],["fill","Fill light"],["headlight","Camera fill (all angles)"]]){const row=el("label",label),input=el("input");input.type="number";input.min="0";input.max="3";input.step="0.05";input.setAttribute("aria-label",label);input.oninput=()=>edit(name,input.value===""?NaN:Number(input.value));controls.set(name,input);row.append(input);root.append(row);}
   const directions=el("details"),summary=el("summary","Light directions (global X, Y, Z)");directions.append(summary);
   for(const[name,label]of[["keyDirection","Main direction"],["fillDirection","Fill direction"]]){const group=el("fieldset"),legend=el("legend",label);group.append(legend);for(let i=0;i<3;i++){const row=el("label",["X","Y","Z"][i]),input=el("input");input.type="number";input.min="-100";input.max="100";input.step="0.1";input.setAttribute("aria-label",label+" "+["X","Y","Z"][i]);input.oninput=()=>edit(name+"."+i,input.value===""?NaN:Number(input.value));controls.set(name+"."+i,input);row.append(input);group.append(row);}directions.append(group);}
   directions.append(el("p","Directions describe the travel of light in global axes. Camera fill follows the viewing direction and lights faces viewed from below; set it to zero to switch it off."));root.append(directions,error);host.append(root);sync();return root;
  }
  function dispose(){if(disposed)return;disposed=true;if(observer)scene.onDisposeObservable.remove(observer);if(frameObserver)scene.onBeforeRenderObservable.remove(frameObserver);scene.onNewMeshAddedObservable.remove(meshAdded);scene.onMeshRemovedObservable.remove(meshRemoved);shadows?.dispose();shadowGround?.dispose();shadowMaterial?.dispose();for(const light of lights)light.dispose();root?.remove();root=null;controls.clear();}
  frameObserver=scene.onBeforeRenderObservable.add(()=>{if(state.shadows||state.selfShadows)updateShadows();const camera=scene.activeCamera;if(camera&&headlight.intensity>0)headlight.direction.copyFrom(camera.getForwardRay(1).direction);});
  observer=scene.onDisposeObservable.addOnce(dispose);apply();if(host)mount(host);
  return{lights,capture,restore:value=>apply(value),apply,reset:()=>apply(),mount,dispose};
 }
 return{create,normalize,PRESETS:clone(PRESETS)};
});
