'use strict';
// Real bundled Babylon pixels, including occlusion of an enabled halo.
// node constraint_visibility_browser_test.cjs OUTPUT webgpu|webgl PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const [out,backend='webgpu',modulePath='playwright']=process.argv.slice(2),web=path.resolve(__dirname,'../web');
const {chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[];
 const html='<body style="margin:0"><canvas id="canvas" style="width:100vw;height:100vh;display:block"></canvas>'+['vendor/babylon.js','support_glyphs.js','line_quality.js','transparency.js'].map(s=>'<script src="/'+s+'"></script>').join('');
 const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');if(u.pathname==='/'){res.setHeader('Content-Type','text/html');return res.end(html);}if(u.pathname==='/favicon.ico'){res.statusCode=204;return res.end();}const p=path.resolve(web,'.'+u.pathname);if(!p.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',p.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(p).on('error',()=>{res.statusCode=404;res.end();}).pipe(res);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:'chrome',headless:true,args:backend==='webgpu'?['--enable-unsafe-webgpu','--disable-gpu-sandbox']:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:960,height:720}});
 page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(async backend=>{
   const B=BABYLON;window.engine=backend==='webgpu'?new B.WebGPUEngine(document.getElementById('canvas'),{antialias:true,enableAllFeatures:true}):new B.Engine(document.getElementById('canvas'),true);
   if(engine.isWebGPU)await engine.initAsync({jsPath:'/vendor/glslang/glslang.js',wasmPath:'/vendor/glslang/glslang.wasm'},{jsPath:'/vendor/twgsl/twgsl.js',wasmPath:'/vendor/twgsl/twgsl.wasm'});
   engine.useReverseDepthBuffer=true;window.gpuErrors=[];engine._device?.addEventListener('uncapturederror',e=>gpuErrors.push(e.error.message));
   window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(.025,.035,.05,1);scene.setRenderingAutoClearDepthStencil(2,false);
   window.camera=new B.ArcRotateCamera('camera',-.8,.8,8,B.Vector3.Zero(),scene);camera.minZ=.01;camera.maxZ=100;
   const light=new B.HemisphericLight('light',new B.Vector3(0,1,0),scene);light.intensity=.8;
   window.glyphs=WingSupportGlyphs.create({BABYLON:B,scene,data:{nodes:{count:2,ids:[100,200]},spc:{nodes:[0,1],node_components:['25','36']}},positions:Float32Array.from([-1,0,0,1,0,0]),radius:.3});
   window.quality=WingLineQuality.create({BABYLON:B,scene,camera});
   window.transparency=WingTransparency.create({scene});
   const line=B.MeshBuilder.CreateLines('mesh-edge',{points:[new B.Vector3(-2,-.8,.1),new B.Vector3(2,.8,.1)]},scene);line.color=new B.Color3(.3,.3,.3);
   window.render=async()=>{let ready=0;for(let n=0;n<120;n++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(r=>setTimeout(r,15));ready=scene.isReady()?ready+1:0;if(ready>=10)return;}throw Error('Scene not ready');};
   await render();
  },backend);
  async function capture(name){const png=await page.screenshot({path:path.join(out,name+'.png')});return page.evaluate(async base64=>{
   const im=new Image();im.src='data:image/png;base64,'+base64;await im.decode();const c=document.createElement('canvas');c.width=im.width;c.height=im.height;const ctx=c.getContext('2d');ctx.drawImage(im,0,0);const d=ctx.getImageData(0,0,c.width,c.height).data;
   let green=0,blue=0,greenSum=0,blueSum=0;for(let i=0;i<d.length;i+=4){const r=d[i],g=d[i+1],b=d[i+2];if(g>r+12&&g>b+12){green++;greenSum+=g-Math.max(r,b);}if(b>r+12&&b>g+12){blue++;blueSum+=b-Math.max(r,g);}}
   return{green,blue,greenSum,blueSum};
  },png.toString('base64'));}
  const ordinary=await capture('constraints-no-glow');assert(ordinary.green>150&&ordinary.blue>150);
  await page.evaluate(async()=>{glyphs.setGlow(true);await render();});const glowing=await capture('constraints-glow');assert(glowing.green>ordinary.green&&glowing.blue>ordinary.blue,'The halo must visibly extend both marker colors');
  await page.evaluate(async()=>{glyphs.update({radius:.6});await render();});const large=await capture('constraints-large');assert(large.green>glowing.green*2&&large.blue>glowing.blue*2,'Size must enlarge actual visible glyphs');
  const lifecycle=await page.evaluate(async()=>{
   const before=scene.effectLayers.length;glyphs.setGlow(false);glyphs.setGlow(true);glyphs.setGlow(true);const after=scene.effectLayers.length;
   const B=BABYLON;window.cover=B.MeshBuilder.CreatePlane('opaque-occluder',{size:8},scene);cover.position=camera.position.scale(.5);cover.lookAt(camera.position);cover.material=new B.StandardMaterial('opaque-gray',scene);cover.material.disableLighting=true;cover.material.emissiveColor=new B.Color3(.12,.12,.12);cover.material.backFaceCulling=false;
   await render();return{before,after,pickable:glyphs.meshes.some(m=>m.isPickable),depthWrites:glyphs.meshes.every(m=>!m.material.disableDepthWrite)};
  });
  const occluded=await capture('constraints-occluded');assert.equal(occluded.green,0,'Opaque geometry must hide green glyphs and halo');assert.equal(occluded.blue,0,'Opaque geometry must hide blue glyphs and halo');assert.equal(lifecycle.before,lifecycle.after);assert(!lifecycle.pickable&&lifecycle.depthWrites);
  await page.evaluate(async()=>{cover.material.alpha=.35;transparency.setEnabled(true);await render();});const translucent=await capture('constraints-translucent');assert(translucent.green>150&&translucent.blue>150,'Translucent surfaces must retain visible constraints');
  await page.evaluate(async()=>{cover.dispose();glyphs.meshes.forEach(m=>m.setEnabled(false));await render();});const hidden=await capture('constraints-hidden');assert.equal(hidden.green,0);assert.equal(hidden.blue,0);
  const gpuErrors=await page.evaluate(()=>gpuErrors);assert.deepEqual(gpuErrors,[]);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend,ordinary,glowing,large,occluded,translucent,hidden,lifecycle,errors,gpuErrors},null,2));console.log(backend+': saturated green/blue, visible halo and size, opaque/translucent depth, hidden layers, effect reuse and GPU checks passed');
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors},null,2));throw e;}finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
