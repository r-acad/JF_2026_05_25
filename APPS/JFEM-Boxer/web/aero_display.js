/* Native airfoil definitions and an offline studio reflection for the aero loft.
 * Helpers are display-only; material selection never changes FE geometry/results.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingAeroDisplay=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const SECTION_COLOR="#e6b8ff";
 // Discrete Gaussian curvature: angle defect / mixed Voronoi dual area.
 // Open boundaries, non-manifold vertices, collapsed triangles and the known
 // sharp trailing edge have no smooth-surface estimate and remain unavailable.
 // Coordinates are metres, so the result is in m^-2. No display-scale or
 // percentile clipping is applied to the reported range.
 function gaussianCurvature(positions,indices,{excluded=[]}={}){
  const count=positions.length/3,angles=new Float64Array(count),areas=new Float64Array(count),bad=new Uint8Array(count),edges=new Map();
  for(const id of excluded)if(id>=0&&id<count)bad[id]=1;
  const edge=(a,b)=>{const key=a<b?a+":"+b:b+":"+a,record=edges.get(key);if(record)record[2]++;else edges.set(key,[a,b,1]);};
  for(let k=0;k<indices.length;k+=3){
   const ids=[indices[k],indices[k+1],indices[k+2]];
   if(ids.some(id=>!Number.isInteger(id)||id<0||id>=count))throw Error("Invalid aerodynamic surface connectivity.");
   const points=ids.map(id=>[positions[3*id],positions[3*id+1],positions[3*id+2]]);
   const ab=points[1].map((v,i)=>v-points[0][i]),ac=points[2].map((v,i)=>v-points[0][i]);
   const cross=[ab[1]*ac[2]-ab[2]*ac[1],ab[2]*ac[0]-ab[0]*ac[2],ab[0]*ac[1]-ab[1]*ac[0]],twiceArea=Math.hypot(...cross);
   const side2=points.map((p,i)=>p.reduce((sum,v,j)=>sum+(v-points[(i+1)%3][j])**2,0));
   if(!Number.isFinite(twiceArea)||twiceArea<=1e-14*Math.max(...side2)||new Set(ids).size<3){ids.forEach(id=>bad[id]=1);continue;}
   const dots=points.map((p,i)=>p.reduce((sum,v,j)=>sum+(points[(i+1)%3][j]-v)*(points[(i+2)%3][j]-v),0));
   const obtuse=dots.findIndex(v=>v<0);
   for(let i=0;i<3;i++){
    angles[ids[i]]+=Math.atan2(twiceArea,dots[i]);
    areas[ids[i]]+=obtuse>=0?twiceArea*(obtuse===i?.25:.125):
      (side2[i]*dots[(i+2)%3]+side2[(i+2)%3]*dots[(i+1)%3])/(8*twiceArea);
    edge(ids[i],ids[(i+1)%3]);
   }
  }
  for(const[a,b,n]of edges.values())if(n!==2){bad[a]=1;bad[b]=1;}
  const values=new Float64Array(count);values.fill(NaN);let min=Infinity,max=-Infinity,available=0;
  for(let i=0;i<count;i++)if(!bad[i]&&areas[i]>0){
   const defect=2*Math.PI-angles[i],value=Math.abs(defect)<2e-12?0:defect/areas[i];
   if(Number.isFinite(value)){values[i]=value;min=Math.min(min,value);max=Math.max(max,value);available++;}
  }
  return{values,min:available?min:0,max:available?max:0,available,unavailable:count-available};
 }
 function floats(value){if(value instanceof Float32Array)return value;if(Array.isArray(value))return Float32Array.from(value);if(value instanceof ArrayBuffer)return new Float32Array(value);if(ArrayBuffer.isView(value)){const bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength);return new Float32Array(bytes.byteOffset%4?bytes.slice().buffer:bytes.buffer,bytes.byteOffset%4?0:bytes.byteOffset,bytes.byteLength/4);}return new Float32Array();}
 function sectionLayout(data){return(data?.aero?.sections||[]).map((section,index)=>{const xyz=floats(section.xyz);if(xyz.length<6||xyz.length%3||!Array.from(xyz).every(Number.isFinite))throw Error("Airfoil section has invalid native coordinates.");const eta=section.eta;if(!Number.isFinite(eta)||eta<0||eta>1)throw Error("Airfoil section ETA must be between zero and one.");return{eta,name:String(section.name||"Airfoil "+(index+1)),kind:section.kind||"intermediate",source:String(section.source||""),count:xyz.length/3,xyz,positions:Array.from({length:xyz.length/3},(_,i)=>[xyz[3*i+1],xyz[3*i+2],xyz[3*i]])};});}
 // A bright neutral studio gives polished aluminium broad, readable reflections.
 // Procedural bytes keep rendering portable and avoid remote texture requests.
 function studioFaces(size=64){
  const directions=[(u,v)=>[1,-v,-u],(u,v)=>[-1,-v,u],(u,v)=>[u,1,v],(u,v)=>[u,-1,-v],(u,v)=>[u,-v,1],(u,v)=>[-u,-v,-1]];
  const panel=(x,z,cx,cz,width,height)=>Math.exp(-Math.pow(Math.abs((x-cx)/width),8)-Math.pow(Math.abs((z-cz)/height),8));
  return directions.map(direction=>{const pixels=new Uint8Array(size*size*4);for(let row=0;row<size;row++)for(let col=0;col<size;col++){
   let[x,y,z]=direction(2*(col+.5)/size-1,2*(row+.5)/size-1);const n=Math.hypot(x,y,z);x/=n;y/=n;z/=n;
   const sky=.36+.18*Math.max(0,y),horizon=.12*Math.exp(-Math.pow(y/.18,2));
   const ceiling=y>0?Math.max(panel(x/y,z/y,-.55,-.2,.2,2.4),panel(x/y,z/y,.85,.1,.13,2.8)):0;
   const side=z<0?panel(x/-z,y/-z,-.3,.35,1.5,.12):.65*panel(x/z,y/z,.2,.25,1.3,.18);
   const below=y<0?.55*panel(x/-y,z/-y,0,-.4,1.6,.32):0;
   const light=Math.max(ceiling,side,below),floor=y<0?.08:0,base=sky+horizon+floor;
   const colors=[base*.98+light*.58,base+light*.59,base*1.025+light*.60],i=4*(row*size+col);for(let c=0;c<3;c++)pixels[i+c]=Math.round(255*Math.min(1,colors[c]));pixels[i+3]=255;
  }return pixels;});
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,parent=null,data}){
  const sections=sectionLayout(data),meshes=[],originals=new Map(),normalBuffers=new Map(),surfaces=new Map();let steel=null,environment=null,disposed=false;
  for(const[index,section]of sections.entries()){
   const mesh=B.MeshBuilder.CreateLines("defined-airfoil-"+index,{points:section.positions.map(p=>B.Vector3.FromArray(p)),updatable:false},scene);mesh.color=B.Color3.FromHexString(SECTION_COLOR);mesh.alpha=1;mesh.isPickable=false;mesh.parent=parent;mesh.renderingGroupId=0;mesh.metadata={wingViewHelper:true,airfoilDefinition:true,eta:section.eta,name:section.name,source:section.source,kind:section.kind};mesh.setEnabled(false);meshes.push(mesh);
  }
  function material(){if(steel)return steel;
   environment=new B.RawCubeTexture(scene,studioFaces(),64,B.Engine.TEXTUREFORMAT_RGBA,B.Engine.TEXTURETYPE_UNSIGNED_BYTE,true,false,B.Texture.TRILINEAR_SAMPLINGMODE);environment.name="aero-local-studio";environment.coordinatesMode=B.Texture.CUBIC_MODE;environment.gammaSpace=false;
   // Keep the legacy "steel" choice/internal material identity so saved
   // Studies retain their metallic appearance; its finish is now aluminium.
   steel=new B.PBRMaterial("aero-polished-steel",scene);steel.albedoColor=new B.Color3(.91,.92,.94);steel.metallic=1;steel.roughness=.18;steel.reflectionTexture=environment;steel.environmentIntensity=1.5;steel.directIntensity=.9;steel.maxSimultaneousLights=6;steel.backFaceCulling=false;steel.twoSidedLighting=true;steel.alpha=1;steel.transparencyMode=B.Material.MATERIAL_OPAQUE;steel.wireframe=false;steel.separateCullingPass=false;steel.disableDepthWrite=false;return steel;
  }
  function attach(mesh,{quads,nLoop=0}={}){
   const pairs=[],seen=new Set();
   for(let i=0;i<quads.length;i+=4)for(let j=0;j<4;j++){
    const a=quads[i+j],b=quads[i+(j+1)%4],key=a<b?a+":"+b:b+":"+a;
    if(!seen.has(key)){seen.add(key);pairs.push(a,b);}
   }
   const count=mesh.getTotalVertices(),excluded=[];
   // The supplied closed airfoil ring starts at the sharp trailing edge.
   if(nLoop>0)for(let id=0;id<count;id+=nLoop)excluded.push(id);
   const info={mesh,pairs:Int32Array.from(pairs),excluded,wire:null,curvature:null,curvatureDirty:true,settings:null};
   surfaces.set(mesh,info);return info;
  }
  function ensureWire(info){
   if(info.wire)return info.wire;
   const wire=new B.LinesMesh("aero-quad-wireframe",scene,null,undefined,false,true,false),vd=new B.VertexData();
   info.wirePositions=new Float32Array(info.pairs.length*3);info.wireColors=new Float32Array(info.pairs.length*4).fill(1);
   vd.positions=info.wirePositions;vd.indices=Int32Array.from(info.pairs,(_,i)=>i);vd.colors=info.wireColors;vd.applyToMesh(wire,true);
   wire.color=B.Color3.White();wire.alpha=1;wire.parent=info.mesh.parent;wire.isPickable=false;wire.renderingGroupId=1;
   // Opaque line primitives survive transparent composition. A small depth
   // bias reveals the loft at coincident FE skins without drawing through it.
   wire.material.zOffset=-2;wire.material.zOffsetUnits=-2;wire.material.disableDepthWrite=false;
   wire.metadata={wingViewHelper:true,aeroWireframe:true};wire.setEnabled(false);info.wire=wire;
   updateWire(info);return wire;
  }
  function updateWire(info){
   if(!info.wire)return;
   const positions=info.mesh.getVerticesData(B.VertexBuffer.PositionKind);
   for(let i=0;i<info.pairs.length;i++){const source=3*info.pairs[i];for(let j=0;j<3;j++)info.wirePositions[3*i+j]=positions[source+j];}
   info.wire.updateVerticesData(B.VertexBuffer.PositionKind,info.wirePositions,true,false);
  }
  function curvature(mesh){
   const info=surfaces.get(mesh);if(!info)return null;
   if(info.curvatureDirty){info.curvature=gaussianCurvature(mesh.getVerticesData(B.VertexBuffer.PositionKind),mesh.getIndices(),{excluded:info.excluded});info.curvatureDirty=false;}
   return info.curvature;
  }
  function paint(info){
   const settings=info.settings;if(!settings)return;
   const {color="#b8cee4",curvature:enabled=false,colorAt=()=>[.5,.5,.5],range=value=>value}=settings;
   const field=enabled?curvature(info.mesh):null,bounds=field?range(field):null,base=B.Color3.FromHexString(color),count=info.mesh.getTotalVertices();
   info.colors??=new Float32Array(count*4);
   for(let i=0;i<count;i++){
    const value=field?.values[i],rgb=field?(Number.isFinite(value)?colorAt(bounds.max>bounds.min?(value-bounds.min)/(bounds.max-bounds.min):.5,value,bounds):[.42,.45,.49]):[1,1,1];
    info.colors.set([...rgb,1],4*i);
   }
   info.mesh.updateVerticesData(B.VertexBuffer.ColorKind,info.colors,false,false);
   const m=info.mesh.material,materialColor=field?B.Color3.White():base;
   if(m instanceof B.PBRMaterial)m.albedoColor=materialColor;else{m.diffuseColor=materialColor;m.emissiveColor=materialColor.scale(field ? .10 : .015);}
   if(info.wire){
    for(let i=0;i<info.pairs.length;i++){
     const vertex=info.pairs[i],rgb=field?info.colors.subarray(4*vertex,4*vertex+3):[base.r,base.g,base.b];
     info.wireColors.set([...rgb,1],4*i);
    }
    info.wire.updateVerticesData(B.VertexBuffer.ColorKind,info.wireColors,false,false);
   }
   return field;
  }
  function updateNormals(mesh){
   const positions=mesh.getVerticesData(B.VertexBuffer.PositionKind),indices=mesh.getIndices();if(!positions||!indices)return false;
   let normals=normalBuffers.get(mesh);if(!normals||normals.length!==positions.length){normals=new Float32Array(positions.length);normalBuffers.set(mesh,normals);}
   B.VertexData.ComputeNormals(positions,indices,normals,{useRightHandedSystem:!!scene.useRightHandedSystem});mesh.updateVerticesData(B.VertexBuffer.NormalKind,normals,false,false);
   const info=surfaces.get(mesh);if(info){info.curvatureDirty=true;updateWire(info);if(info.settings?.curvature)paint(info);}return true;
  }
  function apply(mesh,{deformed=false,style="wireframe",visible=true,color="#b8cee4",curvature:showCurvature=false,...options}={}){
   if(disposed||!mesh)return false;
   const selected=style==="steel"||style==="metallic",info=surfaces.get(mesh);
   if(!originals.has(mesh))originals.set(mesh,mesh.material);
   const changed=mesh.material!==(selected?material():originals.get(mesh));mesh.material=selected?steel:originals.get(mesh);
   mesh.hasVertexAlpha=false;mesh.material.wireframe=false;mesh.material.alpha=style==="translucent"?.28:1;
   mesh.material.transparencyMode=style==="translucent"?B.Material.MATERIAL_ALPHABLEND:B.Material.MATERIAL_OPAQUE;
   mesh.material.separateCullingPass=false;mesh.material.disableDepthWrite=false;
   if(info){
    info.settings={...options,color,curvature:showCurvature};
    if(style==="wireframe")ensureWire(info);
    mesh.setEnabled(visible&&style!=="wireframe");info.wire?.setEnabled(visible&&style==="wireframe");
    paint(info);
   }else{
    // Standalone/legacy callers without a quad topology retain triangle wires.
    mesh.material.wireframe=style==="wireframe";mesh.setEnabled(visible);
   }
   if(changed)updateNormals(mesh);return selected;
  }
  function dispose(){if(disposed)return;disposed=true;for(const[mesh,original]of originals)if(!mesh.isDisposed())mesh.material=original;originals.clear();normalBuffers.clear();for(const info of surfaces.values())info.wire?.dispose(false,true);surfaces.clear();for(const mesh of meshes)mesh.dispose(false,true);steel?.dispose(false,false);environment?.dispose();steel=null;environment=null;}
  return{meshes,sections,count:sections.length,attach,apply,updateNormals,curvature,dispose,wireFor:mesh=>surfaces.get(mesh)?.wire,get steelMaterial(){return steel;},get environment(){return environment;}};
 }
 return{SECTION_COLOR,sectionLayout,studioFaces,gaussianCurvature,create};
});
