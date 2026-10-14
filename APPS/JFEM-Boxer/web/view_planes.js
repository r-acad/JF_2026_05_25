/* Non-FE context planes, excluded from model layers, picking and exports.
 * A procedural shader keeps adjustable grids cheap at any cell spacing.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingViewPlanes=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const toView=p=>[p[1],p[2],p[0]];
 const GROUND_DEFAULTS={color:'#bfccd7',style:'solid',opacity:1};
 function settings({z=0,spacing=5}={}){
  if(!Number.isFinite(z))throw Error("Ground z must be a finite number of metres.");
  if(!Number.isFinite(spacing)||spacing<=0)throw Error("Ground grid spacing must be a finite number greater than zero.");
  return{z,spacing};
 }
 function layout(data,options){
  const {z,spacing}=settings(options);
  const min=data?.bbox?.min||[-5,-5,-5],max=data?.bbox?.max||[5,5,5],params=data?.model_params||{};
  const imported=!!data?.imported_deck;
  // A native deck has no generated-wing root. Do not stretch its guides from
  // a far-offset model to an unrelated origin inherited from wing defaults.
  const root=imported?[(min[0]+max[0])/2,0,(min[2]+max[2])/2]:[Number(params["planform.root_ref_x"])||0,Number(params["planform.root_ref_y"])||0,Number(params["planform.root_ref_z"])||0];
  const diagonal=Math.hypot(...max.map((v,i)=>v-min[i]))||1,margin=imported?.15*diagonal:Math.max(5,.15*diagonal);
  const low=min.map((v,i)=>imported?v-margin:5*Math.floor((Math.min(v,root[i])-margin)/5)),high=max.map((v,i)=>imported?v+margin:5*Math.ceil((Math.max(v,root[i])+margin)/5));
  return{root,spacing,z,ground:[[low[0],low[1],z],[high[0],low[1],z],[high[0],high[1],z],[low[0],high[1],z]],
   symmetry:[[low[0],root[1],low[2]],[high[0],root[1],low[2]],[high[0],root[1],high[2]],[low[0],root[1],high[2]]]};
 }
 function create({BABYLON:B=globalThis.BABYLON,scene}){
  const meshes={},materials=[];let geometry=null,model=null,currentSettings=settings(),groundRenderable=true;
  let groundAppearance={...GROUND_DEFAULTS},mirror=null,metal=null;
  function material(name,color,alpha){
   const mat=new B.StandardMaterial(name,scene);mat.diffuseColor=B.Color3.Black();mat.emissiveColor=B.Color3.FromHexString(color);
   mat.specularColor=B.Color3.Black();mat.disableLighting=true;mat.backFaceCulling=false;mat.twoSidedLighting=true;
   mat.alpha=alpha;mat.transparencyMode=B.Material.MATERIAL_ALPHABLEND;mat.disableDepthWrite=true;materials.push(mat);return mat;
  }
  const groundShader={
   vertexSource:"precision highp float; attribute vec3 position; uniform mat4 worldViewProjection; uniform float gridSpacing; varying vec2 grid; void main(){grid=position.zx/gridSpacing;gl_Position=worldViewProjection*vec4(position,1.0);}",
   // Euclidean screen gradients express distance in pixels, independent of
   // zoom, projection or line direction. A narrow antialias ramp avoids thick
   // world-space grid bands; unresolved cells fade instead of flickering.
   fragmentSource:`#extension GL_OES_standard_derivatives : enable
precision highp float;
#include<oitDeclaration>
uniform vec3 groundTint;
uniform float groundOpacity;
uniform float gridOnly;
varying vec2 grid;
vec4 gridColor(){
 vec2 dx=dFdx(grid),dy=dFdy(grid),width=sqrt(dx*dx+dy*dy);
 float fade=clamp(max(width.x,width.y)*2.0,0.0,1.0);
 vec3 average=vec3(0.75,0.80,0.845);
 if(fade>=1.0)return vec4(average*groundTint,groundOpacity*(1.0-gridOnly));
 float tile=mod(floor(grid.x)+floor(grid.y),2.0);
 vec3 color=mix(vec3(0.69,0.75,0.80),vec3(0.81,0.85,0.89),tile);
 vec2 line=abs(fract(grid+0.5)-0.5)/max(width,vec2(0.00000000000000000001));
 float edge=1.0-smoothstep(0.0,1.0,min(line.x,line.y));
 // The same physical grid is used in every nonmetal finish. Wireframe
 // removes only the tile fill; it never exposes the quad's two triangles.
 vec3 lineColor=mix(vec3(0.39,0.48,0.57),vec3(0.67,0.76,0.83),gridOnly);
 color=mix(mix(color,lineColor,edge),average,fade);
 float alpha=groundOpacity*mix(1.0,edge*(1.0-fade),gridOnly);
 return vec4(mix(color,lineColor,gridOnly)*groundTint,alpha);
}
void main(){
 vec4 color=gridColor();
 gl_FragColor=color;
#include<oitFragment>
#ifdef ORDER_INDEPENDENT_TRANSPARENCY
 if(fragDepth==nearestDepth){frontColor.rgb+=color.rgb*color.a*alphaMultiplier;frontColor.a=1.0-alphaMultiplier*(1.0-color.a);}else{backColor+=color;}
#endif
}`,
  };
  const groundMaterial=new B.ShaderMaterial("view-ground-material",scene,groundShader,{attributes:["position"],uniforms:["worldViewProjection","gridSpacing","groundTint","groundOpacity","gridOnly"],samplers:["oitDepthSampler","oitFrontColorSampler"],needAlphaBlending:false,needAlphaTesting:false});
  groundMaterial.needAlphaBlending=()=>groundAppearance.style==='wireframe'||groundMaterial.alpha<1;
  // ShaderMaterial does not opt into Babylon's depth-peeling protocol for us.
  // Without its MRT outputs the translucent/grid-only guide disappears as
  // soon as the FE surface mode enables OIT. Use the bundled shader includes
  // and per-pass sampler binding, retaining the same bounded grid geometry.
  groundMaterial.customShaderNameResolve=(_name,_uniforms,_buffers,_samplers,defines)=>{
   if(scene.useOrderIndependentTransparency&&groundMaterial.needAlphaBlending()){
    defines.push('#define ORDER_INDEPENDENT_TRANSPARENCY');
    if(!scene.getEngine().getCaps().textureFloatLinearFiltering)defines.push('#define ORDER_INDEPENDENT_TRANSPARENCY_16BITS');
   }
   return groundShader;
  };
  groundMaterial.onBindObservable.add(()=>{if(scene.useOrderIndependentTransparency&&groundMaterial.needAlphaBlending())scene.depthPeelingRenderer.bind(groundMaterial.getEffect());});
  function setGroundColor(hex){groundAppearance.color=hex;const c=B.Color3.FromHexString(hex);groundMaterial.setColor3('groundTint',new B.Color3(c.r/(191/255),c.g/(204/255),c.b/(215/255)));if(metal)metal.albedoColor=c;}
  setGroundColor('#bfccd7');
  groundMaterial.setFloat('groundOpacity',1);
  groundMaterial.setFloat('gridOnly',0);
  groundMaterial.backFaceCulling=false;groundMaterial.disableDepthWrite=true;materials.push(groundMaterial);
  const symmetryMaterial=material("view-symmetry-material","#a9c6df",.09);
  function reflectionSide(){
   if(!mirror)return;
   // FE global Z maps to Babylon Y. Keep only objects on the camera's
   // side of the mirror, including views from beneath an elevated plane.
   scene.activeCamera?.getViewMatrix();
   const side=(scene.activeCamera?.globalPosition?.y??currentSettings.z+1)>=currentSettings.z?1:-1;
   mirror.mirrorPlane.normal.copyFromFloats(0,-side,0);mirror.mirrorPlane.d=side*currentSettings.z;
  }
  function metallicMaterial(){
   if(metal)return metal;
   // One bounded planar render target reflects the current visible meshes;
   // it is collected by Babylon only while the metallic ground is visible.
   mirror=new B.MirrorTexture('view-ground-reflection',512,scene,true);
   mirror.noPrePassRenderer=true;
   // Babylon's depth-peeling compositor owns scene-sized shared buffers;
   // running it inside a reflection target corrupts the subsequent main
   // view. The bounded mirror uses normal alpha sorting in its own render
   // pass. Do not call the public OIT setter twice per frame: it invalidates
   // every material in the scene. Each pass already has its own draw cache.
   const renderMirror=mirror.render.bind(mirror);
   mirror.render=(...args)=>{
    const oit=scene._useOrderIndependentTransparency;
    try{scene._useOrderIndependentTransparency=false;return renderMirror(...args);}
    finally{scene._useOrderIndependentTransparency=oit;scene.resetCachedMaterial();}
   };
   mirror.renderListPredicate=mesh=>mesh!==meshes.ground&&mesh!==meshes.symmetry&&
    !mesh.metadata?.wingViewHelper&&mesh.isEnabled()&&mesh.isVisible&&mesh.visibility>0&&mesh.getTotalVertices()>0;
   mirror.clearColor=new B.Color4(.06,.075,.09,1);
   metal=new B.PBRMaterial('view-ground-metallic',scene);metal.metallic=1;metal.roughness=.12;
   metal.albedoColor=B.Color3.FromHexString(groundAppearance.color);metal.reflectionTexture=mirror;metal.environmentIntensity=1.5;
   metal.backFaceCulling=false;metal.twoSidedLighting=true;metal.disableDepthWrite=true;
   materials.push(metal);reflectionSide();return metal;
  }
  const beforeRender=scene.onBeforeRenderObservable.add(()=>{if(groundAppearance.style==='metallic'&&meshes.ground?.isEnabled())reflectionSide();});
  function setGroundAppearance(value={}){
   const next={...GROUND_DEFAULTS,...value};
   if(!['solid','wireframe','translucent','metallic'].includes(next.style)||!/^#[0-9a-f]{6}$/i.test(next.color)||!Number.isFinite(next.opacity)||next.opacity<.03||next.opacity>1)throw Error('Invalid ground appearance.');
   groundAppearance=next;setGroundColor(next.color);
   groundMaterial.alpha=next.style==='translucent'?next.opacity:1;
   groundMaterial.setFloat('groundOpacity',groundMaterial.alpha);groundMaterial.setFloat('gridOnly',next.style==='wireframe'?1:0);
   groundMaterial.transparencyMode=groundMaterial.needAlphaBlending()?B.Material.MATERIAL_ALPHABLEND:B.Material.MATERIAL_OPAQUE;
   const mat=next.style==='metallic'?metallicMaterial():groundMaterial;
   if(meshes.ground){meshes.ground.material=mat;meshes.ground.metadata.ground_style=next.style;}
   return {...groundAppearance};
  }
  function updatePlane(name,points,mat){
   let mesh=meshes[name];
   if(!mesh){mesh=meshes[name]=new B.Mesh("view-plane-"+name,scene);mesh.material=mat;mesh.isPickable=false;mesh.renderingGroupId=0;mesh.setEnabled(false);
    mesh.metadata={wingViewHelper:true,plane:name};}
   const data=new B.VertexData();data.positions=points.flatMap(toView);data.indices=[0,1,2,0,2,3];
   data.normals=[];B.VertexData.ComputeNormals(data.positions,data.indices,data.normals,{useRightHandedSystem:true});
   data.uvs=points.flatMap(p=>name==="ground"?[p[0]/10,p[1]/10]:[0,0]);data.applyToMesh(mesh,true);mesh.refreshBoundingInfo();mesh.computeWorldMatrix(true);
  }
  function update(data,options=currentSettings){
   const next=settings(options);geometry=layout(data,next);currentSettings=next;model=data;
   // Preserve all finite input values. Heights beyond float32 rendering range
   // are outside any usable camera view, so suppress that helper safely.
   groundRenderable=Math.abs(next.z)<=1e30;
   updatePlane("ground",groundRenderable?geometry.ground:geometry.ground.map(p=>[p[0],p[1],0]),groundAppearance.style==='metallic'?metallicMaterial():groundMaterial);
   const coordinate=Math.max(1,...geometry.ground.flatMap(p=>[Math.abs(p[0]),Math.abs(p[1])]));
   // Frequencies smaller than a pixel fade to the average tile colour. Clamp
   // only the GPU uniform's extreme range, never the saved physical setting.
   groundMaterial.setFloat("gridSpacing",Math.max(coordinate*1e-12,Math.min(coordinate*1e12,next.spacing)));
   meshes.ground.metadata.grid_spacing_m=next.spacing;meshes.ground.metadata.ground_z_m=next.z;meshes.ground.metadata.ground_style=groundAppearance.style;reflectionSide();
   if(!groundRenderable)meshes.ground.setEnabled(false);
   updatePlane("symmetry",geometry.symmetry,symmetryMaterial);return geometry;
  }
  function configure(options){return model?update(model,options):null;}
  function setVisible(ground,symmetry){meshes.ground?.setEnabled(!!ground&&groundRenderable);meshes.symmetry?.setEnabled(!!symmetry);}
  function dispose(){scene.onBeforeRenderObservable.remove(beforeRender);for(const mesh of Object.values(meshes))mesh.dispose();for(const mat of materials)mat.dispose(false,false);mirror?.dispose();}
  return{meshes,get layout(){return geometry;},get groundAppearance(){return {...groundAppearance};},get reflection(){return mirror;},update,configure,setVisible,setGroundColor,setGroundAppearance,dispose};
 }
 return{settings,layout,create,GROUND_DEFAULTS};
});
