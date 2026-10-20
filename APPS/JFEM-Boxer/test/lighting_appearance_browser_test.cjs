"use strict";
// Real FE buffers, Babylon materials and GPU pixels; no numerical solve.
// node lighting_appearance_browser_test.cjs FIXTURE EVIDENCE [PLAYWRIGHT]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2);
if(!fixtureArg||!outArg)throw Error('Expected FIXTURE EVIDENCE [PLAYWRIGHT]');
const fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const {chromium}=require(modulePath),checks=[],errors=[];fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1600,height:1100}});page.on('pageerror',e=>errors.push(e.message));
 try {
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43989/**',route=>{
   const url=new URL(route.request().url());assert(!url.pathname.startsWith('/api/'),'Lighting must not request a mesh or solve');
   return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});
  });
  await page.goto('http://127.0.0.1:43989/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:source.slice(0,source.indexOf('(async function start()'))});
  await page.evaluate(async({bytes,input})=>{
   initScene();state.engine.stopRenderLoop();state.schema=input.schema;state.defaults=input.defaults;
   state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;state.autoMeshEnabled=false;
   document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);
   state.modelSignature=formSignature();setModelDirty(false);setBusy(false);document.getElementById('splash').hidden=true;
   WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   const bars=document.getElementById('beam-style');bars.value='sections';bars.dispatchEvent(new Event('change'));
   if(!state.barMeshes.some(mesh=>mesh.sectionGeometry))throw Error('Lighting fixture must include full 3D beam sections.');
   activateWorkspaceTab('displayenvironment');fitView();state.camera.radius*=1.15;
   window.frame=async()=>{state.engine.resize();await state.scene.whenReadyAsync();for(let i=0;i<3;i++){state.scene.render();await new Promise(requestAnimationFrame);}};
   window.originalGeometry=Array.from(state.baseline);window.definition=formSignature();
   window.physical=()=>[...state.shellMeshes,...state.barMeshes].filter(m=>m.material&&!m.material.disableLighting&&m.isEnabled());
   window.litMaterials=new Map(physical().map(m=>[m.material,{diffuse:m.material.diffuseColor.clone(),emissive:m.material.emissiveColor.clone(),specular:m.material.specularColor.clone()}]));
   window.vertexColors=physical().map(m=>Array.from(m.getVerticesData(BABYLON.VertexBuffer.ColorKind)||[]));
   window.legacyLighting=async enabled=>{
    state.sceneLighting.restore(enabled?{preset:'custom',shadows:false,selfShadows:false,ambient:.3,key:.3,fill:.2,headlight:.48,lowerFill:0,rim:0,keyDirection:[-.5,-.7,-1],fillDirection:[.6,.35,.8]}:undefined);
    for(const [m,fields]of litMaterials){m.diffuseColor=fields.diffuse.scale(enabled ? .86/.96 : 1);m.emissiveColor=fields.emissive.scale(enabled ? .035/.045 : 1);m.specularColor=enabled?new BABYLON.Color3(.045,.045,.045):fields.specular.clone();m.maxSimultaneousLights=enabled?4:6;}
    for(const i of [0,2])state.sceneLighting.lights[i].specular=enabled?BABYLON.Color3.White():BABYLON.Color3.Black();
    await frame();
   };
   window.surfacePixels=async()=>{
    const width=state.engine.getRenderWidth(),height=state.engine.getRenderHeight(),pixels=await state.engine.readPixels(0,0,width,height),meshes=new Set(physical()),values=[];
    for(let y=28;y<height-28;y+=12)for(let x=28;x<width-28;x+=12){
     const hit=state.scene.pick(x,y,m=>meshes.has(m));if(!hit.hit)continue;
     const neighbors=[[3,0],[-3,0],[0,3],[0,-3]].map(([dx,dy])=>state.scene.pick(x+dx,y+dy,m=>meshes.has(m)));
     if(neighbors.some(n=>!n.hit||n.pickedMesh!==hit.pickedMesh))continue;
     const at=4*((height-1-y)*width+x),rgb=[...pixels.slice(at,at+3)],luma=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];values.push({luma,rgb});
    }
    const luminance=values.map(v=>v.luma).sort((a,b)=>a-b),at=f=>luminance[Math.floor((luminance.length-1)*f)];
    return{samples:values.length,mean:luminance.reduce((a,b)=>a+b,0)/values.length,p10:at(.1),p50:at(.5),p90:at(.9),whiteFraction:values.filter(v=>v.rgb.every(c=>c>=250)).length/values.length};
   };
   await frame();
  },{bytes:[...fs.readFileSync(path.join(fixture,'payload.msgpack'))],input:JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'))});

  for(const [name,beta,alpha]of [['above',1.02,-.95],['below',2.15,-.95],['side',1.48,-.35]])for(const background of ['#0e131a','#ffffff']){
   const label=name+(background==='#ffffff'?'-white':'-dark');
   await page.evaluate(({beta,alpha,background})=>{state.camera.beta=beta;state.camera.alpha=alpha;applyBackgroundColor(background,false);},{beta,alpha,background});
   await page.evaluate(()=>legacyLighting(true));const before=await page.evaluate(()=>surfacePixels());
   await page.screenshot({path:path.join(out,label+'-before.png')});
   await page.evaluate(()=>legacyLighting(false));const after=await page.evaluate(()=>surfacePixels());
   await page.screenshot({path:path.join(out,label+'-after.png')});
   assert(after.samples>=25,label+' needs enough interior FE pixels');
   assert(after.mean>before.mean*1.10,label+' should be visibly brighter: '+JSON.stringify({before,after}));
   assert(after.whiteFraction<.15,label+' must retain colored faces rather than clipping to white');
   assert(after.p90-after.p10>12,label+' must retain shape/color contrast');
   checks.push({view:label,before,after,brightnessGain:after.mean/before.mean});
  }
  assert.equal(await page.locator('[aria-label="Lighting preset"] option').count(),7);
  for(const preset of ['balanced','soft','technical','inspection','presentation','overcast']){
   await page.locator('[aria-label="Lighting preset"]').selectOption(preset);
   await page.evaluate(()=>frame());
   assert.equal(await page.evaluate(()=>state.scene.lights.length),6);
   assert(await page.locator('.scene-lighting > label input[type="number"]').evaluateAll(inputs=>inputs.every(input=>input.checkValidity())));
   const value=await page.evaluate(()=>state.sceneLighting.capture());assert.equal(value.preset,preset);assert(value.lowerFill>0&&value.rim>0);
  }
  await page.locator('[aria-label="Lighting preset"]').selectOption('balanced');
  const saved=await page.evaluate(async()=>{
   const view=WingWorkspace.captureView(document,state,workspaceUI),parameters={...state.values,'references.items':[]};
   const study=await WingWorkspace.snapshot(parameters,state.reference,view);
   const reopened=WingWorkspace.parseObject(JSON.parse(JSON.stringify(study)));
   return{saved:study.view.lighting,reopened:reopened.data.view.lighting,current:state.sceneLighting.capture()};
  });
  assert.deepEqual(saved.saved,saved.current);assert.deepEqual(saved.reopened,saved.current);
  await page.evaluate(async()=>{const mode=document.getElementById('surface-mode');mode.value='translucent';mode.dispatchEvent(new Event('change'));await frame();});
  await page.screenshot({path:path.join(out,'translucent-3d-sections.png')});
  await page.evaluate(()=>{window.previousLayers=[...state.layers].map(([name,layer])=>[name,layer.visible]);batchLayerVisibility(()=>{for(const [name]of previousLayers)setLayerVisible(name,name==='AERO_SURFACE');});});
  for(const [name,beta]of [['above',1.02],['below',2.15]]){
   await page.evaluate(async beta=>{
    state.camera.beta=beta;state.camera.alpha=-.95;setLayerVisible('AERO_SURFACE',true);
    const style=document.getElementById('aero-deformed-style');style.value='metallic';style.dispatchEvent(new Event('change'));applyAeroOverlayStyles();await frame();
   },beta);
   await page.screenshot({path:path.join(out,'metallic-aero-'+name+'.png')});
   assert(await page.evaluate(()=>state.layers.get('AERO_SURFACE').meshes.some(m=>m.material instanceof BABYLON.PBRMaterial&&m.material.maxSimultaneousLights===6)));
  }
  await page.evaluate(()=>batchLayerVisibility(()=>{for(const [name,visible]of previousLayers)setLayerVisible(name,visible);}));
  assert.equal(await page.evaluate(()=>formSignature()===definition),true);
  assert.deepEqual(await page.evaluate(()=>Array.from(state.baseline)),await page.evaluate(()=>originalGeometry));
  assert.deepEqual(await page.evaluate(()=>physical().map(m=>Array.from(m.getVerticesData(BABYLON.VertexBuffer.ColorKind)||[]))),await page.evaluate(()=>vertexColors));
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,comparisons:checks,errors},null,2));
  console.log('Lighting appearance: brighter FE pixels from six views, retained contrast/colors, six presets, translucency and metallic rendering passed.');
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
