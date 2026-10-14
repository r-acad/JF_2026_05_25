'use strict';
// node test/navigation_material_axes_app_test.cjs <payload+schema directory> <evidence directory> [playwright module]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixture,out,modulePath]=process.argv.slice(2);if(!fixture||!out)throw Error('Specify fixture and evidence directories');
const web=path.resolve(__dirname,'../web'),{chromium}=require(modulePath?path.resolve(modulePath):'playwright');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1600,height:1050}}),errors=[];
 try{
  page.on('pageerror',e=>errors.push(e.stack));const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43989/**',route=>{const name=new URL(route.request().url()).pathname;return route.fulfill(name.endsWith('.js')?{contentType:'application/javascript',body:fs.readFileSync(path.join(web,name),'utf8')}:{contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});});
  await page.goto('http://127.0.0.1:43989/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(({bytes,schema})=>{initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);setBusy(false);document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;window.frame=()=>{state.engine.resize();for(let i=0;i<3;i++)state.scene.render();state.annotations.render(true);};activateWorkspaceTab('displaylabels');frame();},{bytes:Array.from(fs.readFileSync(path.join(fixture,'payload.msgpack'))),schema:JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'))});
  assert.equal(await page.evaluate(()=>state.layers.get('MATERIAL_AXES').meshes.length),0,'hidden material glyphs are lazy');
  await page.locator('#show-material-axis-labels').check();
  assert(await page.evaluate(()=>{frame();return state.layers.get('MATERIAL_AXES').meshes.length===0&&!state.layers.get('MATERIAL_AXES').visible&&state.annotations.stats.materialAxesShown.length>0;}),'labels can be shown without building axis arrows');
  await page.locator('#show-material-axis-labels').uncheck();
  await page.locator('#show-material-axes').check();
  assert(await page.evaluate(()=>{frame();return state.layers.get('MATERIAL_AXES').visible&&!(state.annotations.stats.materialAxesShown||[]).length;}),'arrows do not force labels on');
  await page.locator('#show-material-axis-labels').check();
  const axes=await page.evaluate(()=>{frame();return{meshes:state.layers.get('MATERIAL_AXES').meshes.length,labels:state.materialAxisLabels.map(x=>x.text),shown:state.annotations.stats.materialAxesShown};});
  assert.equal(axes.meshes,2,JSON.stringify(await page.evaluate(()=>({axes:state.data.groups.map(g=>({kind:g.kind,count:g.count,orientation:g.material_orientation,material:WingMaterialAxes.axes(state,g,{asF32,asI32,groupIds})})),note:document.getElementById('axes-note').textContent}))));assert(axes.labels.length>0&&axes.labels.every(t=>/MCID \d+|θ /.test(t)));assert(axes.shown.length>0);
  await page.screenshot({path:path.join(out,'material-axes.png')});
  const restored=await page.evaluate(()=>{const saved=WingWorkspace.captureView(document,state,workspaceUI);setLayerVisible('MATERIAL_AXES',false);document.getElementById('show-material-axis-labels').checked=false;restoreWorkspaceView(saved);frame();return state.layers.get('MATERIAL_AXES').visible&&document.getElementById('show-material-axes').checked&&document.getElementById('show-material-axis-labels').checked;});assert(restored);
  await page.locator('#show-material-axes').uncheck();
  assert(await page.evaluate(()=>{frame();return !state.layers.get('MATERIAL_AXES').visible&&state.annotations.stats.materialAxesShown.length>0;}),'hiding arrows preserves labels');
  const progress=await page.evaluate(()=>{showStartupStudyNotice({status:'loading',name:'example.json',message:'Loading latest Study example.json from its accessible disk file.'});return !!document.getElementById('startup-study-notice');});assert.equal(progress,false);
  // Exercise the actual load operation until the schema fetch. Its first
  // frame must retain the filename even as stage details change.
  const label=await page.evaluate(async()=>{let captured;await loadModelDefinition({name:'example.json',text:async()=>{captured=document.getElementById('activity-label').textContent;throw Error('intentional offline test');}});return captured;});assert.match(label,/Loading Study · example.json/);
  await page.evaluate(()=>{setLayerVisible('MATERIAL_AXES',false);document.getElementById('model-error').hidden=true;state.camera.alpha=.43;state.camera.beta=1.12;fitView();state.camera.radius*=2;frame();});
  const before=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius}));
  const empty=await page.evaluate(()=>{const canvas=document.getElementById('render'),r=canvas.getBoundingClientRect();for(let y=20;y<r.height;y+=40)for(let x=20;x<r.width;x+=40){const hit=state.scene.pick(x,y,m=>m.isEnabled()&&m.isVisible&&m.isPickable&&!m.metadata?.wingViewHelper);if(!hit?.hit)return{x:r.left+x,y:r.top+y};}throw Error('no empty canvas point');});
  await page.mouse.dblclick(empty.x,empty.y);const after=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius}));
  assert(Math.abs(after.alpha-before.alpha)<1e-8&&Math.abs(after.beta-before.beta)<1e-8);assert(Math.abs(after.radius-before.radius/2)<1e-6);
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,axes,restored,label,before,after,errors},null,2));console.log('Navigation/material axes full-app PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
