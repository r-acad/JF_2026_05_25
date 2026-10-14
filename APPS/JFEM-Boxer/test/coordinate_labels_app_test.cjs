'use strict';
// Read-only import/render proof; no solver or external service is used.
// node coordinate_labels_app_test.cjs <evidence-dir> [playwright-module]
// Evidence directory contains payload.msgpack and schema.json; screenshots and
// browser summaries are written alongside them. CHROME_PATH is optional.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(process.argv.length<3||process.argv.length>4){console.error('Usage: node coordinate_labels_app_test.cjs <evidence-dir> [playwright-module]');process.exit(2);}
const web=path.resolve(__dirname,'../web'),out=path.resolve(process.argv[2]),modulePath=process.argv[3]||process.env.WING_PLAYWRIGHT_MODULE;
const {chromium}=require(modulePath?path.resolve(modulePath):'playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  const page=await browser.newPage({viewport:{width:1600,height:1050}}),errors=[];
  try{
    page.on('pageerror',error=>errors.push(error.stack));const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
    await page.route('http://127.0.0.1:43988/**',route=>{const name=new URL(route.request().url()).pathname;return route.fulfill(name.endsWith('.js')?{contentType:'application/javascript',body:fs.readFileSync(path.join(web,name),'utf8')}:{contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});});
    await page.goto('http://127.0.0.1:43988/');
    for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
    for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
    const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
    await page.evaluate(({bytes,schema})=>{
      initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
      state.importedDeck=state.data.imported_deck?{...state.data.imported_deck,source:state.data.model_source}:null;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
      buildForm(state.schema,state.values);buildModel(state.data);setBusy(false);
      document.getElementById('activity-status').hidden=true;document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
      window.frame=()=>{state.engine.resize();for(let i=0;i<3;i++)state.scene.render();state.annotations.render(true);};
      activateWorkspaceTab('displaylabels');frame();
    },{bytes:Array.from(fs.readFileSync(path.join(out,'payload.msgpack'))),schema:JSON.parse(fs.readFileSync(path.join(out,'schema.json'),'utf8'))});
    const initial=await page.evaluate(()=>({visible:state.layers.get('COORDINATE_SYSTEMS').visible,checked:document.getElementById('show-coordinate-labels').checked,frames:state.data.coordinate_systems.systems.length,materialFrames:state.data.coordinate_systems.systems.filter(frame=>frame.usage?.shell_mcid>0).length}));
    assert(!initial.visible&&!initial.checked);
    await page.locator('#show-coordinate-labels').check();
    const labels=await page.evaluate(()=>{
      clearInspection();frame();const candidates=WingModelEntities.coordinateCandidates(state,true),layer=state.layers.get('COORDINATE_SYSTEMS');
      return{visible:layer.visible,enabled:layer.meshes.every(mesh=>mesh.isEnabled()),meshes:layer.meshes.length,candidates,groups:WingModelEntities.coordinateLabelGroups(candidates),shown:state.annotations.stats.coordinateSystemsShown,options:Array.from(document.getElementById('coordinate-select').options,option=>({value:option.value,text:option.text})),note:document.getElementById('id-label-status').textContent};
    });
    assert(labels.visible&&labels.enabled);assert.equal(labels.meshes,3);assert.equal(labels.candidates.length,initial.frames);assert.equal(labels.options.length,initial.frames+1);
    assert(labels.shown.length>0,'Coordinate labels must render in the initial fitted view: '+JSON.stringify(labels));
    assert.equal(labels.groups.reduce((n,row)=>n+(row.ids?.length||1),0),initial.frames);
    assert(labels.candidates.filter(row=>row.id!==0).every(row=>/RID|GRIDs/.test(row.text)));
    assert.equal(labels.candidates.filter(row=>/shell MCID/.test(row.text)).length,initial.materialFrames);
    assert.equal(labels.options.filter(row=>/shell MCID/.test(row.text)).length,initial.materialFrames);
    await page.screenshot({path:path.join(out,'coordinate-labels.png')});
    const last=String(labels.candidates.at(-1).id);await page.locator('#coordinate-select').selectOption(last);
    const selected=await page.evaluate(()=>{frame();return{selected:state.selectedCoordinate,text:document.getElementById('pick-content').textContent,visible:state.layers.get('COORDINATE_SYSTEMS').visible,shown:state.annotations.stats.coordinateSystemsShown,note:document.getElementById('id-label-status').textContent};});
    assert.equal(selected.selected,Number(last));assert(selected.visible);assert.match(selected.text,/Defined relative to/);
    if(initial.materialFrames===initial.frames-1){assert.match(selected.text,/Shell material uses/);assert.match(selected.text,/not a node attachment|do not attach frames/);}
    assert(selected.shown.includes(Number(last)));assert.match(selected.note,/1 \/ 1 labels shown/);
    await page.screenshot({path:path.join(out,'coordinate-selected.png')});
    const hidden=await page.evaluate(()=>{setLayerVisible('COORDINATE_SYSTEMS',false);frame();return WingModelEntities.coordinateCandidates(state,true).length;});assert.equal(hidden,0);
    await page.locator('#show-coordinate-labels').uncheck();await page.locator('#show-coordinate-labels').check();
    assert(await page.evaluate(()=>state.layers.get('COORDINATE_SYSTEMS').visible));
    const rebuild=await page.evaluate(()=>{buildModel(state.data);frame();const layer=state.layers.get('COORDINATE_SYSTEMS');return{visible:layer.visible,meshes:layer.meshes.length,enabled:layer.meshes.every(mesh=>mesh.isEnabled()),options:document.getElementById('coordinate-select').options.length};});
    assert(rebuild.visible&&rebuild.enabled);assert.equal(rebuild.meshes,3);assert.equal(rebuild.options,initial.frames+1);
    const restored=await page.evaluate(()=>{
      const saved=WingWorkspace.captureView(document,state,workspaceUI),control=document.getElementById('show-coordinate-labels');
      control.checked=false;control.dispatchEvent(new Event('change'));restoreWorkspaceView(saved);frame();
      const visible=state.layers.get('COORDINATE_SYSTEMS').visible&&!document.getElementById('coordinate-inspection').hidden;
      const off={...saved,controls:{...saved.controls,'show-coordinate-labels':false},layers:{...saved.layers,COORDINATE_SYSTEMS:false}};restoreWorkspaceView(off);frame();
      return{visible,hidden:!state.layers.get('COORDINATE_SYSTEMS').visible&&document.getElementById('coordinate-inspection').hidden};
    });assert(restored.visible&&restored.hidden);
    assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'coordinate-browser-summary.json'),JSON.stringify({passed:true,initial,labels,selected,rebuild,restored,errors},null,2));console.log('Coordinate import/render PASS: '+initial.frames+' frames, '+labels.groups.length+' origin groups, '+labels.shown.length+' CIDs represented by visible labels.');
  }catch(error){fs.writeFileSync(path.join(out,'coordinate-browser-failure.json'),JSON.stringify({error:error.stack,errors},null,2));await page.screenshot({path:path.join(out,'coordinate-browser-failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
