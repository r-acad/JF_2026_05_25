'use strict';
// Real bundled Babylon pixels. Compares exactly the same dense FE scene and
// camera before/after line-quality setup; no Julia server or external assets.
// node line_quality_browser_test.cjs EVIDENCE webgpu|webgl [PLAYWRIGHT]
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),backend=process.argv[3]||'webgpu',web=path.resolve(__dirname,'../web');
const {chromium}=require(process.argv[4]||'playwright'),dpr=Number(process.env.LINE_TEST_DPR||2);
if(!['webgpu','webgl'].includes(backend))throw Error('Choose webgpu or webgl.');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],results=[],external=[];
 const html='<body style="margin:0;background:white"><canvas id="canvas" style="display:block;width:100vw;height:100vh"></canvas>'+['vendor/babylon.js','transparency.js','line_quality.js'].map(s=>'<script src="/'+s+'"></script>').join('');
 const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');if(u.pathname==='/'){res.setHeader('Content-Type','text/html');return res.end(html);}if(u.pathname==='/favicon.ico'){res.statusCode=204;return res.end();}const p=path.resolve(web,'.'+decodeURIComponent(u.pathname));if(!p.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',p.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(p).on('error',()=>{res.statusCode=404;res.end();}).pipe(res);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:backend==='webgpu'?['--enable-unsafe-webgpu','--disable-gpu-sandbox']:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:960,height:720},deviceScaleFactor:dpr});
 page.on('pageerror',e=>errors.push(e.stack));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 await page.route('**/*',route=>{if(!route.request().url().startsWith(origin+'/')){external.push(route.request().url());return route.abort();}return route.continue();});
 try{
  await page.goto(origin);
  const info=await page.evaluate(async backend=>{
   const B=BABYLON,canvas=document.getElementById('canvas');window.engine=backend==='webgpu'?new B.WebGPUEngine(canvas,{antialias:true,enableAllFeatures:true}):new B.Engine(canvas,true);
   if(engine.isWebGPU)await engine.initAsync({jsPath:'/vendor/glslang/glslang.js',wasmPath:'/vendor/glslang/glslang.wasm'},{jsPath:'/vendor/twgsl/twgsl.js',wasmPath:'/vendor/twgsl/twgsl.wasm'});
   engine.useReverseDepthBuffer=true;window.gpuErrors=[];engine._device?.addEventListener('uncapturederror',e=>gpuErrors.push(e.error.message));
   window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(1,1,1,1);window.camera=new B.ArcRotateCamera('camera',-1.1,.9,32,B.Vector3.Zero(),scene);camera.minZ=.03;camera.maxZ=320;
   window.skins=[];window.edges=[];
   for(let layer=0;layer<2;layer++){
    const mesh=B.MeshBuilder.CreateGround('skin-'+layer,{width:30,height:5,subdivisionsX:120,subdivisionsY:25},scene);mesh.position.y=-.003*layer;
    const m=new B.StandardMaterial('skin-material-'+layer,scene);m.disableLighting=true;m.emissiveColor=layer?new B.Color3(.95,.12,.05):new B.Color3(.05,.15,.95);m.alpha=.45;m.backFaceCulling=false;mesh.material=m;skins.push(mesh);
    const lines=[];for(let i=0;i<=120;i++){const x=-15+i*.25;lines.push([new B.Vector3(x,.0002-.003*layer,-2.5),new B.Vector3(x,.0002-.003*layer,2.5)]);}for(let j=0;j<=25;j++){const z=-2.5+j*.2;lines.push([new B.Vector3(-15,.0002-.003*layer,z),new B.Vector3(15,.0002-.003*layer,z)]);}
    const edge=B.MeshBuilder.CreateLineSystem('FE-grid-'+layer,{lines},scene);edge.color=new B.Color3(.07,.12,.18);edges.push(edge);
   }
   window.hiddenLine=B.MeshBuilder.CreateLines('hidden-occlusion-probe',{points:[new B.Vector3(-6,-.1,0),new B.Vector3(6,-.1,0)]},scene);hiddenLine.color=new B.Color3(0,1,0);
   window.transparency=WingTransparency.create({scene});transparency.setEnabled(true);
   window.quality=null;window.calibration=null;
   window.render=async()=>{let stable=0;for(let i=0;i<180;i++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(r=>setTimeout(r,10));stable=scene.isReady()?stable+1:0;if(stable>=8)return;}throw Error('Scene did not become ready');};
   window.pose=({alpha,beta,ortho,solid})=>{
    camera.alpha=alpha;camera.beta=beta;camera.mode=ortho?B.Camera.ORTHOGRAPHIC_CAMERA:B.Camera.PERSPECTIVE_CAMERA;camera.orthoLeft=-20;camera.orthoRight=20;camera.orthoTop=15;camera.orthoBottom=-15;
    skins.forEach(m=>m.material.alpha=solid?1:.45);transparency.setEnabled(!solid);edges[1].setEnabled(!solid);
    scene.updateTransformMatrix(true);calibration?.dispose();
    // A screen-aligned red one-pixel diagonal checks actual subpixel line
    // coverage, independently from FE color and triangle lighting.
    const w=engine.getRenderWidth(),h=engine.getRenderHeight();const unproject=(x,y)=>B.Vector3.Unproject(new B.Vector3(x/960*w,y/720*h,.5),w,h,B.Matrix.Identity(),camera.getViewMatrix(),camera.getProjectionMatrix());
    calibration=B.MeshBuilder.CreateLines('subpixel-calibration',{points:[unproject(40,45),unproject(920,142)]},scene);calibration.color=new B.Color3(.9,.02,.02);
   };
   await render();return{backend,version:B.Engine.Version,adapter:engine.getInfo(),dpr:devicePixelRatio,initialWidth:engine.getRenderWidth(),initialHeight:engine.getRenderHeight()};
  },backend);
  async function capture(name){const png=await page.screenshot({path:path.join(out,name+'.png'),scale:'css'});return page.evaluate(async base64=>{
   const im=new Image();im.src='data:image/png;base64,'+base64;await im.decode();const c=document.createElement('canvas');c.width=im.width;c.height=im.height;const ctx=c.getContext('2d');ctx.drawImage(im,0,0);const d=ctx.getImageData(0,0,c.width,c.height).data;
   const centers=[];let coverage=0,partial=0,redPixels=0;const bins=new Set();
   for(let x=55;x<905;x++){let sum=0,weighted=0;for(let y=25;y<160;y++){const i=(y*c.width+x)*4,r=d[i],g=d[i+1],b=d[i+2],weight=Math.max(0,r-(g+b)/2);if(weight<2)continue;sum+=weight;weighted+=weight*(y+.5);coverage+=weight;redPixels++;if(weight>8&&weight<195)partial++;bins.add(Math.round(weight));}if(sum>15)centers.push([x+.5,weighted/sum]);}
   const n=centers.length,mx=centers.reduce((s,p)=>s+p[0],0)/n,my=centers.reduce((s,p)=>s+p[1],0)/n;let xy=0,xx=0;for(const[x,y]of centers){xy+=(x-mx)*(y-my);xx+=(x-mx)**2;}const slope=xy/xx,intercept=my-slope*mx,jitter=Math.sqrt(centers.reduce((s,[x,y])=>s+(y-slope*x-intercept)**2,0)/n);
   // A genuinely reversed peel is red-dominant. Dark antialiased grid pixels
   // may approach neutral and must not be mistaken for a reversed blue skin.
   let colored=0,wrong=0,grid=0,hiddenGreen=0;for(let y=170;y<c.height;y++)for(let x=0;x<c.width;x++){const i=(y*c.width+x)*4,r=d[i],g=d[i+1],b=d[i+2];if(Math.max(r,b)-g>30&&g<220){colored++;if(r>b+10)wrong++;}if(r<80&&g<100&&b<130)grid++;if(g>r+30&&g>b+30)hiddenGreen++;}
   return{width:c.width,height:c.height,calibration:{samples:n,coverage,partial,redPixels,levels:bins.size,jitter,slope},sheet:{colored,wrong,wrongFraction:wrong/colored,grid,hiddenGreen}};
  },png.toString('base64'));}
  const cases=[['front-translucent',-1.1,.9,false,false],['grazing-translucent',-1.1,1.42,false,false],['orthographic-translucent',-.6,1.15,true,false],['front-solid',-.9,.9,false,true]];
  for(const[name,alpha,beta,ortho,solid]of cases){
   await page.evaluate(async p=>{quality?.dispose();quality=null;engine.setHardwareScalingLevel(1/devicePixelRatio);engine.resize();pose(p);await render();},{alpha,beta,ortho,solid});const before=await capture(name+'-before');
   await page.evaluate(async()=>{quality=WingLineQuality.create({BABYLON,scene,camera,canvas:document.getElementById('canvas')});await render();});const after=await capture(name+'-after');
   const state=await page.evaluate(()=>({gpuErrors:[...gpuErrors],width:engine.getRenderWidth(),height:engine.getRenderHeight(),camera:[camera.alpha,camera.beta,camera.mode],ready:scene.isReady()}));
   results.push({name,before,after,state,jitterReductionPercent:100*(1-after.calibration.jitter/before.calibration.jitter)});
   assert.deepEqual(state.gpuErrors,[]);assert(state.ready);assert(before.calibration.samples>820&&after.calibration.samples>820,'Diagonal lines must remain continuous');
   assert(after.calibration.coverage/before.calibration.coverage>.50,'Thin lines must remain visible');
   if(solid){assert(after.calibration.jitter<.12,'Already antialiased solid lines must retain subpixel precision');assert(after.calibration.partial>before.calibration.partial*1.2,'Solid edges must gain smoother coverage transitions');assert.equal(after.sheet.hiddenGreen,0,'Opaque skin must occlude the green line below it');}
   else assert(after.calibration.jitter<before.calibration.jitter*.9,'The displayed diagonal must have measurably smoother pixel coverage: '+JSON.stringify({name,before:before.calibration,after:after.calibration}));
   assert(after.sheet.colored>3000,'FE surface must remain visible');assert(after.sheet.wrongFraction<.02,'Anti-aliasing must preserve front/back skin color ordering');
  }
  // Positive control: the same hidden probe becomes visibly green once the
  // occluding FE surfaces are removed; an invisible probe cannot pass the test.
  await page.evaluate(async()=>{skins.forEach(m=>m.setEnabled(false));edges.forEach(m=>m.setEnabled(false));await render();});
  const occlusionControl=await capture('hidden-line-visible-control');assert(occlusionControl.sheet.hiddenGreen>100,'The occlusion probe must be visible without the skin');
  await page.setViewportSize({width:880,height:660});await page.evaluate(async()=>{engine.resize();quality?.resize?.();await render();});
  const lifecycle=await page.evaluate(async()=>{
   const B=BABYLON,c=B.Color4.FromHexString('#4d99ccb3'),source=B.MeshBuilder.CreateLineSystem('vertex-colored-probe',{lines:[[new B.Vector3(-2,1,0),new B.Vector3(2,1,0)]],colors:[[c,c]],updatable:true},scene);
   // Loft cuts deliberately set both the native uniform and vertex colors.
   // Native vertex-colored lines ignore that uniform; do not multiply twice.
   source.color=new B.Color3(c.r,c.g,c.b);await render();const proxy=source._wingScreenStroke,white=proxy.material.emissiveColor.asArray(),colors=Array.from(proxy.getVerticesData('color'));
   const first=proxy.getVerticesData('position'),other=proxy.getVerticesData('strokeOther'),indices=proxy.getIndices(),points=source.getVerticesData('position').slice();points[1]+=.15;source.updateVerticesData('position',points,true);await render();
   const reused=first===proxy.getVerticesData('position')&&other===proxy.getVerticesData('strokeOther')&&indices===proxy.getIndices(),moved=proxy.getVerticesData('position')[1]===points[1];
   source.updateIndices(Int32Array.from([]));await render();const empty=!proxy.isEnabled();source.updateIndices(Int32Array.from([0,1]));await render();const restored=proxy.isEnabled()&&proxy.getTotalIndices()===6;
   const hidden=B.MeshBuilder.CreateLines('lazy-hidden-probe',{points:[B.Vector3.Zero(),B.Vector3.One()]},scene);hidden.setEnabled(false);await render();const lazy=!hidden._wingScreenStroke;hidden.setEnabled(true);await render();const shown=!!hidden._wingScreenStroke;
   const active=camera._postProcesses.filter(Boolean).length;quality.dispose();await render();
   return{active,disposed:camera._postProcesses.filter(Boolean).length,remainingStrokes:scene.meshes.filter(m=>m.metadata?.wingStrokeSource).length,white,colors,expected:[c.r**2.2,c.g**2.2,c.b**2.2,c.a],reused,moved,empty,restored,lazy,shown,errors:[...gpuErrors]};
  });assert.deepEqual(lifecycle.errors,[]);assert.equal(lifecycle.disposed,0);assert.equal(lifecycle.remainingStrokes,0);assert.deepEqual(lifecycle.white,[1,1,1]);for(let k=0;k<lifecycle.colors.length;k++)assert(Math.abs(lifecycle.colors[k]-lifecycle.expected[k%4])<1e-6);assert(lifecycle.reused&&lifecycle.moved&&lifecycle.empty&&lifecycle.restored&&lifecycle.lazy&&lifecycle.shown);assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,info,results,occlusionControl,lifecycle,errors,external},null,2));console.log(backend+': four real-pixel scenes, color preservation, reused animation buffers, index filtering, lazy hidden layers and disposal pass without GPU errors.');
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,results,errors,external},null,2));throw e;}finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
