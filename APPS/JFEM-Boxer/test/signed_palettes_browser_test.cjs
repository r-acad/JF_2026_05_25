'use strict';
// Actual app UI with generated geometry and explicitly synthetic signed fields.
// node signed_palettes_browser_test.cjs <evidence> <fixture> <playwright> [chrome]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [output,fixtureArg,playwright,chrome]=process.argv.slice(2);if(!output||!fixtureArg||!playwright)throw Error('Pass evidence, fixture (schema/params/payload), playwright module, and optional browser path');
const out=path.resolve(output),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(playwright));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json')));schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json')));
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(chrome?{executablePath:chrome}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1540,height:1080}}),checks=[],errors=[];
try{
 page.on('pageerror',e=>errors.push(e.message));await page.route('http://127.0.0.1:43983/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:schema});
  if(['/api/generate','/api/prepare_workspace'].includes(p))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p.startsWith('/api/'))return route.fulfill({json:{ok:true,events:[]}});
  return route.fulfill({path:path.join(web,p==='/'?'index.html':p)});
 });
 await page.goto('http://127.0.0.1:43983/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>typeof state!=='undefined'&&state.data&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
 await page.evaluate(()=>{
  state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();
  const ids=state.shellMeshes.flatMap(m=>Array.from(m.elementIds)).slice(0,3),f32=a=>new Uint8Array(new Float32Array(a).buffer),i32=a=>new Uint8Array(new Int32Array(a).buffer);
  const raw={analysis_type:'SOL101',node_count:state.nodeIds.length,mode_kind:'none',source:'jfem',model_params:{...state.values},load_application_version:state.data.loads?.load_application_version,
   static:{disp:f32(new Float32Array(state.nodeIds.length*3)),max_disp:0},modes:[],summary:[],contours:[{name:'Synthetic signed field',unit:'dimensionless',min:-2,max:8,domain:'shell',location:'element',ids:i32(ids),values:f32([-2,0,8])}]};
  state.results=decodeResultCase(raw,raw,state.modelSignature);state.resultCases=new Map([[state.activeCase,state.results]]);showResults();activateWorkspaceTab('results');
  state.contourIdx=contourOptions().findIndex(c=>c.name==='Synthetic signed field');document.getElementById('contour-select').value=String(state.contourIdx);applyContour();
 });
 await page.locator('#result-palette').selectOption('signed');
 assert.match(await page.locator('#viewport-legends .viewport-scale-ramp').getAttribute('style'),/20%/);
 const colors=await page.evaluate(()=>{const c=contourValues(),out=[];for(const mesh of state.shellMeshes){const rgba=mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind);mesh.elementIds.forEach((eid,i)=>{if(c.byId.has(eid))out.push({value:c.byId.get(eid),rgb:Array.from(rgba.slice(i*mesh.nodesPerElement*4,i*mesh.nodesPerElement*4+3)),expected:contourRGB(c,c.byId.get(eid))});});}return out;});
 assert.equal(colors.length,3);for(const c of colors)for(let i=0;i<3;i++)assert(Math.abs(c.rgb[i]-c.expected[i])<1e-6);
 assert(colors.find(c=>c.value<0).rgb[0]>colors.find(c=>c.value<0).rgb[2]);assert(colors.find(c=>c.value>0).rgb[2]>colors.find(c=>c.value>0).rgb[0]);
 checks.push('Actual FE vertex buffers use red negatives, neutral zero, blue positives; asymmetric legend zero is at 20%');
 const legend=page.locator('#viewport-legends [data-scale="fe"]');await legend.locator('[data-legend-action="palette"]').click();
 assert.match(await legend.locator('[data-palette-value="signed"] .legend-palette-swatch').getAttribute('style'),/20%/);await page.screenshot({path:path.join(out,'signed-fe-palette.png')});await page.keyboard.press('Escape');
 const exported=await page.evaluate(async()=>{const exportScene=WingViewportSVG.exportScene,download=WingWorkspace.downloadText;let captured;try{WingViewportSVG.exportScene=async(_s,_c,_e,options)=>{captured=options.legends;return{text:'<svg/>',stats:{}};};WingWorkspace.downloadText=()=>{};await saveViewportSVG();}finally{WingViewportSVG.exportScene=exportScene;WingWorkspace.downloadText=download;}return captured[0];});
 assert.deepEqual(exported.stops,[{offset:0,color:'#c33442'},{offset:.2,color:'#f2f3ef'},{offset:1,color:'#3070c4'}]);checks.push('Palette preview and SVG export retain the true zero stop and identical endpoint colours');
 // The common legend renderer is shared by every physical field scope.
 for(const scope of ['vlm','sensitivity','properties','aero-curvature']){
  await page.evaluate(scope=>{WingLegends.render(document.getElementById('viewport-legends'),[{kind:scope,paletteKey:scope,title:'Test '+scope,min:-8,max:2,gradient:contourGradient(-8,2,scope)}]);},scope);
  const scale=page.locator('#viewport-legends [data-scale="'+scope+'"]');await scale.locator('[data-legend-action="palette"]').click();
  const choice=scale.locator('[data-palette-value="signed"]');assert.match(await choice.locator('.legend-palette-swatch').getAttribute('style'),/80%/);await choice.click();
  assert.equal(await page.evaluate(scope=>WingLegends.getPalette(scope),scope),'signed');
 }
 checks.push('VLM, sensitivity, property and curvature legends all offer the signed palette and numeric range previews');
 const saved=await page.evaluate(()=>WingLegends.capture());await page.evaluate(saved=>{WingLegends.restore(null);WingLegends.restore(saved);},saved);assert.deepEqual(await page.evaluate(()=>WingLegends.capture()),saved);
 const oneSided=await page.evaluate(()=>{const scopes=['fe','vlm','sensitivity','properties','aero-curvature'];return scopes.flatMap(scope=>[[1,8],[-8,-1],[3,3],[-3,-3]].map(([min,max])=>({scope,min,max,rgb:fieldColor(min,min,max,scope),gradient:contourGradient(min,max,scope)})));});
 for(const c of oneSided)assert(c.min>0?c.rgb[2]>c.rgb[0]:c.rgb[0]>c.rgb[2]);checks.push('Independent saved palettes and one-sided/constant hues agree across every viewport field scope');
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,colors,exported,errors},null,2));console.log('Signed palette browser: '+checks.length+' groups passed');
}catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
