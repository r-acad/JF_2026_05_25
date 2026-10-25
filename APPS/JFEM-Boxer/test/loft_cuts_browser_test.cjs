'use strict';
// node loft_cuts_browser_test.cjs <evidence-dir> <playwright-module> [webgpu|webgl]
// Uses bundled production Babylon and actual WebGPU/WebGL screenshot pixels.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const backend=process.argv[4]||'webgl';
if(!['webgpu','webgl'].includes(backend))throw Error('Choose webgpu or webgl.');
(async()=>{
 fs.mkdirSync(out,{recursive:true});let checks=0;const errors=[],verify=(condition,message)=>{assert(condition,message);checks++;};
 const server=http.createServer((req,res)=>{if(req.url==='/favicon.ico')return res.end();if(req.url==='/'){res.setHeader('Content-Type','text/html');return res.end('<!doctype html>');}const file=path.resolve(web,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',file.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(file).pipe(res);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,args:backend==='webgpu'?['--enable-unsafe-webgpu']:['--enable-webgl','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader'],...((process.env.CHROME_PATH||process.env.CHROME_BIN)?{executablePath:process.env.CHROME_PATH||process.env.CHROME_BIN}:{})});
 const page=await browser.newPage({viewport:{width:640,height:480},deviceScaleFactor:1});page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error'){errors.push(m.text());console.error(m.text());}});
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.setContent('<!doctype html><style>html,body{margin:0;background:black}canvas{display:block;width:640px;height:480px}</style><canvas id="view" width="640" height="480"></canvas>');
  for(const file of['vendor/babylon.js','loft_cuts.js','aero_display.js','transparency.js','inspect_highlight.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(async({backend,origin})=>{
   const B=BABYLON;window.engine=backend==='webgpu'?new B.WebGPUEngine(document.getElementById('view'),{antialias:true,enableAllFeatures:true}):new B.Engine(document.getElementById('view'),true,{preserveDrawingBuffer:true,stencil:true});if(backend==='webgpu')await engine.initAsync({jsPath:origin+'/vendor/glslang/glslang.js',wasmPath:origin+'/vendor/glslang/glslang.wasm'},{jsPath:origin+'/vendor/twgsl/twgsl.js',wasmPath:origin+'/vendor/twgsl/twgsl.wasm'});engine._device?.addEventListener('uncapturederror',e=>console.error(e.error.message));engine.useReverseDepthBuffer=true;window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(0,0,0,1);
   const camera=new B.ArcRotateCamera('camera',-Math.PI/3,Math.PI/3,9,new B.Vector3(0,0,0),scene);camera.minZ=.01;
   const positions=[],indices=[];
   for(const x of[-2,2])for(const[y,z]of[[-.7,-1],[.7,-1],[.7,1],[-.7,1]])positions.push(x,y,z);
   for(let k=0;k<4;k++){const a=k,b=(k+1)%4,c=4+(k+1)%4,d=4+k;indices.push(a,b,c,a,c,d);}
   window.source=new B.Mesh('hidden-loft',scene);const vd=new B.VertexData();vd.positions=positions;vd.indices=indices;vd.colors=new Float32Array(positions.length/3*4).fill(1);vd.applyToMesh(source,true);source.material=new B.StandardMaterial('loft',scene);source.setEnabled(false);
   window.cuts=WingLoftCuts.create({BABYLON:B,scene,mesh:source,basePositions:positions});cuts.configure({visible:true,count:3});
   window.frame=async()=>{for(let i=0;i<20;i++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(r=>setTimeout(r,10));}};
   window.stats=async png=>{
    // Screenshot decoding is RGBA on both backends; WebGPU canvas readback
    // may expose native BGRA bytes instead. Inspect the actual displayed frame.
    const image=new Image();image.src='data:image/png;base64,'+png;await image.decode();const c=document.createElement('canvas');c.width=image.width;c.height=image.height;const ctx=c.getContext('2d');ctx.drawImage(image,0,0);const rgba=ctx.getImageData(0,0,c.width,c.height).data;let cyan=0,white=0,bright=0,magenta=0,orange=0;
    for(let i=0;i<rgba.length;i+=4){if(rgba[i]>100&&rgba[i+1]>40&&rgba[i+1]<220&&rgba[i+2]<70)orange++;if(rgba[i]>100&&rgba[i+2]>100&&rgba[i+1]<40)magenta++;if(rgba[i+1]>100&&rgba[i+2]>100&&rgba[i]<40)cyan++;if(rgba[i]>180&&rgba[i+1]>180&&rgba[i+2]>180)white++;if(Math.max(rgba[i],rgba[i+1],rgba[i+2])>100)bright++;}
    const colors=cuts.mesh.getVerticesData(B.VertexBuffer.ColorKind);
    return{cyan,white,bright,magenta,orange,allMagentaVertices:Array.from(colors).every((v,i)=>v===(i%4===1?0:1)),vertexCount:cuts.mesh.getTotalVertices(),allCyanVertices:Array.from(colors).every((v,i)=>v===(i%4===0?0:1)),color:cuts.mesh.color.toHexString(),opaque:cuts.mesh.material.transparencyMode===B.Material.MATERIAL_OPAQUE,sourceEnabled:source.isEnabled(),cutEnabled:cuts.mesh.isEnabled(),planes:cuts.planes};
   };
  },{backend,origin:'http://127.0.0.1:'+server.address().port});
  const stats=async()=>page.evaluate(png=>window.stats(png),(await page.locator('canvas').screenshot()).toString('base64'));
  await page.evaluate(()=>frame());const initial=await stats();
  verify(initial.allCyanVertices,'Real Babylon GPU vertex buffer is cyan RGBA.');
  verify(initial.cyan>100&&initial.white===0,JSON.stringify(initial));
  verify(initial.color==='#00FFFF'&&initial.opaque&&initial.cutEnabled&&!initial.sourceEnabled,'Opaque cyan cuts render independently of hidden loft.');
  await page.locator('canvas').screenshot({path:path.join(out,'cyan-cuts.png')});
  // Exercise the allocation branch as well as the original buffer: a fresh
  // larger LinesMesh must carry the same cyan vertex colors.
  await page.evaluate(()=>{cuts.configure({count:37});return frame();});const enlarged=await stats();
  verify(enlarged.vertexCount>initial.vertexCount&&enlarged.allCyanVertices,'A grown vertex buffer remains cyan.');
  verify(enlarged.cyan>100&&enlarged.white===0,JSON.stringify(enlarged));
  await page.evaluate(()=>{const p=source.getVerticesData(BABYLON.VertexBuffer.PositionKind).slice();for(let i=0;i<p.length;i+=3)p[i+1]+=.2*p[i];source.updateVerticesData(BABYLON.VertexBuffer.PositionKind,p,true);cuts.update();return frame();});const deformed=await stats();
  verify(deformed.allCyanVertices&&deformed.cyan>100&&deformed.white===0,'Deformation updates preserve cyan pixels and vertex colors.');
  await page.evaluate(()=>{window.originalMesh=cuts.mesh;cuts.configure({color:'#ff00ff'});return frame();});const recolored=await stats();
  verify(recolored.magenta>100&&recolored.cyan===0&&recolored.allMagentaVertices,'Color picker value changes actual rendered pixels and the vertex buffer.');
  verify(await page.evaluate(()=>cuts.mesh===originalMesh),'Color changes reuse the rendered mesh.');
  await page.evaluate(()=>{cuts.configure({count:100});return frame();});const regrown=await stats();
  verify(regrown.vertexCount>enlarged.vertexCount&&regrown.allMagentaVertices&&regrown.magenta>100,'Buffer growth retains the user color.');
  await page.evaluate(()=>{cuts.update();return frame();});verify((await stats()).allMagentaVertices,'Deformation retains the chosen color.');
  await page.locator('canvas').screenshot({path:path.join(out,'magenta-cuts.png')});
  await page.evaluate(()=>{cuts.configure({visible:false});return frame();});const hidden=await stats();
  verify(!hidden.cutEnabled&&hidden.bright===0,'Hide removes the actual rendered cuts.');
  // The loft wireframe used the same illegal line depth bias. Exercise it
  // with transparent composition active, as in the full Boxer viewport.
  await page.evaluate(()=>{const B=BABYLON;window.aero=WingAeroDisplay.create({scene,data:{}});const quads=[];for(let k=0;k<4;k++)quads.push(k,(k+1)%4,4+(k+1)%4,4+k);aero.attach(source,{quads,nLoop:4});aero.apply(source,{visible:true,style:'wireframe',color:'#00ffff'});window.transparency=WingTransparency.create({scene});transparency.setEnabled(true);return frame();});
  const wire=await stats();verify(wire.cyan>100&&wire.white===0,'Aerodynamic quad wireframe renders on '+backend+' with transparent composition.');
  verify(await page.evaluate(()=>{const w=aero.wireFor(source);return w.material.zOffset===0&&w.material.zOffsetUnits===0&&!source.isEnabled();}),'Wireframe uses valid line primitives without showing the source surface.');
  await page.locator('canvas').screenshot({path:path.join(out,'quad-wireframe.png')});
  await page.evaluate(()=>{aero.dispose();transparency.dispose();return frame();});
  await page.evaluate(()=>{const B=BABYLON,group={kind:'quad',pid:11,name:'skin'};source.elementIds=[1,2,3,4];source.metadata={feGroup:group,facesPerElement:2};source.setEnabled(true);source.material.disableLighting=true;source.material.emissiveColor=new B.Color3(.03,.03,.03);window.highlight=WingInspectHighlight.create({BABYLON:B,scene,state:{selectedElement:1,elements:new Map(source.elementIds.map(id=>[id,{id,group}])),shellMeshes:[source],barMeshes:[],layers:new Map([['skin',{visible:true}]]),diag:5}});highlight.refresh();return frame();});
  const inspection=await stats();verify(inspection.orange>100,'Inspected property peers remain visible on '+backend+'.');
  verify(await page.evaluate(()=>{const peer=highlight.meshes.find(m=>m.metadata.peerHighlight),selected=highlight.meshes.find(m=>m.metadata.selectedHighlight);return peer.material.zOffset===0&&peer.material.zOffsetUnits===0&&selected.material.zOffset===-1&&highlight.diagnostics.visiblePeerCount===3;}),'Peer lines have zero bias; selected triangular glow retains its valid depth bias.');
  await page.locator('canvas').screenshot({path:path.join(out,'inspection.png')});
  await page.evaluate(()=>{highlight.dispose();return frame();});
  verify(errors.length===0,errors.join('\n'));
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend,checks,errors,initial,enlarged,deformed,recolored,regrown,hidden,wire,inspection,scope:'Bundled production Babylon, actual screenshot RGBA pixel/vertex buffers, hidden source, allocation growth, deformation, hiding and aerodynamic wireframe with transparent composition and inspected property peers'},null,2));
  console.log(JSON.stringify({passed:true,checks,errors,pixels:{initial:initial.cyan,enlarged:enlarged.cyan,deformed:deformed.cyan}}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await page.evaluate(()=>engine?.dispose()).catch(()=>{});await browser.close();await new Promise(r=>server.close(r));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
