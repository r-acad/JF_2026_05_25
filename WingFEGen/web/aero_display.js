/* Native airfoil definitions and an offline studio reflection for the aero loft.
 * Helpers are display-only; material selection never changes FE geometry/results.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingAeroDisplay=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const SECTION_COLOR="#e6b8ff";
 function floats(value){if(value instanceof Float32Array)return value;if(Array.isArray(value))return Float32Array.from(value);if(value instanceof ArrayBuffer)return new Float32Array(value);if(ArrayBuffer.isView(value)){const bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength);return new Float32Array(bytes.byteOffset%4?bytes.slice().buffer:bytes.buffer,bytes.byteOffset%4?0:bytes.byteOffset,bytes.byteLength/4);}return new Float32Array();}
 function sectionLayout(data){return(data?.aero?.sections||[]).map((section,index)=>{const xyz=floats(section.xyz);if(xyz.length<6||xyz.length%3||!Array.from(xyz).every(Number.isFinite))throw Error("Airfoil section has invalid native coordinates.");const eta=section.eta;if(!Number.isFinite(eta)||eta<0||eta>1)throw Error("Airfoil section ETA must be between zero and one.");return{eta,name:String(section.name||"Airfoil "+(index+1)),kind:section.kind||"intermediate",source:String(section.source||""),count:xyz.length/3,xyz,positions:Array.from({length:xyz.length/3},(_,i)=>[xyz[3*i+1],xyz[3*i+2],xyz[3*i]])};});}
 // A bright neutral studio gives polished aluminium broad, readable reflections.
 // Procedural bytes keep rendering portable and avoid remote texture requests.
 function studioFaces(size=64){
  const directions=[(u,v)=>[1,-v,-u],(u,v)=>[-1,-v,u],(u,v)=>[u,1,v],(u,v)=>[u,-1,-v],(u,v)=>[u,-v,1],(u,v)=>[-u,-v,-1]];
  const panel=(x,z,cx,cz,width,height)=>Math.exp(-Math.pow(Math.abs((x-cx)/width),8)-Math.pow(Math.abs((z-cz)/height),8));
  return directions.map(direction=>{const pixels=new Uint8Array(size*size*4);for(let row=0;row<size;row++)for(let col=0;col<size;col++){
   let[x,y,z]=direction(2*(col+.5)/size-1,2*(row+.5)/size-1);const n=Math.hypot(x,y,z);x/=n;y/=n;z/=n;
   const sky=.24+.20*Math.max(0,y),horizon=.10*Math.exp(-Math.pow(y/.18,2));
   const ceiling=y>0?Math.max(panel(x/y,z/y,-.55,-.2,.2,2.4),panel(x/y,z/y,.85,.1,.13,2.8)):0;
   const side=z<0?panel(x/-z,y/-z,-.3,.35,1.5,.09):0;
   const light=Math.max(ceiling,side),floor=y<0?.06:0,base=sky+horizon+floor;
   const colors=[base*.98+light*.70,base+light*.71,base*1.025+light*.72],i=4*(row*size+col);for(let c=0;c<3;c++)pixels[i+c]=Math.round(255*Math.min(1,colors[c]));pixels[i+3]=255;
  }return pixels;});
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,parent=null,data}){
  const sections=sectionLayout(data),meshes=[],originals=new Map(),normalBuffers=new Map();let steel=null,environment=null,disposed=false;
  for(const[index,section]of sections.entries()){
   const mesh=B.MeshBuilder.CreateLines("defined-airfoil-"+index,{points:section.positions.map(p=>B.Vector3.FromArray(p)),updatable:false},scene);mesh.color=B.Color3.FromHexString(SECTION_COLOR);mesh.alpha=1;mesh.isPickable=false;mesh.parent=parent;mesh.renderingGroupId=0;mesh.metadata={wingViewHelper:true,airfoilDefinition:true,eta:section.eta,name:section.name,source:section.source,kind:section.kind};mesh.setEnabled(false);meshes.push(mesh);
  }
  function material(){if(steel)return steel;
   environment=new B.RawCubeTexture(scene,studioFaces(),64,B.Engine.TEXTUREFORMAT_RGBA,B.Engine.TEXTURETYPE_UNSIGNED_BYTE,true,false,B.Texture.TRILINEAR_SAMPLINGMODE);environment.name="aero-local-studio";environment.coordinatesMode=B.Texture.CUBIC_MODE;environment.gammaSpace=false;
   // Keep the legacy "steel" choice/internal material identity so saved
   // Studies retain their metallic appearance; its finish is now aluminium.
   steel=new B.PBRMaterial("aero-polished-steel",scene);steel.albedoColor=new B.Color3(.91,.92,.94);steel.metallic=1;steel.roughness=.18;steel.reflectionTexture=environment;steel.environmentIntensity=1.5;steel.directIntensity=.9;steel.backFaceCulling=false;steel.twoSidedLighting=true;steel.alpha=1;steel.transparencyMode=B.Material.MATERIAL_OPAQUE;steel.wireframe=false;steel.separateCullingPass=false;steel.disableDepthWrite=false;return steel;
  }
  function updateNormals(mesh){if(!steel||mesh.material!==steel)return false;const positions=mesh.getVerticesData(B.VertexBuffer.PositionKind),indices=mesh.getIndices();if(!positions||!indices)return false;let normals=normalBuffers.get(mesh);if(!normals||normals.length!==positions.length){normals=new Float32Array(positions.length);normalBuffers.set(mesh,normals);}B.VertexData.ComputeNormals(positions,indices,normals,{useRightHandedSystem:!!scene.useRightHandedSystem});mesh.updateVerticesData(B.VertexBuffer.NormalKind,normals,false,false);return true;}
  function apply(mesh,{deformed=false,style="wireframe"}={}){
   if(disposed||!mesh)return false;const selected=style==="steel";
   if(selected){if(!originals.has(mesh))originals.set(mesh,mesh.material);const changed=mesh.material!==material();mesh.material=steel;mesh.hasVertexAlpha=false;steel.alpha=1;steel.transparencyMode=B.Material.MATERIAL_OPAQUE;steel.wireframe=false;steel.separateCullingPass=false;steel.disableDepthWrite=false;if(changed)updateNormals(mesh);return true;}
   if(originals.has(mesh)){mesh.material=originals.get(mesh);originals.delete(mesh);}return false;
  }
  function dispose(){if(disposed)return;disposed=true;for(const[mesh,original]of originals)if(!mesh.isDisposed())mesh.material=original;originals.clear();normalBuffers.clear();for(const mesh of meshes)mesh.dispose(false,true);steel?.dispose(false,false);environment?.dispose();steel=null;environment=null;}
  return{meshes,sections,count:sections.length,apply,updateNormals,dispose,get steelMaterial(){return steel;},get environment(){return environment;}};
 }
 return{SECTION_COLOR,sectionLayout,studioFaces,create};
});
