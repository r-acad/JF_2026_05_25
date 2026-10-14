"use strict";
// node ground_lighting_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Completed generated FE fixture: schema.json and payload.msgpack (gaps_ accepted).
// CHROME_PATH optionally selects a browser executable.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Usage: node ground_lighting_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const fixtureFile=name=>{const file=path.join(fixture,name);return fs.existsSync(file)?file:path.join(fixture,'gaps_'+name);};
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],results=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1450,height:1000}});page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43996/**',async route=>{const url=new URL(route.request().url());if(url.pathname.startsWith('/api/'))throw Error('Ground display must not request model or solver work');return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43996/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(async({bytes,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;state.autoMeshEnabled=false;
   document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);
   document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;activateWorkspaceTab('displaygeometry');
   window.structural=new Set(state.data.groups.flatMap(g=>state.layers.get(g.name)?.meshes||[]).filter(m=>m.material&&!m.material.disableLighting&&m.material.alpha===1));
   state.camera.radius*=1.4;state.viewPlanes.configure({z:state.data.bbox.min[2]-.8,spacing:1});
   window.render=async(n=3)=>{state.engine.resize();await state.scene.whenReadyAsync();for(let i=0;i<n;i++){state.scene.render();await new Promise(requestAnimationFrame);}};
   window.snapshot=()=>({lights:state.scene.lights.map(l=>({id:l.id,intensity:l.intensity,direction:l.direction?.asArray(),diffuse:l.diffuse.asArray(),specular:l.specular.asArray()})),environment:state.scene.environmentTexture?.uniqueId||null,environmentIntensity:state.scene.environmentIntensity,image:{exposure:state.scene.imageProcessingConfiguration.exposure,contrast:state.scene.imageProcessingConfiguration.contrast,tone:state.scene.imageProcessingConfiguration.toneMappingEnabled},materials:[...structural].map(m=>({id:m.uniqueId,material:m.material.uniqueId,disableLighting:m.material.disableLighting,emissive:m.material.emissiveColor?.asArray(),diffuse:m.material.diffuseColor?.asArray(),alpha:m.material.alpha,vertexColors:m.useVertexColors})),oit:state.scene.useOrderIndependentTransparency,camera:state.scene.activeCamera.uniqueId,view:Array.from(state.scene.getViewMatrix().asArray()),projection:Array.from(state.scene.getProjectionMatrix().asArray()),clip:state.scene.clipPlane?.asArray()||null,forcedView:state.scene._forcedViewPosition?.asArray()||null});
   window.sample=async(points)=>{const width=state.engine.getRenderWidth(),height=state.engine.getRenderHeight(),rgba=await state.engine.readPixels(0,0,width,height);return points.map(([x,y])=>Array.from(rgba.slice(((height-1-y)*width+x)*4,((height-1-y)*width+x)*4+3)));};
   window.points=async()=>{const width=state.engine.getRenderWidth(),height=state.engine.getRenderHeight(),points=[],rgba=await state.engine.readPixels(0,0,width,height);for(let y=30;y<height-30;y+=11)for(let x=30;x<width-30;x+=11){const offsets=[[0,0],[-3,0],[3,0],[0,-3],[0,3]],hits=offsets.map(([dx,dy])=>state.scene.pick(x+dx,y+dy,m=>structural.has(m)&&m.isEnabled()));if(!hits.every(h=>h.hit&&h.pickedMesh===hits[0].pickedMesh))continue;const center=((height-1-y)*width+x)*4;if(offsets.every(([dx,dy])=>[0,1,2].every(c=>Math.abs(rgba[((height-1-y-dy)*width+x+dx)*4+c]-rgba[center+c])<2)))points.push([x,y]);}return points;};
   await render();
  },{bytes:[...fs.readFileSync(fixtureFile('payload.msgpack'))],schema:JSON.parse(fs.readFileSync(fixtureFile('schema.json'),'utf8'))});
  for(const [view,beta,alpha,oit]of[['above',1.05,-.95,false],['side',1.48,-.35,false],['below',2.15,-.95,false],['oit-above',1.05,-.95,true],['oit-below',2.15,-.95,true]]){
   await page.evaluate(async({beta,alpha,oit})=>{
    state.camera.beta=beta;state.camera.alpha=alpha;state.viewPlanes.configure({z:beta>Math.PI/2?state.data.bbox.max[2]+.8:state.data.bbox.min[2]-.8,spacing:1});state.transparency.setEnabled(oit);state.viewPlanes.setVisible(false,false);await render();window.samples=await points();window.baseline=await sample(samples);
    // Reject already unstable coplanar support/edge pixels before measuring
    // ground effects; keep all real default layers and camera lighting active.
    for(let i=0;i<8;i++){await render(1);const next=await sample(samples),stable=samples.map((_,j)=>j).filter(j=>next[j].every((v,c)=>Math.abs(v-baseline[j][c])<=1));samples=stable.map(j=>samples[j]);baseline=stable.map(j=>baseline[j]);}
    window.beforeState=snapshot();
   }, {beta,alpha,oit});
   const sampleCount=await page.evaluate(()=>samples.length);assert(sampleCount>20,'Enough interior FE pixels: '+sampleCount);
   await page.screenshot({path:path.join(out,view+'-baseline.png')});
   for(const style of['metallic','wireframe','translucent','solid','metallic']){
    const result=await page.evaluate(async({style,view})=>{state.viewPlanes.setGroundAppearance({style,opacity:.35});state.viewPlanes.setVisible(true,false);await render(1);const first=await sample(samples);await render(3);const after=await sample(samples);const compare=pixels=>{let maximum=0,changed=0,total=0;for(let i=0;i<pixels.length;i++){let delta=0;for(let c=0;c<3;c++){const d=Math.abs(pixels[i][c]-baseline[i][c]);maximum=Math.max(maximum,d);delta=Math.max(delta,d);total+=d;}if(delta>2)changed++;}return{maximum,changed,mean:total/(samples.length*3)};};return{view,style,sampleCount:samples.length,first:compare(first),...compare(after),before:beforeState,after:snapshot()};},{style,view});results.push(result);
    await page.screenshot({path:path.join(out,view+'-'+style+'.png')});
   }
  }
  for(const result of results){assert.deepEqual(result.after,result.before,'Scene lighting and FE material state '+result.view+' '+result.style);assert.equal(result.changed,0,JSON.stringify({view:result.view,style:result.style,changed:result.changed,max:result.maximum,mean:result.mean}));assert.equal(result.first.changed,0,'First reflection frame '+JSON.stringify(result.first));}
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,results,errors},null,2));console.log('Ground lighting: unchanged real FE mesh colors and lighting across 25 finish/perspective/transparency combinations.');
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,results,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
