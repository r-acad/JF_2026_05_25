'use strict';
// Actual full-float WebGPU pixels: 3 mm skin separation across a 30 m model.
// node transparency_depth_browser_test.cjs <evidence-dir> [playwright-module] [webgpu|webgl]
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web'),backend=process.argv[4]||'webgpu';
if(!['webgpu','webgl'].includes(backend))throw Error('Choose webgpu or webgl.');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],results=[];
 const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');if(u.pathname==='/'){res.setHeader('Content-Type','text/html');return res.end('<body style="margin:0"><canvas width="1200" height="800" id="canvas"></canvas><script src="/vendor/babylon.js"></script><script src="/transparency.js"></script>');}if(u.pathname==='/favicon.ico')return res.end();const p=path.resolve(web,'.'+u.pathname);if(!p.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',p.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(p).pipe(res);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})}),page=await browser.newPage({viewport:{width:1200,height:800}});
 page.on('pageerror',e=>errors.push(e.stack));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  const info=await page.evaluate(async backend=>{
   const B=BABYLON;window.engine=backend==='webgpu'?new B.WebGPUEngine(document.getElementById('canvas'),{antialias:true,enableAllFeatures:true}):new B.Engine(document.getElementById('canvas'),true);
   if(engine.isWebGPU)await engine.initAsync({jsPath:'/vendor/glslang/glslang.js',wasmPath:'/vendor/glslang/glslang.wasm'},{jsPath:'/vendor/twgsl/twgsl.js',wasmPath:'/vendor/twgsl/twgsl.wasm'});
   if(!engine.getCaps().blendFloat||!engine.getCaps().textureFloatLinearFiltering)throw Error('This regression requires full-float blending/filtering.');
   engine.useReverseDepthBuffer=true;window.gpuErrors=[];engine._device?.addEventListener('uncapturederror',e=>gpuErrors.push(e.error.message));
   window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(1,1,1,1);window.camera=new B.ArcRotateCamera('camera',-1.1,.9,32,B.Vector3.Zero(),scene);camera.minZ=Math.hypot(30,5)*.001;camera.maxZ=Math.hypot(30,5)*10;
   for(let i=0;i<2;i++){const p=B.MeshBuilder.CreateGround('skin'+i,{width:30,height:5,subdivisionsX:160,subdivisionsY:20},scene);p.rotation.y=.2;p.position.y=-.003*i;const m=new B.StandardMaterial('skin-material'+i,scene);m.disableLighting=true;m.emissiveColor=i?new B.Color3(.95,.15,.05):new B.Color3(.05,.15,.95);m.alpha=.45;m.backFaceCulling=false;p.material=m;}
   window.transparency=WingTransparency.create({scene});transparency.setEnabled(true);
   window.render=async()=>{for(let i=0;i<20;i++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(r=>setTimeout(r,10));}};await render();
   return{backend,adapter:engine.getInfo(),version:B.Engine.Version,triangles:scene.meshes.reduce((n,m)=>n+m.getTotalIndices()/3,0),gap:.003,span:30,near:camera.minZ,reverse:engine.useReverseDepthBuffer};
  },backend);
  for(const [name,alpha,beta,ortho] of [['above',-1.1,.9,false],['rotated',.6,1.05,false],['below',-1.1,2.2,false],['ortho-above',-.9,1.05,true],['ortho-below',.4,2.2,true]]){
   await page.evaluate(async({alpha,beta,ortho})=>{camera.alpha=alpha;camera.beta=beta;camera.mode=ortho?BABYLON.Camera.ORTHOGRAPHIC_CAMERA:BABYLON.Camera.PERSPECTIVE_CAMERA;camera.orthoLeft=-22;camera.orthoRight=22;camera.orthoTop=14.667;camera.orthoBottom=-14.667;await render();},{alpha,beta,ortho});
   const screenshot=await page.screenshot({path:path.join(out,name+'.png')});
   const pixels=await page.evaluate(async({png,above})=>{const img=new Image();img.src='data:image/png;base64,'+png;await img.decode();const c=document.createElement('canvas');c.width=img.width;c.height=img.height;const ctx=c.getContext('2d');ctx.drawImage(img,0,0);const d=ctx.getImageData(0,0,c.width,c.height).data;let colored=0,wrong=0;for(let i=0;i<d.length;i+=4){const[r,g,b]=d.slice(i,i+3);if(g>230||Math.max(r,b)-g<15)continue;colored++;if((above?b-r:r-b)<20)wrong++;}return{colored,wrong,fraction:wrong/colored};},{png:screenshot.toString('base64'),above:beta<Math.PI/2});
   assert(pixels.colored>20000,name+' must show both sheets');assert(pixels.fraction<.005,name+' must preserve layer order across the entire skin: '+JSON.stringify(pixels));results.push({name,...pixels});
  }
  const state=await page.evaluate(()=>({errors:gpuErrors,types:scene.depthPeelingRenderer._depthMrts.map(rt=>rt.textures[0].getInternalTexture().type),float:BABYLON.Constants.TEXTURETYPE_FLOAT}));assert.deepEqual(state.errors,[]);assert(state.types.every(t=>t===state.float));assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,info,results,errors},null,2));console.log('Full-float reversed '+backend+': 3 mm separated, 30 m skins retain correct color order in five perspective/orthographic views.');
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,results,errors},null,2));throw e;}finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
