/* Projected vector snapshot of the current Babylon scene. No canvas bitmap is
 * embedded. Textures/PBR lighting are deliberately reduced to flat colors. */
(function(root,factory){const api=factory(root);if(typeof module==="object"&&module.exports)module.exports=api;else root.WingViewportSVG=api;})(typeof globalThis!=="undefined"?globalThis:this,function(root){
 "use strict";
 const escape=value=>String(value).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&apos;"}[c]));
 const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),finite=Number.isFinite;
 const number=x=>{if(!finite(x))throw Error("SVG projection produced a non-finite coordinate.");return String(Number(x.toFixed(4)));};
 const rgb=value=>"#"+value.slice(0,3).map(v=>Math.round(clamp(v)*255).toString(16).padStart(2,"0")).join("");
 const color=value=>value&&[value.r,value.g,value.b].every(finite)?[value.r,value.g,value.b]:[.65,.72,.8];
 const hex=value=>typeof value==="string"&&/^#[0-9a-f]{6}$/i.test(value)?value:"#8fa8c2";
 const midpointColor=stops=>{const sorted=stops.slice().sort((a,b)=>a.offset-b.offset),left=sorted.filter(stop=>stop.offset<=.5).at(-1)||sorted[0],right=sorted.find(stop=>stop.offset>=.5)||sorted.at(-1),t=right.offset===left.offset?0:(.5-left.offset)/(right.offset-left.offset),decode=value=>[1,3,5].map(i=>parseInt(hex(value).slice(i,i+2),16)/255);return rgb(interpolate(decode(left.color),decode(right.color),t));};
 function textureLabel(mesh,source){
  const materials=(mesh.material?.subMaterials||[mesh.material||source.material]).filter(Boolean),dynamic=materials.some(material=>material.getActiveTextures?.().some(texture=>texture.getClassName?.()==="DynamicTexture"));
  return dynamic&&(mesh.metadata?.wingLabel===true||mesh.metadata?.isLabel===true||/(?:^|[-_ ])(?:label|text)(?:[-_ ]|$)/i.test(mesh.name||""));
 }
 const pause=()=>new Promise(resolve=>setTimeout(resolve,0));
 const interpolate=(a,b,t)=>a.map((v,i)=>v+t*(b[i]-v));
 const planes=halfZ=>[p=>p[3]+p[0],p=>p[3]-p[0],p=>p[3]+p[1],p=>p[3]-p[1],p=>halfZ?p[2]:p[3]+p[2],p=>p[3]-p[2]];
 function clipPolygon(input,clipPlanes){let polygon=input;for(const distance of clipPlanes){if(!polygon.length)break;const result=[];for(let i=0;i<polygon.length;i++){const a=polygon[i],b=polygon[(i+1)%polygon.length],da=distance(a),db=distance(b),insideA=da>=0,insideB=db>=0;if(insideA)result.push(a);if(insideA!==insideB)result.push(interpolate(a,b,da/(da-db)));}polygon=result;}return polygon.filter(p=>p[3]>1e-12);}
 function clipSegment(a,b,clipPlanes){let low=0,high=1;for(const distance of clipPlanes){const da=distance(a),db=distance(b);if(da<0&&db<0)return null;if(da<0||db<0){const t=da/(da-db);if(da<0)low=Math.max(low,t);else high=Math.min(high,t);if(low>high)return null;}}const result=[interpolate(a,b,low),interpolate(a,b,high)];return result.every(p=>p[3]>1e-12)?result:null;}
 function transform(p,m){const[x,y,z]=p;return[x*m[0]+y*m[4]+z*m[8]+m[12],x*m[1]+y*m[5]+z*m[9]+m[13],x*m[2]+y*m[6]+z*m[10]+m[14],x*m[3]+y*m[7]+z*m[11]+m[15]];}
 const screen=(p,v)=>({x:v.x+(p[0]/p[3]+1)*v.width/2,y:v.y+(1-p[1]/p[3])*v.height/2,z:p[2]/p[3]});
 const area=p=>p.reduce((sum,a,i)=>{const b=p[(i+1)%p.length];return sum+a.x*b.y-b.x*a.y;},0);
 const bounds=p=>({left:Math.min(...p.map(p=>p.x)),right:Math.max(...p.map(p=>p.x)),top:Math.min(...p.map(p=>p.y)),bottom:Math.max(...p.map(p=>p.y))});
 function sphereBounds(mesh,source,geometry){
  if(!(mesh.metadata?.svgPrimitive==="sphere"||source.metadata?.svgPrimitive==="sphere"||/^(?:NODES|RBE3_NODES|FUEL_RBE3_NODES|SPC)(?:-\d+)?$/.test(source.name||"")))return null;
  if(geometry.colors)return null;if(geometry.sphereBounds)return geometry.sphereBounds;const minimum=[Infinity,Infinity,Infinity],maximum=[-Infinity,-Infinity,-Infinity];for(let i=0;i<geometry.positions.length;i++) {const a=i%3;minimum[a]=Math.min(minimum[a],geometry.positions[i]);maximum[a]=Math.max(maximum[a],geometry.positions[i]);}
  const center=minimum.map((n,i)=>(n+maximum[i])/2),radii=minimum.map((n,i)=>(maximum[i]-n)/2);return geometry.sphereBounds=radii.every(r=>r>0)?{center,radii}:null;
 }
 function sphereOutline(sphere,world,viewProjection,camera,B,viewport){
  const local=B.Matrix.Scaling(...sphere.radii).multiply(B.Matrix.Translation(...sphere.center)).multiply(world);if(!finite(local.determinant())||local.determinant()===0)return null;const inverse=local.clone().invert(),perspective=camera.mode!==B.Camera.ORTHOGRAPHIC_CAMERA;
  const eye=perspective?B.Vector3.TransformCoordinates(camera.position,inverse):B.Vector3.TransformNormal(camera.direction,inverse),length=eye.length();if(!finite(length)||length<1e-12||perspective&&length<=1+1e-7)return null;
  const n=eye.scale(1/length),a=B.Vector3.Cross(n,Math.abs(n.y)<.8?B.Axis.Y:B.Axis.X).normalize(),b=B.Vector3.Cross(n,a).normalize(),origin=perspective?n.scale(1/length):B.Vector3.Zero(),radius=perspective?Math.sqrt(1-1/(length*length)):1,matrix=local.multiply(viewProjection).m;
  const point=angle=>transform(origin.add(a.scale(radius*Math.cos(angle))).add(b.scale(radius*Math.sin(angle))).asArray(),matrix),sample=Array.from({length:16},(_,i)=>point(2*Math.PI*i/16));if(sample.some(p=>p[3]<=1e-8))return null;
  const projected=sample.map(p=>screen(p,viewport)),box=bounds(projected),pixelRadius=Math.max(box.right-box.left,box.bottom-box.top)/2,segments=Math.max(12,Math.min(256,Math.ceil(Math.PI*Math.sqrt(Math.max(1,pixelRadius)/.4))));return Array.from({length:segments},(_,i)=>point(2*Math.PI*i/segments));
 }
 function snapshotMaterial(material,mesh,source,B,warn){
  const line=source.getClassName?.().includes("Lines"),mode=line?B.Material.LineListDrawMode:material?.wireframe?B.Material.WireFrameFillMode:material?.fillMode??B.Material.TriangleFillMode;
  let base=line?color(mesh.color||source.color):color(material?.albedoColor||material?.diffuseColor||material?.emissiveColor);
  if(!line&&material?.disableLighting&&material?.emissiveColor&&color(material.emissiveColor).some(v=>v>0))base=color(material.emissiveColor);
  if(!line&&material?.getClassName?.().includes("PBR"))warn("Metallic reflections and lighting are represented by flat material/vertex colors.");
  if(!line&&material?.getActiveTextures?.().length)warn("Texture images, normal maps and alpha-cutout patterns are simplified to flat colors.");
  if(!line&&material?.getClassName?.()==="ShaderMaterial"&&mesh.metadata?.plane!=="ground")warn("Custom shader appearance is simplified to flat colors.");
  const alpha=clamp((material?.alpha??1)*(mesh.visibility??1)*(line?(mesh.alpha??source.alpha??1):1));
  return{mode,base,alpha,depthWrite:material?.disableDepthWrite!==true,depthTest:material?.depthFunction!==B.Engine.ALWAYS,backface:!line&&material?.backFaceCulling===true,orientation:material?.sideOrientation??source.overrideMaterialSideOrientation??source.sideOrientation,vertexColors:source.useVertexColors!==false,vertexAlpha:line?source.useVertexAlpha!==false:source.hasVertexAlpha===true,lineWidth:Math.max(.5,Math.min(12,mesh.edgesWidth||1)),pointSize:Math.max(1,Math.min(30,material?.pointSize||3)),zOffset:material?.zOffset||0};
 }
 function legendSVG(legends,width,height){
  if(!Array.isArray(legends)||legends.length>32)throw Error("SVG export supports up to 32 color scales.");
  const defs=[],output=[],panelWidth=Math.min(224,Math.max(140,width-24)),panelHeight=147;
  legends.forEach((legend,index)=>{if(legend.hidden||legend.collapsed)return;if(!finite(legend.min)||!finite(legend.max))return;
   let stops=Array.isArray(legend.stops)&&legend.stops.length?legend.stops:[{offset:0,color:"#2355dd"},{offset:.5,color:"#35bc80"},{offset:1,color:"#e74633"}];if(stops.length>256)throw Error("An SVG color scale supports up to 256 color stops.");
   if(stops.some(stop=>!finite(stop.offset)||stop.offset<0||stop.offset>1))throw Error("Invalid SVG color stop position.");if(legend.min===legend.max){const color=midpointColor(stops);stops=[{offset:0,color},{offset:1,color}];}
   const id="color-scale-"+index;defs.push(`<linearGradient id="${id}" x1="0" y1="1" x2="0" y2="0">${stops.map(stop=>{if(!finite(stop.offset)||stop.offset<0||stop.offset>1)throw Error("Invalid SVG color stop position.");return`<stop offset="${stop.offset}" stop-color="${hex(stop.color)}"/>`;}).join("")}</linearGradient>`);
   const rows=Math.max(1,Math.floor((height-24)/(panelHeight+8))),column=Math.floor(index/rows),row=index%rows;
   const x=finite(legend.x)?legend.x:Math.max(8,width-12-panelWidth-column*(panelWidth+8)),y=finite(legend.y)?legend.y:12+row*(panelHeight+8),title=String(legend.title||"Results"),units=String(legend.units||""),label=value=>Math.abs(value)>=100?value.toFixed(2):String(Number(value.toPrecision(5)));
   const ticks=legend.ticks||[0,.5,1].map(offset=>({offset,value:legend.min+(legend.max-legend.min)*offset}));
   output.push(`<g class="color-scale" aria-label="${escape(title)}"><rect x="${number(x)}" y="${number(y)}" width="${panelWidth}" height="${panelHeight}" rx="5" fill="#112335" fill-opacity=".92" stroke="#6b8297"/><text x="${number(x+10)}" y="${number(y+19)}" fill="#eef6ff" font-size="12" font-weight="600">${escape(title.slice(0,35))}</text><text x="${number(x+10)}" y="${number(y+35)}" fill="#bcd0df" font-size="10">${escape((legend.subtitle||units).slice(0,42))}</text><rect x="${number(x+13)}" y="${number(y+45)}" width="18" height="88" fill="url(#${id})"/>${ticks.map(t=>{const offset=finite(t.offset)?clamp(t.offset):legend.max===legend.min?.5:clamp((t.value-legend.min)/(legend.max-legend.min));const text=t.label??label(t.value??legend.min+(legend.max-legend.min)*offset);return`<text x="${number(x+41)}" y="${number(y+133-88*offset+4)}" fill="#e5eff7" font-size="11">${escape(text)}${units?" "+escape(units):""}</text>`;}).join("")}</g>`);
  });return{defs:defs.join(""),body:output.join("")};
 }
 // An indexed depth comparison clips line segments to visible intervals. This
 // keeps bars/edges behind opaque skins out of a vector export even when their
 // Babylon rendering group is later than the surface group.
 async function occlusionIndex(polygons,limits,stats,yieldProgress){
  const size=48,cells=new Map();let references=0;
  let processed=0;for(const primitive of polygons){if(++processed%512===0)await yieldProgress();if(!primitive.depthWrite||primitive.alpha<.999)continue;const p=primitive.points;
   for(let i=1;i<p.length-1;i++){const a=p[0],b=p[i],c=p[i+1],den=(b.y-c.y)*(a.x-c.x)+(c.x-b.x)*(a.y-c.y);if(Math.abs(den)<1e-12)continue;const box=bounds([a,b,c]),triangle={a,b,c,den,box};
    for(let x=Math.floor(box.left/size);x<=Math.floor(box.right/size);x++)for(let y=Math.floor(box.top/size);y<=Math.floor(box.bottom/size);y++){if(++references>limits.maxOcclusionReferences)throw Error("SVG visibility index exceeds its resource limit. Hide some surfaces and try again.");const key=x+":"+y;if(!cells.has(key))cells.set(key,[]);cells.get(key).push(triangle);}
   }
  }
  const bary=(p,t)=>{const a=((t.b.y-t.c.y)*(p.x-t.c.x)+(t.c.x-t.b.x)*(p.y-t.c.y))/t.den,b=((t.c.y-t.a.y)*(p.x-t.c.x)+(t.a.x-t.c.x)*(p.y-t.c.y))/t.den;return[a,b,1-a-b];};
  return line=>{if(line.depthTest===false)return[line];const[a,b]=line.points,box=bounds(line.points),candidates=new Set();for(let x=Math.floor(box.left/size);x<=Math.floor(box.right/size);x++)for(let y=Math.floor(box.top/size);y<=Math.floor(box.bottom/size);y++)for(const t of cells.get(x+":"+y)||[])candidates.add(t);
   const hidden=[];for(const t of candidates){if(++stats.lineOcclusionTests>limits.maxOcclusionTests)throw Error("SVG hidden-line calculation exceeds its resource limit. Hide some dense line layers and try again.");if(box.right<t.box.left||box.left>t.box.right||box.bottom<t.box.top||box.top>t.box.bottom)continue;
    const wa=bary(a,t),wb=bary(b,t);let low=0,high=1;const constrain=(v0,v1)=>{if(v0<0&&v1<0)return false;if(v0<0)low=Math.max(low,-v0/(v1-v0));else if(v1<0)high=Math.min(high,-v0/(v1-v0));return low<high;};let inside=true;for(let k=0;k<3;k++)if(!constrain(wa[k]+1e-9,wb[k]+1e-9)){inside=false;break;}if(!inside)continue;
    const za=wa[0]*t.a.z+wa[1]*t.b.z+wa[2]*t.c.z,zb=wb[0]*t.a.z+wb[1]*t.b.z+wb[2]*t.c.z;
    if(constrain(a.z-za-2e-7,b.z-zb-2e-7))hidden.push([low,high]);
   }
   hidden.sort((a,b)=>a[0]-b[0]);const spans=[];let next=0;for(const[low,high]of hidden){if(low>next+1e-8)spans.push([next,low]);next=Math.max(next,high);if(next>=1)break;}if(next<1-1e-8)spans.push([next,1]);return spans.map(([lo,hi])=>({...line,points:[lo,hi].map(t=>({x:a.x+t*(b.x-a.x),y:a.y+t*(b.y-a.y),z:a.z+t*(b.z-a.z)}))}));
  };
 }
 async function exportScene(scene,camera,engine,options={}){
  const B=options.BABYLON||root.BABYLON;if(!B||!scene||!camera||!engine)throw Error("SVG export needs an active Babylon scene and camera.");
  if(engine.useReverseDepthBuffer)throw Error("SVG export does not support a reversed depth buffer.");
  const limits={maxPrimitives:options.maxPrimitives??250000,maxWorkingPrimitives:options.maxWorkingPrimitives??1000000,maxInputPrimitives:options.maxInputPrimitives??4000000,maxVertices:options.maxVertices??5000000,maxOutputBytes:options.maxOutputBytes??64*1024*1024,maxOcclusionReferences:options.maxOcclusionReferences??8000000,maxOcclusionTests:options.maxOcclusionTests??40000000};
  for(const[key,value]of Object.entries(limits))if(!Number.isSafeInteger(value)||value<1)throw Error("Invalid SVG resource limit: "+key);
  const canvas=engine.getRenderingCanvas?.(),width=Math.round(canvas?.clientWidth||engine.getRenderWidth()),height=Math.round(canvas?.clientHeight||engine.getRenderHeight());if(!(width>0&&height>0&&width<=32768&&height<=32768))throw Error("The viewport size is not valid for SVG export.");
  const warnings=new Set(["Vector snapshot uses flat material/vertex colors; lighting, textures and reflections may differ from the interactive renderer.","Surface depth uses painter ordering; intersecting or interpenetrating surfaces may overlap approximately.","Screen-space entity labels, text overlays and selection halos are omitted; active color scales are included."]),warn=message=>warnings.add(message),stats={width,height,meshes:0,instances:0,sourceVertices:0,inputPrimitives:0,polygons:0,lines:0,points:0,compactGlyphs:0,replacedGlyphTriangles:0,emittedPaths:0,aggregatedPrimitives:0,clippedPrimitives:0,hiddenLinePieces:0,lineOcclusionTests:0,yields:0};
  const progress=async(fraction,message)=>{options.onProgress?.(fraction,message);stats.yields++;await pause();};await progress(0,"Capturing the visible viewport");
  const viewport=camera.viewport.toGlobal(width,height),viewProjection=camera.getViewMatrix(true).multiply(camera.getProjectionMatrix(true)),cameraSnapshot={mode:camera.mode,position:(camera.globalPosition||camera.position).clone(),direction:camera.getForwardRay().direction.clone()},clipPlanes=planes(!!engine.isNDCHalfZRange),records=[],cache=new Map();let expandedVertices=0;
  // Capture all mutable buffers and matrices before yielding again, so an
  // animated/deformed scene contributes one coherent frame to the export.
  for(const mesh of scene.meshes){if(mesh.isDisposed?.()||!mesh.isEnabled()||!mesh.isVisible||mesh.visibility<=0||!(mesh.layerMask&camera.layerMask))continue;const source=mesh.sourceMesh||mesh;
   if(textureLabel(mesh,source)){warn("Textured label planes are omitted, rather than exported as opaque rectangles.");continue;}
   if(!source.getVerticesData)continue;const positions=source.getVerticesData(B.VertexBuffer.PositionKind);if(!positions?.length)continue;
   let geometry=cache.get(source.geometry||source);if(!geometry){const colors=source.getVerticesData(B.VertexBuffer.ColorKind),indices=source.isUnIndexed?null:source.getIndices();geometry={positions:Float32Array.from(positions),colors:colors?Float32Array.from(colors):null,indices:indices?Uint32Array.from(indices):null};cache.set(source.geometry||source,geometry);stats.sourceVertices+=positions.length/3;if(stats.sourceVertices>limits.maxVertices)throw Error("SVG source geometry exceeds its vertex limit. Hide some entities and try again.");}
   if(source.skeleton||source.morphTargetManager?.numInfluencers)warn("GPU skinning or morph animation is exported from its current CPU vertex positions.");
   const meshWorld=mesh.computeWorldMatrix(true).clone(),thin=source===mesh&&mesh.thinInstanceCount>0?mesh.thinInstanceGetWorldMatrices():null;
   const worlds=thin?.length?thin.map(matrix=>matrix.multiply(meshWorld)):[meshWorld],thinColors=mesh._userThinInstanceBuffersStorage?.data?.instanceColor;
   const sphere=options.compactGlyphs===false?null:sphereBounds(mesh,source,geometry);expandedVertices+=worlds.length*(sphere?64:geometry.positions.length/3);if(expandedVertices>limits.maxVertices)throw Error("SVG instances exceed the expanded vertex limit. Hide some entities and try again.");
   const subMeshes=source.subMeshes?.length?source.subMeshes:[{indexStart:0,indexCount:geometry.indices?.length||0,verticesStart:0,verticesCount:geometry.positions.length/3,materialIndex:0}];
   const submeshes=subMeshes.map(sub=>{const material=(mesh.material?.subMaterials?mesh.material.subMaterials[sub.materialIndex]:mesh.material||source.material)||scene.defaultMaterial;return{...snapshotMaterial(material,mesh,source,B,warn),start:sub.indexStart,count:sub.indexCount,vertexStart:sub.verticesStart,vertexCount:sub.verticesCount};});
   records.push({name:mesh.name||"Mesh",geometry,worlds,submeshes,sphere,group:mesh.metadata?.plane==="ground"?-1:(mesh.renderingGroupId||0),plane:mesh.metadata?.plane,spacing:mesh.metadata?.grid_spacing_m,instanceColor:mesh.instancedBuffers?.color?color(mesh.instancedBuffers.color).concat(mesh.instancedBuffers.color.a??1):null,thinColors:thinColors?Float32Array.from(thinColors):null});stats.meshes++;stats.instances+=worlds.length;
  }
  if(!records.length)throw Error("No visible model geometry is available to export.");
  const polygons=[],lines=[],points=[],primitiveCount=()=>polygons.length+lines.length+points.length;let operations=0;
  const push=(target,primitive)=>{if(primitiveCount()>=limits.maxWorkingPrimitives)throw Error("SVG projection exceeds its "+limits.maxWorkingPrimitives+" working-primitive limit. Hide dense reference/surface layers and try again.");target.push(primitive);};
  const countInput=()=>{if(++stats.inputPrimitives>limits.maxInputPrimitives)throw Error("SVG geometry exceeds its bounded input-processing limit.");};
  for(let recordIndex=0;recordIndex<records.length;recordIndex++){const record=records[recordIndex],{geometry}=record;
   for(let instance=0;instance<record.worlds.length;instance++){const world=record.worlds[instance],matrix=world.multiply(viewProjection).m,negativeDeterminant=world.determinant()<0,vertices=new Array(geometry.positions.length/3),instanceColor=record.thinColors?Array.from(record.thinColors.subarray(instance*4,instance*4+4)):record.instanceColor;
    const style=(sub,ids)=>{let c=sub.base.slice(),alpha=sub.alpha;if(sub.vertexColors&&geometry.colors){const vc=[0,0,0,0];for(const id of ids)for(let k=0;k<4;k++)vc[k]+=(geometry.colors[id*4+k]??(k===3?1:0))/ids.length;c=c.map((v,i)=>v*vc[i]);if(sub.vertexAlpha)alpha*=vc[3];}if(instanceColor?.length>=3){c=c.map((v,i)=>v*instanceColor[i]);alpha*=instanceColor[3]??1;}return{fill:rgb(c),alpha:clamp(alpha),depthWrite:sub.depthWrite,depthTest:sub.depthTest,width:sub.lineWidth,pointSize:sub.pointSize};};
    const base={name:record.name,instance,group:record.group};
    const addFace=(input,appearance,sub)=>{countInput();const clipped=clipPolygon(input,clipPlanes);if(clipped.length<3){stats.clippedPrimitives++;return;}const projected=clipped.map(p=>screen(p,viewport)),signedArea=area(projected);if(Math.abs(signedArea)<1e-8)return;const orientation=(sub.orientation??(scene.useRightHandedSystem?0:1))^(negativeDeterminant?1:0);if(sub.backface&&(orientation===0?signedArea<0:signedArea>0))return;if(appearance.alpha<=0)return;push(polygons,{...base,...appearance,points:projected,depth:projected.reduce((sum,p)=>sum+p.z,0)/projected.length});};
    const addLine=(a,b,appearance)=>{countInput();const segment=clipSegment(a,b,clipPlanes);if(!segment){stats.clippedPrimitives++;return;}if(appearance.alpha<=0)return;const projected=segment.map(p=>screen(p,viewport));push(lines,{...base,...appearance,points:projected,depth:(projected[0].z+projected[1].z)/2});};
    if(record.sphere&&record.submeshes.length===1&&record.submeshes[0].mode===B.Material.TriangleFillMode){const outline=sphereOutline(record.sphere,world,viewProjection,cameraSnapshot,B,viewport);if(outline){const sub=record.submeshes[0],appearance=style(sub,[]);if(!sub.backface&&appearance.alpha<1)appearance.alpha=1-(1-appearance.alpha)**2;addFace(outline,appearance,{...sub,backface:false});stats.compactGlyphs++;stats.replacedGlyphTriangles+=Math.floor((geometry.indices?.length||geometry.positions.length/3)/3);warn("Spherical markers and inertia ellipsoids use adaptively sampled vector silhouettes; their principal ellipse curves remain visible.");if(++operations%64===0)await progress(.05+.55*recordIndex/records.length,"Projecting compact markers and ellipsoids");continue;}}
    for(let i=0;i<vertices.length;i++){const p=transform(geometry.positions.subarray(i*3,i*3+3),matrix);if(!p.every(finite))throw Error("Non-finite coordinates in visible mesh "+record.name);vertices[i]=p;if(++operations%4096===0)await progress(.05+.55*recordIndex/records.length,"Projecting visible geometry");}
    if(record.plane==="ground"){
     const coords=geometry.positions,xs=[],zs=[];for(let i=0;i<coords.length;i+=3){xs.push(coords[i]);zs.push(coords[i+2]);}const minX=Math.min(...xs),maxX=Math.max(...xs),minZ=Math.min(...zs),maxZ=Math.max(...zs),y=coords[1],spacing=record.spacing,columns=Math.ceil(maxX/spacing)-Math.floor(minX/spacing),rows=Math.ceil(maxZ/spacing)-Math.floor(minZ/spacing),sub={...record.submeshes[0],backface:false};
     if(finite(spacing)&&spacing>0&&columns*rows<=4096){for(let ix=Math.floor(minX/spacing);ix<Math.ceil(maxX/spacing);ix++)for(let iz=Math.floor(minZ/spacing);iz<Math.ceil(maxZ/spacing);iz++){const a=Math.max(minX,ix*spacing),b=Math.min(maxX,(ix+1)*spacing),c=Math.max(minZ,iz*spacing),d=Math.min(maxZ,(iz+1)*spacing),corners=[[a,y,c],[b,y,c],[b,y,d],[a,y,d]].map(p=>transform(p,matrix));addFace(corners,{fill:(ix+iz)%2===0?"#b0bfcc":"#cfd9e3",alpha:1,depthWrite:false},sub);if(++operations%1024===0)await progress(.05+.55*recordIndex/records.length,"Projecting ground grid");}}
     else{warn("The procedural ground grid is too dense for individual SVG tiles and uses its average flat color.");for(const ids of[[0,1,2],[0,2,3]])addFace(ids.map(i=>vertices[i]),{fill:"#bfccd7",alpha:1,depthWrite:false},sub);}continue;
    }
    for(const sub of record.submeshes){const indexed=geometry.indices?.length&&sub.count>0,ids=indexed?geometry.indices.subarray(sub.start,sub.start+sub.count):Uint32Array.from({length:sub.vertexCount},(_,i)=>sub.vertexStart+i),edgeSet=new Set();
     const edge=(i,j)=>{const key=i<j?i+":"+j:j+":"+i;if(edgeSet.has(key))return;edgeSet.add(key);addLine(vertices[i],vertices[j],style(sub,[i,j]));};
     if([B.Material.PointFillMode,B.Material.PointListDrawMode].includes(sub.mode)){for(const id of new Set(ids)){countInput();const p=vertices[id];if(!clipPlanes.every(distance=>distance(p)>=0)||p[3]<=1e-12){stats.clippedPrimitives++;continue;}const point=screen(p,viewport);push(points,{...base,...style(sub,[id]),points:[point],depth:point.z});}}
     else if([B.Material.LineListDrawMode,B.Material.LineStripDrawMode,B.Material.LineLoopDrawMode].includes(sub.mode)){const step=sub.mode===B.Material.LineListDrawMode?2:1;for(let i=0;i+1<ids.length;i+=step){edge(ids[i],ids[i+1]);if(++operations%2048===0)await progress(.05+.55*recordIndex/records.length,"Projecting bars and edges");}if(sub.mode===B.Material.LineLoopDrawMode&&ids.length>2)edge(ids.at(-1),ids[0]);}
     else{const count=sub.mode===B.Material.TriangleStripDrawMode||sub.mode===B.Material.TriangleFanDrawMode?Math.max(0,ids.length-2):Math.floor(ids.length/3);for(let triangle=0;triangle<count;triangle++){const face=sub.mode===B.Material.TriangleStripDrawMode?(triangle%2?[ids[triangle+1],ids[triangle],ids[triangle+2]]:[ids[triangle],ids[triangle+1],ids[triangle+2]]):sub.mode===B.Material.TriangleFanDrawMode?[ids[0],ids[triangle+1],ids[triangle+2]]:Array.from(ids.subarray(3*triangle,3*triangle+3));if(face.some(i=>!vertices[i]))throw Error("Invalid triangle connectivity in "+record.name);if(sub.mode===B.Material.WireFrameFillMode){edge(face[0],face[1]);edge(face[1],face[2]);edge(face[2],face[0]);}else addFace(face.map(i=>vertices[i]),style(sub,face),sub);if(++operations%2048===0)await progress(.05+.55*recordIndex/records.length,"Projecting surfaces");}}
    }
   }
  }
  await progress(.62,"Resolving visible line segments");const visibleLine=lines.length||points.length?await occlusionIndex(polygons,limits,stats,()=>progress(.64,"Indexing opaque surfaces")):()=>[],visible=[];
  for(let i=0;i<lines.length;i++){const pieces=visibleLine(lines[i]);stats.hiddenLinePieces+=pieces.length!==1||pieces[0]?.points.some((p,j)=>Math.abs(p.x-lines[i].points[j].x)+Math.abs(p.y-lines[i].points[j].y)>1e-5)?1:0;visible.push(...pieces);if(polygons.length+visible.length+points.length>limits.maxWorkingPrimitives)throw Error("SVG visible line fragments exceed the working-primitive limit.");if(i%256===0)await progress(.65+.2*i/Math.max(1,lines.length),"Resolving visible line segments");}
  const visiblePoints=[];for(let i=0;i<points.length;i++){const point=points[i];if(point.alpha>0&&visibleLine({...point,points:[point.points[0],point.points[0]]}).length)visiblePoints.push(point);if(i%512===0&&points.length)await progress(.85,"Resolving visible markers");}
  const primitives=[...polygons.map(p=>({...p,type:"polygon"})),...visible.map(p=>({...p,type:"line"})),...visiblePoints.map(p=>({...p,type:"point"}))];primitives.sort((a,b)=>a.group-b.group||b.depth-a.depth||(a.type==="polygon"?-1:1));stats.polygons=polygons.length;stats.lines=visible.length;stats.points=visiblePoints.length;if(!primitives.length)throw Error("No model geometry intersects the current camera view.");
  const legend=legendSVG(options.legends||[],width,height),background=scene.clearColor||{r:.05,g:.08,b:.12,a:1},parts=[];let bytes=0;
  const append=text=>{bytes+=text.length*2;if(bytes>limits.maxOutputBytes)throw Error("SVG document exceeds its size limit. Hide some entities and try again.");parts.push(text);};
  append(`<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img"><title>${escape(options.title||"WingFEGen viewport")}</title><desc>Flat-color vector snapshot of the visible model and current camera. ${escape([...warnings].join(" "))}</desc><defs><clipPath id="model-viewport"><rect x="${number(viewport.x)}" y="${number(viewport.y)}" width="${number(viewport.width)}" height="${number(viewport.height)}"/></clipPath>${legend.defs}</defs><rect width="${width}" height="${height}" fill="${rgb(color(background))}" fill-opacity="${number(background.a??1)}"/><g clip-path="url(#model-viewport)">`);
  let pending=null;const countPath=()=>{if(++stats.emittedPaths>limits.maxPrimitives)throw Error("SVG export exceeds "+limits.maxPrimitives+" vector primitive paths after geometry compaction. Hide dense reference/surface layers and try again.");};
  const flush=()=>{if(!pending)return;countPath();const {primitive:p,attributes,d}=pending;if(p.type==="polygon")append(`<path ${attributes} d="${d.join(" ")}" fill="${p.fill}" fill-opacity="${number(p.alpha)}" stroke="none"/>`);else append(`<path ${attributes} d="${d.join(" ")}" fill="none" stroke="${p.fill}" stroke-opacity="${number(p.alpha)}" stroke-width="${number(p.width)}" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`);pending=null;};
  // Batch only consecutive opaque paths of identical style/identity. Reordering
  // transparent facets or combining their opacity would change the image.
  for(let i=0;i<primitives.length;i++){const p=primitives[i],attributes=`data-mesh="${escape(p.name)}" data-instance="${p.instance}"`;let points=p.points;if(p.type==="polygon"&&area(points)<0)points=[points[0],...points.slice(1).reverse()];const d=points.map((point,j)=>(j?"L":"M")+number(point.x)+" "+number(point.y)).join(" ")+(p.type==="polygon"?"Z":""),canBatch=options.aggregatePaths!==false&&primitives.length>=1024&&p.alpha===1&&p.type!=="point",key=canBatch?[p.name,p.instance,p.type,p.fill,p.width].join("|"):null;
   if(p.type==="point"){flush();countPath();append(`<circle ${attributes} cx="${number(points[0].x)}" cy="${number(points[0].y)}" r="${number(p.pointSize/2)}" fill="${p.fill}" fill-opacity="${number(p.alpha)}"/>`);}
   else if(key&&pending?.key===key&&pending.d.length<2048){pending.d.push(d);stats.aggregatedPrimitives++;}
   else{flush();pending={key,primitive:p,attributes,d:[d]};}
   if(i%4096===0)await progress(.87+.1*i/primitives.length,"Writing compact SVG paths");
  }flush();
  append(`</g><g font-family="system-ui,sans-serif">${legend.body}</g></svg>`);await progress(1,"Viewport SVG ready");stats.outputCharacters=parts.reduce((sum,part)=>sum+part.length,0);return{text:parts.join(""),stats,warnings:[...warnings]};
 }
 return{exportScene,clipPolygon,clipSegment};
});
