'use strict';
// Real application, isolated native fixture and mocked routes. No user files change.
// node study_loading_fast_browser_test.cjs OUT FIXTURE PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,pwArg,browserArg]=process.argv.slice(2);
if(!outArg||!fixtureArg||!pwArg)throw Error('Output, fixture and Playwright paths are required');
const out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(pwArg));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
const msgpack=require(path.join(web,'vendor/msgpack.min.js'));
const preview=Buffer.from(msgpack.encode({aero:{xyz:[0,0,0,1,0,0,1,4,0,0,4,0],conn:[0,1,2,3],sections:[]},bbox:{min:[0,0,0],max:[1,4,.1]},movables:{surfaces:[]}}));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1800,height:1100}}),requests=[],errors=[],checks=[];page.setDefaultTimeout(30000);page.on('pageerror',e=>errors.push(e.message));
 const settle=()=>page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy&&!state.studyRestoring&&!state.meshRequestInFlight);
 const authored=()=>page.waitForFunction(()=>state.geometryPreview?.active&&state.scene.getMeshByName('live-geometry-loft')?.getTotalVertices()>0);
 const count=p=>requests.filter(r=>r.path===p).length;
 const modelSnapshot=()=>page.evaluate(()=>({epoch:state.studyEpoch,file:state.studyFile,dirty:state.studyDirty,title:state.values['output.title'],notes:structuredClone(state.studyNotes),refs:state.reference.entries.map(entry=>({id:entry.id,name:entry.name,visible:entry.visible,wireframe:entry.wireframe,opacity:entry.opacity,locked:entry.locked,transform:state.reference.getTransform(entry)})),auto:state.autoMeshEnabled,mesh:!!state.data}));
 const load=study=>page.evaluate(text=>loadModelDefinition(new File([text],'Fast-loading.wingfem.json',{type:'application/json'}),{recent:true}),typeof study==='string'?study:JSON.stringify(study));
 try{
  await page.route('http://127.0.0.1:43989/**',async route=>{
   const u=new URL(route.request().url()),data=route.request().method()==='POST'?route.request().postDataJSON():null;
   if(u.pathname.startsWith('/api/'))requests.push({path:u.pathname,title:data?.['output.title']||null});
   if(u.pathname==='/api/input')return route.fulfill({json:schema});
   if(['/api/validate_workspace','/api/restore_workspace'].includes(u.pathname))return data?.['output.title']==='Reject loading fixture'?
    route.fulfill({status:400,json:{error:'Saved parameter value is invalid in fixture'}}):route.fulfill({json:{ok:true,parameters:data}});
   if(['/api/generate','/api/prepare_workspace'].includes(u.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
   if(u.pathname==='/api/geometry_preview')return route.fulfill({body:preview,contentType:'application/msgpack'});
   if(u.pathname==='/api/movable_surfaces')return route.fulfill({json:{ok:true,surfaces:[]}});
   if(u.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(u.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(u.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(u.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated Study loading test'}});
   const file=u.pathname.startsWith('/shared/')?path.join(web,'../..',u.pathname.slice(8)):path.join(web,u.pathname==='/'?'index.html':decodeURIComponent(u.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing isolated fixture asset'});
  });
  await page.goto('http://127.0.0.1:43989/');await page.locator('.startup-study-dialog [data-choice=new]').waitFor();
  assert(await page.locator('#splash').isVisible());assert.equal(await load('{malformed'),false);assert(await page.locator('#splash').isVisible());assert.equal(await page.evaluate(()=>state.autoMeshReady),false);
  checks.push('Initial welcome remains until a Study commits; malformed loading does not dismiss it or create a Study.');
  await page.locator('.startup-study-dialog [data-choice=new]').click();await settle();await authored();assert(!await page.locator('#splash').isVisible());assert.equal(await page.evaluate(()=>state.data),null);
  checks.push('A new authored model dismisses the welcome immediately and shows geometry without a FEM.');
  const saved=await page.evaluate(async()=>{
   const view=WingWorkspace.captureView(document,state,workspaceUI);view.controls['auto-mesh']=true;view.workspace.activeTab='planform';
   const data=await WingWorkspace.snapshot(collectParams(),null,view,{notes:{text:'Retain this saved note',history:[]},identification:{text:'Assignment loading test',visible:true}});
   data.parameters['output.title']='Saved auto-on model';data.references=[{source_name:'Fixture.stl',units:'m',axis:'fe',position_m:[.2,.3,.4],rotation_deg:[0,0,0],scale:[1,1,1],visible:true,wireframe:true,opacity:.65,locked:true,scale_linked:true,
    data_base64:btoa('solid fixture\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid fixture\n')}];
   return data;
  });
  const before={restore:count('/api/restore_workspace'),prepare:count('/api/prepare_workspace'),generate:count('/api/generate'),validate:count('/api/validate_workspace')};
  assert.equal(await load(saved),true);await settle();await authored();await page.waitForTimeout(1000);
  assert.equal(count('/api/restore_workspace'),before.restore+1);assert.equal(count('/api/prepare_workspace'),before.prepare);assert.equal(count('/api/generate'),before.generate);assert.equal(count('/api/validate_workspace'),before.validate);
  const loaded=await modelSnapshot();assert.equal(loaded.title,'Saved auto-on model');assert.equal(loaded.file,'Fast-loading.wingfem.json');assert.equal(loaded.dirty,false);assert.equal(loaded.mesh,false);assert.equal(loaded.auto,true);
  assert(await page.locator('#auto-mesh').isChecked());assert(!await page.locator('#splash').isVisible());assert.equal(await page.locator('#btn-save-model').getAttribute('data-saved'),'true');
  assert.equal(await page.evaluate(()=>state.reference.entries.length),1);assert.equal(loaded.refs[0].name,'Fixture.stl');assert.deepEqual(loaded.refs[0].transform.position,[.2,.3,.4]);assert.equal(loaded.refs[0].wireframe,true);assert.equal(loaded.notes.text,'Retain this saved note');
  const portable=await page.evaluate(async()=>{const item=(await state.reference.exportPortable())[0];return{metadata:item.metadata,text:new TextDecoder().decode(item.bytes)};});assert.match(portable.text,/solid fixture/);assert.equal(portable.metadata.opacity,.65);assert.equal(portable.metadata.locked,true);
  assert.equal(await page.evaluate(()=>state.studyWatermark.capture().text),'Assignment loading test');
  await page.screenshot({path:path.join(out,'saved-geometry-without-fem.png')});
  checks.push('Saved Auto-on Study uses only lightweight restoration, preserves its auto preference/references/notes/identification and stays saved without delayed FEM generation.');
  const invalid=structuredClone(saved);invalid.parameters['output.title']='Reject loading fixture';assert.equal(await load(invalid),false);await settle();assert.deepEqual(await modelSnapshot(),loaded);assert.equal(await page.evaluate(()=>state.reference.entries.length),1);assert(!await page.locator('#splash').isVisible());assert.match(await page.locator('#model-error').textContent(),/Saved parameter value is invalid/);
  assert.equal(await load('{malformed again'),false);await settle();assert.deepEqual(await modelSnapshot(),loaded);
  checks.push('Rejected parameter restoration and malformed JSON retain the complete previous Study and embedded reference.');
  const previewCount=count('/api/geometry_preview');await page.evaluate(()=>{const input=document.getElementById('p-planform.root_ref_z');input.value='1.25';parameterEdited('planform.root_ref_z');});
  await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy);assert.equal(count('/api/generate'),before.generate+1);assert(count('/api/geometry_preview')>=previewCount);assert.equal(await page.evaluate(()=>state.studyDirty),true);
  checks.push('The saved Auto-on preference still generates a FEM after a real subsequent definition edit.');
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();});
  assert.equal(await load(saved),true);await settle();await authored();const explicitBefore=count('/api/generate');await page.evaluate(()=>activateWorkspaceTab('mesh'));await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy);assert.equal(count('/api/generate'),explicitBefore+1);assert(!await page.locator('#splash').isVisible());
  checks.push('Explicit Create FEM performs the full generation request after loading a definition; the welcome stays dismissed.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'loaded-study.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,requests},null,2));console.log(JSON.stringify({passed:true,checks,errors},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests,state:await modelSnapshot().catch(()=>null)},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
