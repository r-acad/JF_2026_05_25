/* Non-FE context planes, excluded from model layers, picking and exports.
 * A procedural shader keeps adjustable grids cheap at any cell spacing.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingViewPlanes=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const toView=p=>[p[1],p[2],p[0]];
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
  function material(name,color,alpha){
   const mat=new B.StandardMaterial(name,scene);mat.diffuseColor=B.Color3.Black();mat.emissiveColor=B.Color3.FromHexString(color);
   mat.specularColor=B.Color3.Black();mat.disableLighting=true;mat.backFaceCulling=false;mat.twoSidedLighting=true;
   mat.alpha=alpha;mat.transparencyMode=B.Material.MATERIAL_ALPHABLEND;mat.disableDepthWrite=true;materials.push(mat);return mat;
  }
  const groundMaterial=new B.ShaderMaterial("view-ground-material",scene,{
   vertexSource:"precision highp float; attribute vec3 position; uniform mat4 worldViewProjection; uniform float gridSpacing; varying vec2 grid; void main(){grid=position.zx/gridSpacing;gl_Position=worldViewProjection*vec4(position,1.0);}",
   // Euclidean screen gradients express distance in pixels, independent of
   // zoom, projection or line direction. A narrow antialias ramp avoids thick
   // world-space grid bands; unresolved cells fade instead of flickering.
   fragmentSource:"#extension GL_OES_standard_derivatives : enable\nprecision highp float; varying vec2 grid; void main(){vec2 dx=dFdx(grid),dy=dFdy(grid);vec2 width=sqrt(dx*dx+dy*dy);float fade=clamp(max(width.x,width.y)*2.0,0.0,1.0);vec3 average=vec3(0.75,0.80,0.845);if(fade>=1.0){gl_FragColor=vec4(average,1.0);return;}float tile=mod(floor(grid.x)+floor(grid.y),2.0);vec3 color=mix(vec3(0.69,0.75,0.80),vec3(0.81,0.85,0.89),tile);vec2 line=abs(fract(grid+0.5)-0.5)/max(width,vec2(0.00000000000000000001));float edge=1.0-smoothstep(0.0,1.0,min(line.x,line.y));gl_FragColor=vec4(mix(mix(color,vec3(0.39,0.48,0.57),edge),average,fade),1.0);}",
  },{attributes:["position"],uniforms:["worldViewProjection","gridSpacing"],needAlphaBlending:false,needAlphaTesting:false});
  groundMaterial.backFaceCulling=false;groundMaterial.disableDepthWrite=true;materials.push(groundMaterial);
  const symmetryMaterial=material("view-symmetry-material","#a9c6df",.09);
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
   updatePlane("ground",groundRenderable?geometry.ground:geometry.ground.map(p=>[p[0],p[1],0]),groundMaterial);
   const coordinate=Math.max(1,...geometry.ground.flatMap(p=>[Math.abs(p[0]),Math.abs(p[1])]));
   // Frequencies smaller than a pixel fade to the average tile colour. Clamp
   // only the GPU uniform's extreme range, never the saved physical setting.
   groundMaterial.setFloat("gridSpacing",Math.max(coordinate*1e-12,Math.min(coordinate*1e12,next.spacing)));
   meshes.ground.metadata.grid_spacing_m=next.spacing;meshes.ground.metadata.ground_z_m=next.z;
   if(!groundRenderable)meshes.ground.setEnabled(false);
   updatePlane("symmetry",geometry.symmetry,symmetryMaterial);return geometry;
  }
  function configure(options){return model?update(model,options):null;}
  function setVisible(ground,symmetry){meshes.ground?.setEnabled(!!ground&&groundRenderable);meshes.symmetry?.setEnabled(!!symmetry);}
  function dispose(){for(const mesh of Object.values(meshes))mesh.dispose();for(const mat of materials)mat.dispose();}
  return{meshes,get layout(){return geometry;},update,configure,setVisible,dispose};
 }
 return{settings,layout,create};
});
