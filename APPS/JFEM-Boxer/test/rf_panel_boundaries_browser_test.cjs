'use strict';
// Actual authored FEM/group topology and previously observed native RFs;
// one explicitly synthetic passing estimate tests rendering invalidation only.
// No FE analysis, numerical assessment or native service is launched.
// FIXTURE_DIR OBSERVED_RF_SUMMARY OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,rfSummaryArg,outArg,modulePath='playwright']=process.argv.slice(2);
if(!outArg)throw Error('Expected FIXTURE_DIR OBSERVED_RF_SUMMARY OUTPUT PLAYWRIGHT_MODULE');
const fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..'),{chromium}=require(modulePath),MessagePack=require('../web/vendor/msgpack.min.js');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),payloadBytes=fs.readFileSync(path.join(fixture,'payload.msgpack')),payload=MessagePack.decode(payloadBytes),observed=JSON.parse(fs.readFileSync(rfSummaryArg,'utf8')),rows=observed.baselineRF?.rows||observed.rows;
assert(rows?.length&&rows.every(r=>r.complete&&Number.isFinite(r.rf)),'Expected complete observed native property RFs');schema.defaults=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1050},deviceScaleFactor:2}),page=await context.newPage(),origin='http://127.0.0.1:43983',checks=[],errors=[],requests=[],frames={};page.setDefaultTimeout(90000);page.on('pageerror',error=>errors.push(error.stack));
 await context.route(origin+'/**',route=>{
  const p=new URL(route.request().url()).pathname;if(p.startsWith('/api/'))requests.push(p);
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(['/api/validate_workspace','/api/restore_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/generate','/api/prepare_workspace'].includes(p))return route.fulfill({body:payloadBytes,contentType:'application/msgpack'});
  if(p==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Rendering-only boundary acceptance; no numerical endpoints are available.'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':decodeURIComponent(p))});
 });
 const snapshot=()=>page.evaluate(()=>{
  state.scene.render();state.scene.render();
  const key=(a,b)=>Math.min(a,b)+':'+Math.max(a,b),point=n=>Array.from(state.baseline.slice(3*n,3*n+3)),pointKey=p=>p.map(Math.fround).join(','),positionKey=(a,b)=>[pointKey(a),pointKey(b)].sort().join('|');
  const allowed=state.rfField?.request.onlyBelowOne?state.rfField.contour.failingElementIds:null;
  // Independent topology oracle: count edges within each authored group;
  // then retain one global stroke for each group perimeter. A shared border
  // between two groups must survive; a shared edge inside one group must not.
  const expected=[],allPerimeters=new Map(),internal=new Set();
  for(const panel of state.data?.stiffened_panels?.panels||[]){
   const faces=[...new Set([...(panel.shell_eids||panel.skin_eids||[]),...(panel.stringer_flange_eids||[])])].filter(eid=>{const e=state.elements.get(eid);return e&&['quad','tria'].includes(e.group.kind)&&state.layers.get(e.group.name)?.visible!==false;});let members=allowed?faces.filter(eid=>allowed.has(eid)):faces;
   const barOnly=!!allowed&&!members.length&&(panel.stringer_eids||[]).some(eid=>{const e=state.elements.get(eid);return e&&allowed.has(eid)&&state.layers.get(e.group.name)?.visible!==false;});if(barOnly)members=faces;if(!members.length)continue;
   const counts=new Map();for(const eid of members){const e=state.elements.get(eid);for(let i=0;i<e.nodes.length;i++){const a=e.nodes[i],b=e.nodes[(i+1)%e.nodes.length];if(a===b)continue;const k=key(a,b),old=counts.get(k);if(old)old.count++;else counts.set(k,{count:1,a,b,eid});}}
   const boundary=[...counts].filter(([,v])=>v.count===1).map(([k,v])=>({key:k,a:v.a,b:v.b,eid:v.eid}));
   for(const[k,v]of counts)if(v.count>1)internal.add(positionKey(point(v.a),point(v.b)));
   for(const e of boundary){const k=positionKey(point(e.a),point(e.b));allPerimeters.set(k,(allPerimeters.get(k)||0)+1);}
   expected.push({key:panel.key,panelId:panel.id,elementIds:members.slice().sort((a,b)=>a-b),stringerOnly:barOnly,segments:boundary.map(e=>e.key).sort()});
  }
  const controller=state.rfPanelOutlines,groups=(controller?.groups||[]).map(g=>({key:g.key,panelId:g.panelId,elementIds:Array.from(g.elementIds||[]).sort((a,b)=>a-b),stringerOnly:!!g.stringerOnly,segments:(g.segments||[]).map(e=>key(e.a,e.b)).sort()})),sources=state.scene.meshes.filter(m=>m.metadata?.rfPanelOutline&&!m.isDisposed()),rendered=[],styles=[];
  for(const source of sources){
   const visible=source.isEnabled()&&source.isVisible&&source.visibility>0,positions=source.getVerticesData(BABYLON.VertexBuffer.PositionKind),indices=source.getIndices();
   if(visible)for(let i=0;i<indices.length;i+=2){const a=Array.from(positions.slice(3*indices[i],3*indices[i]+3)),b=Array.from(positions.slice(3*indices[i+1],3*indices[i+1]+3));rendered.push(positionKey(a,b));}
   const proxy=source._wingScreenStroke,plugin=proxy?.material?.pluginManager?.getPlugin('BoxerScreenStroke');let cssWidth=null;const ratio=state.engine.getRenderWidth()/state.engine.getRenderingCanvas().getBoundingClientRect().width;
   if(plugin)plugin.bindForSubMesh({updateFloat3(name,w,h,width){cssWidth=width/ratio;}});
   styles.push({name:source.name,visible,pickable:source.isPickable,color:source.color?.toHexString(),alpha:source.alpha,requestedWidth:source.metadata.strokeWidthPx,cssWidth,proxy:!!proxy,proxyPickable:proxy?.isPickable});
  }
  const expectedSegments=[...allPerimeters.keys()].sort(),shared=[...allPerimeters].filter(([,count])=>count>1).map(([key])=>key),internalOnly=[...internal].filter(k=>!allPerimeters.has(k));
  return{active:!!state.rfField,groupCount:groups.length,groups:groups.sort((a,b)=>a.key.localeCompare(b.key)),expected:expected.sort((a,b)=>a.key.localeCompare(b.key)),expectedSegments,rendered:rendered.sort(),shared,internalOnly,styles,sourceCount:sources.length,proxyCount:state.scene.meshes.filter(m=>m.metadata?.wingStrokeSource&&m.parent?.metadata?.rfPanelOutline&&!m.isDisposed()).length,mask:state.rfVisibleElementIds?[...state.rfVisibleElementIds].sort((a,b)=>a-b):null,meshIdentity:state.meshIdentity};
 });
 async function assertFrame(label){const numerical=await page.evaluate(()=>({available:state.rfField?.contour.available,stale:state.rfField?.contour.stale,mask:state.rfVisibleElementIds?.size}));assert(numerical.available>0,label+' has no usable presentation oracle: '+JSON.stringify(numerical));await page.waitForFunction(()=>{state.scene.render();const sources=state.scene.meshes.filter(m=>m.metadata?.rfPanelOutline&&!m.isDisposed());return sources.length&&sources.every(m=>m._wingScreenStroke);});const value=await snapshot();assert(value.active,label+' requires an RF field');assert.deepEqual(value.groups,value.expected,label+' authored group boundaries');assert.deepEqual(value.rendered,value.expectedSegments,label+' actual line positions');assert.equal(value.rendered.length,new Set(value.rendered).size,label+' shared borders must not be drawn twice');for(const segment of value.shared)assert(value.rendered.includes(segment),label+' missing shared physical-group border');for(const segment of value.internalOnly)assert(!value.rendered.includes(segment),label+' retained ordinary internal FE edge');for(const style of value.styles){assert(style.visible);assert.equal(style.pickable,false);assert.equal(style.proxyPickable,false);assert.equal(style.color.toLowerCase(),'#103b73');assert.equal(style.alpha,1);assert.equal(style.requestedWidth,3.5);assert.equal(style.cssWidth,3.5);assert(style.proxy);}frames[label]=value;return value;}
 const topology=()=>page.evaluate(()=>JSON.stringify([Array.from(state.data.nodes.ids),Array.from(state.data.nodes.xyz),state.data.groups.map(g=>[g.pid,g.kind,Array.from(g.eids),Array.from(g.conn)])]));
 async function draw({only=false,estimated=false,passingPids=[]}={}){
  await page.evaluate(({rows,only,estimated,passingPids})=>{
   const counts=new Map();for(const e of state.elements.values())counts.set(e.group.pid,(counts.get(e.group.pid)||0)+1);
   const report={failureMode:'minimum_rf',includedCases:[],rows:rows.map(row=>({pid:row.pid,complete:true,coverage:{recovered:counts.get(row.pid),total:counts.get(row.pid)},reserveFactor:passingPids.includes(row.pid)?1.25:row.rf,combined:{governingMode:'von_mises',governingModeLabel:'Observed RF presentation',governingScope:'Rendering oracle'}}))};
   const input={elements:state.elements,panels:state.data.stiffened_panels.panels,generated:true},request={kind:'minimum_rf',caseId:'all',failureMode:'minimum_rf',palette:'signed',onlyBelowOne:only},contour=WingRFFieldData.project(input,report,request);
   if(!contour.available||contour.available!==contour.total)throw Error('Presentation oracle did not cover every fixture element: '+contour.available+'/'+contour.total);
   if(estimated){contour.estimated=true;contour.note='Synthetic passing RF estimate for rendering invalidation only; no numerical calculation.';report.incremental={evaluatedRows:passingPids.length,reusedRows:rows.length-passingPids.length};}
   state.modelDirty=false;displayReserveFactorContour(request,contour,{refresh:!!state.rfField});state.scene.render();
  },{rows,only,estimated,passingPids});
 }
 async function noFrames(label){const value=await snapshot();assert.equal(value.sourceCount,0,label);assert.equal(value.proxyCount,0,label+' screen-width proxies');assert.equal(value.groupCount,0,label+' group cache');frames[label]=value;}
 async function screenshot(name){await page.evaluate(()=>state.scene.render());await page.screenshot({path:path.join(out,name+'.png'),scale:'css'});}
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.buildingScene);
  await page.evaluate(()=>{state.engine.stopRenderLoop();document.getElementById('auto-mesh').checked=false;state.autoMeshEnabled=false;cancelAutoMeshTimer();state.scene.clearColor=new BABYLON.Color4(1,1,1,1);state.camera.alpha=-Math.PI/2;state.camera.beta=.35;fitView();state.scene.render();});const identity=await page.evaluate(()=>state.meshIdentity),initialTopology=await topology();await noFrames('ordinary-view');checks.push('Ordinary structural rendering has no compression-group outline sources or screen-width proxies.');
  await draw();const all=await assertFrame('all-groups');assert.equal(all.groupCount,payload.stiffened_panels.panels.length);assert(all.shared.length>0);assert(all.internalOnly.length>0);assert(all.expected.some(g=>g.elementIds.length>1));await screenshot('rf-all-compression-groups');checks.push('Actual authored element-group perimeters retain shared borders, cancel ordinary internal FE edges and deduplicate their rendered segments. Dark-blue 3.5 CSS-pixel strokes are non-pickable.');
  const hiddenName=await page.evaluate(()=>{const p=state.data.stiffened_panels.panels[0],e=state.elements.get(p.shell_eids[0]);window.__hiddenPanelLayer=e.group.name;setLayerVisible(e.group.name,false);return e.group.name;});const hidden=await assertFrame('hidden-layer');assert(hidden.groupCount<all.groupCount);await page.evaluate(name=>setLayerVisible(name,true),hiddenName);await assertFrame('restored-layer');checks.push('Entity-layer visibility removes the corresponding group frames and restoring the layer redraws them.');
  await draw({only:true});const failing=await assertFrame('rf-below-one');assert(failing.groupCount>0&&failing.groupCount<all.groupCount);assert(failing.mask?.length);await screenshot('rf-failing-groups-only');const target=await page.evaluate(()=>{const p=state.data.stiffened_panels.panels.find(p=>p.shell_eids?.length&&p.shell_eids.every(eid=>state.rfField.contour.failingElementIds.has(eid)));if(!p)throw Error('No complete failing group in observed native RFs');return{key:p.key,pids:[p.shell_pid,p.stringer_pid]};});checks.push('RF < 1 filtering outlines the remaining failing group context, including a failing stringer with passing skin; fully passing and hidden groups leave no ghost perimeters.');
  await draw({only:true,estimated:true,passingPids:target.pids});const estimated=await assertFrame('passing-local-estimate');assert(!estimated.groups.some(g=>g.key===target.key));assert(estimated.groupCount<failing.groupCount);await screenshot('resized-group-hidden');checks.push('A presentation-only passing estimate uses the local sizing refresh branch; its former failing group and outline disappear together without regenerating the FEM.');
  await page.setViewportSize({width:1100,height:800});await page.evaluate(()=>{state.engine.resize();state.scene.render();});await assertFrame('resized-viewport');checks.push('A viewport resize at device scale 2 preserves authored boundary positions and the 3.5 CSS-pixel stroke width.');
  assert.equal(await topology(),initialTopology,'Outlines must leave every original GRID ID/coordinate and FE property/connectivity buffer unchanged');await page.evaluate(()=>{window.__oldBoundarySources=state.scene.meshes.filter(m=>m.metadata?.rfPanelOutline);clearReserveFactorField();state.scene.render();});await noFrames('cleared-field');assert(await page.evaluate(()=>__oldBoundarySources.every(m=>m.isDisposed())));checks.push('Clear RF disposes every boundary source and its expanded screen-width proxy; all original FE buffers remain unchanged.');
  await draw();await page.evaluate(()=>beginAnalysisResults('Boundary lifecycle probe',{source:'jfem'}));await noFrames('new-analysis');await draw();await page.evaluate(()=>loadModelDefinition({name:'New Study'},{newStudy:true,identification:{text:'',visible:false}}));await noFrames('new-study');checks.push('Starting an analysis and loading a new Study clear all group helpers; none survive model disposal.');
  assert.equal(all.meshIdentity,identity);assert.equal(failing.meshIdentity,identity);assert.equal(estimated.meshIdentity,identity);assert(!requests.some(p=>/rf_assessment|rf_sections|run_jfem|jfem_run|jfem_start|sensitivity\/run/.test(p)));assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,actualAuthoredFEM:true,actualObservedNativeRFs:true,syntheticEstimate:'One passing RF value is a rendering-only oracle; no numerical sizing or FE solve is claimed.',sourceGroupScope:'Editable shell element-group footprint; not fractional effective column widths.',nativeOrFESolveRequested:false,frames,requests,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,requests,errors,frame:await snapshot().catch(()=>null)},null,2));await screenshot('failure').catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
