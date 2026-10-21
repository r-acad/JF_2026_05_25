'use strict';
// Actual bundled-engine pixels, without a Julia server or generated FE fixture.
// node renderer_compatibility_browser_test.cjs <evidence-dir> <webgpu|webgl> [playwright-module]
// CHROME_PATH optionally selects a browser executable. WebGPU must be real;
// this test does not silently accept a WebGL fallback.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]||'renderer-evidence'),backend=process.argv[3]||'webgpu',web=path.resolve(__dirname,'../web');
const {chromium}=require(process.argv[4]||'playwright');
if(!['webgpu','webgl'].includes(backend))throw Error('Choose webgpu or webgl.');
const html='<html><body style="margin:0"><canvas id="canvas" width="1000" height="800" style="width:100vw;height:100vh;display:block"></canvas>'+['vendor/babylon.js','view_planes.js','scene_lighting.js','transparency.js'].map(s=>'<script src="/'+s+'"></script>').join('')+'</body></html>';
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],gpuErrors=[],external=[],results=[];
 const server=http.createServer((req,res)=>{if(req.url==='/'){res.setHeader('Content-Type','text/html');return res.end(html);}if(req.url==='/favicon.ico'){res.statusCode=204;return res.end();}const file=path.resolve(web,'.'+decodeURIComponent(req.url));if(!file.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',file.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(file).on('error',()=>{res.statusCode=404;res.end();}).pipe(res);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin='http://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:backend==='webgpu'?['--enable-unsafe-webgpu']:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1000,height:800}});page.on('pageerror',e=>errors.push(e.stack));
 page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
 await page.route('**/*',route=>{if(!route.request().url().startsWith(origin+'/')){external.push(route.request().url());return route.abort();}return route.continue();});
 try{
  await page.goto(origin);
  const info=await page.evaluate(async backend=>{
   const B=BABYLON,canvas=document.getElementById('canvas');
   window.engine=backend==='webgpu'?new B.WebGPUEngine(canvas,{antialias:true,enableAllFeatures:true}):new B.Engine(canvas,true);
   if(engine.isWebGPU)await engine.initAsync({jsPath:'/vendor/glslang/glslang.js',wasmPath:'/vendor/glslang/glslang.wasm'},{jsPath:'/vendor/twgsl/twgsl.js',wasmPath:'/vendor/twgsl/twgsl.wasm'});
   engine.useReverseDepthBuffer=true;
   window.gpuErrors=[];engine._device?.addEventListener('uncapturederror',event=>gpuErrors.push(event.error.message));
   window.scene=new B.Scene(engine);scene.useRightHandedSystem=true;scene.clearColor=new B.Color4(1,1,1,1);
   window.camera=new B.ArcRotateCamera('camera',-.9,1.05,11,new B.Vector3(0,1,0),scene);camera.minZ=.01;
   window.model=B.MeshBuilder.CreateBox('FE-shell',{width:3,height:1,depth:2},scene);model.position.y=1.3;model.rotation.y=.35;model.metadata={feGroup:{kind:'quad'}};
   window.standard=new B.StandardMaterial('FE-standard',scene);standard.diffuseColor=new B.Color3(.05,.35,.8);standard.maxSimultaneousLights=6;
   window.pbr=new B.PBRMaterial('FE-pbr',scene);pbr.albedoColor=new B.Color3(.05,.35,.8);pbr.metallic=.05;pbr.roughness=.35;pbr.maxSimultaneousLights=6;model.material=standard;
   window.planes=WingViewPlanes.create({scene});planes.update({bbox:{min:[-1.5,-1,.8],max:[1.5,1,1.8]},imported_deck:true},{z:0,spacing:.5});planes.setVisible(true,false);
   window.lighting=WingSceneLighting.create({scene});lighting.apply({...lighting.capture(),shadows:true,selfShadows:true});
   window.originalFiltering=engine.getCaps().textureFloatLinearFiltering;window.transparency=WingTransparency.create({scene});
   window.render=async()=>{let stable=0;for(let i=0;i<120;i++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(resolve=>setTimeout(resolve,20));stable=scene.isReady()?stable+1:0;if(stable>=5)return;}throw Error('Scene failed to become stably ready.');};
   window.groundTop=()=>Math.min(...planes.meshes.ground.getBoundingInfo().boundingBox.vectorsWorld.map(p=>B.Vector3.Project(p,B.Matrix.Identity(),scene.getTransformMatrix(),camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight())).y));
   await render();return{webgpu:engine.isWebGPU,version:B.Engine.Version,adapter:engine.getInfo(),filtering:originalFiltering};
  },backend);assert.equal(info.webgpu,backend==='webgpu');
  async function snapshot(name){
   const buffer=await page.screenshot({path:path.join(out,name+'.png')});
   return page.evaluate(async base64=>{const picture=new Image();picture.src='data:image/png;base64,'+base64;await picture.decode();const c=document.createElement('canvas');c.width=picture.width;c.height=picture.height;const ctx=c.getContext('2d');ctx.drawImage(picture,0,0);const pixels=ctx.getImageData(0,0,c.width,c.height).data,top=Math.max(0,Math.floor(groundTop())-6);let modelPixels=0;for(let y=0;y<top;y++)for(let x=0;x<c.width;x++){const i=(y*c.width+x)*4;if(pixels[i+2]>pixels[i]+25&&pixels[i+2]>pixels[i+1]+8)modelPixels++;}return{modelPixels,top};},buffer.toString('base64'));
  }
  for(const material of ['standard','pbr'])for(const oit of [false,true])for(const style of ['solid','wireframe','translucent','metallic']){
   const state=await page.evaluate(async({material,oit,style})=>{model.material=window[material];model.material.alpha=oit?.45:1;transparency.setEnabled(oit);planes.setGroundAppearance({style,opacity:.4});await render();return{ready:scene.isReady(),filtering:engine.getCaps().textureFloatLinearFiltering,depthTypes:oit?scene.depthPeelingRenderer._depthMrts.map(rt=>rt.textures[0].getInternalTexture().type):[],expectedFloat:BABYLON.Constants.TEXTURETYPE_FLOAT,gpuErrors:[...gpuErrors]};},{material,oit,style});
   const pixels=await snapshot(material+'-'+(oit?'translucent':'solid')+'-'+style);assert(pixels.modelPixels>500,'Visible FE surface above ground: '+JSON.stringify({material,oit,style,...pixels}));assert.deepEqual(state.gpuErrors,[]);assert.equal(state.filtering,info.filtering);if(info.webgpu&&oit)assert(state.depthTypes.every(t=>t===state.expectedFloat));results.push({material,oit,style,...pixels,ready:state.ready});
  }
  for(const oit of [false,true]){
   await page.evaluate(async oit=>{model.material=standard;standard.alpha=oit?.45:1;transparency.setEnabled(oit);planes.setGroundAppearance({style:'solid',opacity:.4});lighting.apply({...lighting.capture(),shadows:false,selfShadows:false});await render();},oit);
   const before=await page.screenshot({path:path.join(out,'shadow-'+oit+'-off.png')});
   await page.evaluate(async()=>{lighting.apply({...lighting.capture(),shadows:true});await render();});
   const after=await page.screenshot({path:path.join(out,'shadow-'+oit+'-on.png')});
   const shadow=await page.evaluate(async({before,after})=>{const read=async png=>{const image=new Image();image.src='data:image/png;base64,'+png;await image.decode();const c=document.createElement('canvas');c.width=image.width;c.height=image.height;const ctx=c.getContext('2d');ctx.drawImage(image,0,0);return ctx.getImageData(0,0,c.width,c.height).data;};const a=await read(before),b=await read(after);let darkened=0;for(let i=0;i<a.length;i+=4)if(a[i]+a[i+1]+a[i+2]-b[i]-b[i+1]-b[i+2]>30)darkened++;return{darkened};},{before:before.toString('base64'),after:after.toString('base64')});
   assert(shadow.darkened>200,'Ground shadow must visibly darken pixels: '+JSON.stringify({oit,...shadow}));results.push({shadow:{oit,...shadow}});
  }
  // Resize reallocates peeling textures; repeated switching and a newly added
  // material must retain full depth precision and renderer fixes.
  await page.setViewportSize({width:900,height:700});
  const lifecycle=await page.evaluate(async()=>{
   // Let the engine resize both the backing canvas and its MSAA attachments.
   // Assigning canvas.width first bypasses that normal engine lifecycle.
   engine.resize();
   for(let i=0;i<3;i++){transparency.setEnabled(false);await render();transparency.setEnabled(true);await render();}
   const B=BABYLON,later=new B.StandardMaterial('later-material',scene);later.diffuseColor=new B.Color3(.05,.35,.8);later.alpha=.45;later.maxSimultaneousLights=6;model.material=later;await render();
   const types=scene.depthPeelingRenderer._depthMrts.map(rt=>rt.textures[0].getInternalTexture().type),size=scene.depthPeelingRenderer._depthMrts[0].getSize();
   transparency.dispose();await render();const disposed={flag:!!scene._boxerHalfFloatOITDepth,oit:scene.useOrderIndependentTransparency,pluginDefine:model.subMeshes[0].materialDefines?.BOXER_OIT_HALF_DEPTH||false};
   transparency=WingTransparency.create({scene});transparency.setEnabled(true);await render();
   return{types,size,disposed,filtering:engine.getCaps().textureFloatLinearFiltering,gpuErrors:[...gpuErrors]};
  });assert.deepEqual(lifecycle.disposed,{flag:false,oit:false,pluginDefine:false});assert.equal(lifecycle.size.width,900);assert.equal(lifecycle.size.height,700);assert.equal(lifecycle.filtering,info.filtering);assert.deepEqual(lifecycle.gpuErrors,[]);assert((await snapshot('resize-recreate')).modelPixels>500);results.push({lifecycle});
  gpuErrors.push(...await page.evaluate(()=>window.gpuErrors));assert.deepEqual(gpuErrors,[]);assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend,info,results,errors,gpuErrors,external},null,2));console.log(`${backend}: 16 visible Standard/PBR, ground, shadow and OIT combinations; resize/toggle/recreate lifecycle passed.`);
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,results,errors,gpuErrors,external},null,2));throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
