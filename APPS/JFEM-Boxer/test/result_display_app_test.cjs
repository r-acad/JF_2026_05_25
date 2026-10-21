/* Replay a generated geometry fixture with explicitly synthetic stress/mode fields.
 * node test/result_display_app_test.cjs <output-dir> <fixture-dir> [playwright-module]
 * Fixture: schema.json, payload.msgpack, optional params.json. CHROME_PATH is optional.
 */
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(process.argv.length<4||process.argv.length>5)throw Error('Usage: node result_display_app_test.cjs <output-dir> <fixture-dir> [playwright-module]');
const out=path.resolve(process.argv[2]),fixture=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||process.env.WING_PLAYWRIGHT_MODULE||'playwright');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults??=fs.existsSync(path.join(fixture,'params.json'))?JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8')):schema.values;
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1540,height:1080}}),page=await context.newPage(),errors=[],checks=[];
try{
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));page.on('pageerror',e=>errors.push(e.message));
 await context.route('http://127.0.0.1:43964/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/shared/jfem_graphics.js')return route.fulfill({path:path.resolve(web,'../../jfem_graphics.js')});
  if(p==='/api/input')return route.fulfill({json:schema});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated result display fixture'}});
  return route.fulfill({path:path.join(web,p==='/'?'index.html':decodeURIComponent(p))});
 });
 await page.goto('http://127.0.0.1:43964/');await page.locator('.startup-study-dialog [data-choice="new"]').click();
 await page.waitForFunction(()=>typeof state!=='undefined'&&state.data&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
 const metadata=await page.evaluate(()=>{
  state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();
  const shell=[...state.elements.values()].find(e=>e.group.kind==='quad'||e.group.kind==='tria'),bar=[...state.elements.values()].find(e=>e.group.kind==='bar'),spider=[...state.elements.values()].find(e=>e.group.kind==='rbe3');
  if(!shell||!bar||!spider)throw Error('Fixture requires shells, bars and RBE3');
  window.testEids={shell:shell.id,bar:bar.id};window.testPeakIndices=[shell.nodes[0],spider.nodes[0]];
  window.generatedState={signature:state.modelSignature,values:{...state.values},case:state.activeCase};
  const n=state.nodeIds.length,f32=a=>new Uint8Array(new Float32Array(a).buffer),i32=a=>new Uint8Array(new Int32Array(a).buffer),shape=new Float32Array(n*3);shape[testPeakIndices[0]*3]=5;shape[testPeakIndices[1]*3+2]=-5;
  window.testRaw={analysis_type:'SOL105',node_count:n,mode_kind:'buckling',source:'jfem',model_params:{...state.values},load_application_version:state.data.loads?.load_application_version,
   static:{disp:f32(new Float32Array(n*3)),max_disp:0},modes:[{mode:1,load_factor:3,eigenvalue:3,max_disp:5,shape:f32(shape)}],summary:[['Max von Mises','2e9 Pa'],['Bar axial range','-1e9 to 3e9 Pa']],
   contours:[{name:'Von Mises stress',unit:'Pa',min:1e9,max:2e9,domain:'shell',location:'element',ids:i32([shell.id]),values:f32([2e9])},{name:'Major principal stress (z1)',unit:'Pa',min:-1e9,max:3e9,domain:'shell',location:'element',ids:i32([shell.id]),values:f32([3e9])},{name:'Bar axial stress',unit:'Pa',min:-1e9,max:3e9,domain:'bar',location:'element',ids:i32([bar.id]),values:f32([2e9])}],
   element_results:{[shell.id]:{stress_units:'Pa; fiber_dist in m',stress:{z1:{normal_x:2e9,normal_y:-1e9,shear_xy:.5e9,major:3e9,minor:-2e9,von_mises:4e9,fiber_dist:-.005}},forces:{fx:1234}},[bar.id]:{stress_units:'Pa; end_a/end_b are bending stresses',stress:{axial:2e9,end_a:{p1:-4e9,p8:5e9}},forces:{axial:5678}}}};
  window.installResult=(source='jfem',imported=false)=>{
   const raw={...testRaw,source,model_params:{...generatedState.values}};
   if(imported){state.importedDeck={name:'synthetic-source.bdf',solution:'105',signature:'synthetic-imported',cases:[{id:7,label:'Source preload',result_required:true}],source:{analysis:{solution:'source'}}};state.activeCase=7;state.modelSignature='synthetic-imported';raw.imported_signature='synthetic-imported';}
   else{state.importedDeck=null;state.activeCase=generatedState.case;state.modelSignature=generatedState.signature;}
   state.results=decodeResultCase(raw,raw,state.modelSignature);state.results.modelParams={...generatedState.values,'loads.load_factor':2};state.results.variantId='sol105';state.resultCases=new Map([[state.activeCase,state.results]]);showResults();activateWorkspaceTab('results');document.getElementById('animate').checked=false;applyDeformation();return state.results.matches;
  };
  window.choose=name=>{state.contourIdx=contourOptions().findIndex(c=>c.name===name);document.getElementById('contour-select').value=String(state.contourIdx);applyContour();};
  installResult();return{nodes:state.nodeIds.length,shell:shell.id,bar:bar.id,peaks:testPeakIndices.map(i=>state.nodeIds[i])};
 });
 for(const source of ['jfem','sensitivity_baseline']){
  assert(await page.evaluate(source=>installResult(source),source));const row=await page.locator('#mode-0').innerText(),title=await page.locator('#mode-0').getAttribute('title');
  assert.match(row,/6 × base case preload/);assert.match(title,/λ = 3; case load multiplier = 2/);assert.match(title,/inertial loads/);
  for(const id of metadata.peaks)assert(row.includes('GRID '+id));assert.match(row,/PID/);assert.match(row,/no incident property/);
  assert(await page.evaluate(()=>state.results.source==='jfem'||state.results.source==='sensitivity_baseline'));
  checks.push(source+': solved λ/load multiplier and tied physical GRID/property provenance');
 }
 await page.evaluate(()=>{choose('Von Mises stress');window.beforeColors=Array.from(state.shellMeshes.flatMap(mesh=>Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind))));markStudySaved();});assert.match(await page.locator('#viewport-legends').innerText(),/MPa/);assert.match(await page.locator('#results-summary').innerText(),/2000 MPa/);
 const legend=page.locator('#viewport-legends [data-scale="fe"]');await legend.locator('[data-legend-action="limits"]').click();
 assert.equal(await legend.locator('[name="minimum"]').inputValue(),'1000');assert.equal(await legend.locator('[name="maximum"]').inputValue(),'2000');
 await legend.locator('[name="minimum"]').fill('500');await legend.locator('[name="maximum"]').fill('2500');await legend.locator('.legend-limits-apply').click();
 assert(await page.evaluate(()=>{const r=WingLegends.getLimits(contourValues().limitKey);return Math.abs(r[0]-.5e9)<1e-6&&Math.abs(r[1]-2.5e9)<1e-6;}));
 await legend.locator('[data-legend-action="limits"]').click();const slider=legend.locator('[data-limit-slider="minimum"]');
 await slider.focus();await page.keyboard.press('ArrowRight');assert.equal(await slider.evaluate(el=>el===document.activeElement),true);
 const box=await slider.boundingBox();await page.mouse.move(box.x+5,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width*.35,box.y+box.height/2,{steps:7});await page.mouse.move(box.x+box.width*.6,box.y+box.height/2,{steps:7});await page.mouse.up();
 const colorProof=await page.evaluate(()=>{const c=contourValues(),colors=state.shellMeshes.flatMap(mesh=>Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind)));for(const mesh of state.shellMeshes){const values=mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind);mesh.elementIds.forEach((eid,i)=>{const expected=contourRGB(c,c.byId.get(eid));for(let k=0;k<3;k++)if(Math.abs(values[i*mesh.nodesPerElement*4+k]-expected[k])>1e-6)throw Error('Canonical stress color mismatch at EID '+eid);});}return{changed:colors.some((v,i)=>v!==beforeColors[i]),dirty:state.studyDirty};});assert(colorProof.changed,JSON.stringify(colorProof));
 const manual=await page.evaluate(()=>WingLegends.getLimits(contourValues().limitKey));assert(manual[0]>1e9&&manual[0]<2e9);assert.equal(manual[1],2.5e9);await page.screenshot({path:path.join(out,'stress-range-sliders.png')});
 await legend.locator('[data-limit-slider="maximum"]').focus();await page.keyboard.press('Home');const ordered=await page.evaluate(()=>WingLegends.getLimits(contourValues().limitKey));assert(ordered[0]<ordered[1]);
 await page.keyboard.press('Escape');const saved=await page.evaluate(()=>WingLegends.capture());
 await page.evaluate(()=>{choose('Major principal stress (z1)');});assert.equal(await page.evaluate(()=>contourValues().manual),false);assert.match(await legend.innerText(),/MPa/);
 await page.evaluate(saved=>{WingLegends.restore(null);WingLegends.restore(saved);choose('Von Mises stress');},saved);assert.deepEqual(await page.evaluate(()=>WingLegends.getLimits(contourValues().limitKey)),ordered);
 assert.equal(await page.evaluate(()=>state.results.contours[0].values[0]),2e9);checks.push('MPa fields and continuous pointer/keyboard sliders update colors; ordered manual limits persist canonically per result without mutating data');
 const svgUnits=await page.evaluate(async()=>{const original=WingViewportSVG.exportScene,download=WingWorkspace.downloadText;let captured;try{WingViewportSVG.exportScene=async(_s,_c,_e,options)=>{captured=options.legends;return{text:'<svg/>',stats:{}};};WingWorkspace.downloadText=()=>{};await saveViewportSVG();}finally{WingViewportSVG.exportScene=original;WingWorkspace.downloadText=download;}return captured;});assert.equal(svgUnits[0].units,'MPa');assert(Math.abs(svgUnits[0].min-ordered[0]*1e-6)<1e-12);
 for(const type of ['shell','bar']){
  await page.evaluate(type=>{choose(type==='shell'?'Major principal stress (z1)':'Bar axial stress');showElement(testEids[type]);},type);
  const picked=await page.locator('#pick-content').innerText(),rows=await page.locator('#pick-content tr').evaluateAll(rows=>rows.map(row=>[...row.cells].map(cell=>cell.textContent)));
  assert.match(picked,/stress: MPa/);assert(rows.some(([k,v])=>k==='stress units'&&v.startsWith('MPa')));
  assert(rows.some(([k,v])=>k===(type==='shell'?'normal x':'axial')&&v==='2000'));
  assert(rows.some(([k,v])=>k===(type==='shell'?'fiber dist':'p8')&&v===(type==='shell'?'-0.005':'5000')));
  assert(rows.some(([k,v])=>k===(type==='shell'?'fx':'axial')&&v===(type==='shell'?'1234':'5678')));
 }
 checks.push('Shell components/principals and beam end stresses use MPa; force and fiber-distance fields remain canonical');
 await page.evaluate(()=>{choose('Von Mises stress');document.getElementById('pick-card').hidden=true;state.scene.render();});await page.screenshot({path:path.join(out,'stress-mpa-and-buckling.png')});
 assert(await page.evaluate(()=>installResult('sensitivity_baseline',true)));assert.match(await page.locator('#mode-0').innerText(),/3 × source deck preload/);assert.match(await page.locator('#mode-0').getAttribute('title'),/source deck for this subcase/);checks.push('Imported-source sensitivity baseline uses source deck preload with no generated load multiplier');
 await page.evaluate(()=>installResult());
 const scopes=await page.evaluate(()=>{
  const host=document.createElement('div');host.id='shared-range-test';host.style='position:fixed;left:450px;top:90px;z-index:9999;width:300px';document.body.append(host);
  window.scopeFixture=['fe','sensitivity','properties','vlm'].map((kind,i)=>({kind,limitKey:'slider-fixture:'+kind,title:kind,unit:kind==='vlm'?'Pa':'dimensionless',min:-100,max:100,paletteKey:kind}));
  WingLegends.render(host,scopeFixture);return scopeFixture.map(e=>e.kind);
 });
 for(const scope of scopes){const box=page.locator('#shared-range-test [data-scale="'+scope+'"]');await box.locator('[data-legend-action="limits"]').click();await box.locator('[data-limit-slider="minimum"]').focus();await page.keyboard.press('ArrowRight');await page.keyboard.press('Escape');assert(await page.evaluate(scope=>{const r=WingLegends.getLimits('slider-fixture:'+scope);return Math.abs(r[0]+99.8)<1e-10&&r[1]===100;},scope));}
 checks.push('Shared min/max sliders cover FE, sensitivity, properties and VLM with independent keys');
 await page.evaluate(()=>document.getElementById('shared-range-test').remove());
 const propertyPalette=await page.evaluate(()=>{const saved=WingLegends.capture();WingLegends.restore(null);state.propertyDisplay.restore({enabled:true,field:'shell_thickness',materialRole:'single'});applyContour();const initial=WingLegends.getPalette(contourPaletteKey(contourValues()));WingLegends.setPalette('properties','inferno');state.propertyDisplay.restore({enabled:true,field:'beam_area',materialRole:'single'});applyContour();state.propertyDisplay.restore({enabled:true,field:'shell_thickness',materialRole:'single'});applyContour();const explicit=WingLegends.getPalette('properties');state.propertyDisplay.setEnabled(false);WingLegends.restore(saved);applyContour();return{initial,explicit};});assert.deepEqual(propertyPalette,{initial:'spectrum',explicit:'inferno'});checks.push('Shell thickness starts with the blue/green/red spectrum while an explicit property palette survives field changes.');
 await page.evaluate(()=>{
  window.syntheticSensitivity={case_id:state.activeCase,case_label:'Synthetic stress response',solution:'101',baseline:{value:2e9,unit:'Pa'},objective:{type:'shell_stress',element_id:testEids.shell,component:'major',surface:'z1'},method:'analytic_discrete_adjoint',rows:[{id:'properties.t_skin_upper',label:'Upper thickness',value:.002,unit:'m',derivative:-3e9,derivative_unit:'Pa / m',normalized_derivative:-.003,status:'ok'}]};
  acceptSensitivityResult(syntheticSensitivity,state.modelSignature,{job:'synthetic-stress'});state.sensitivity.complete(syntheticSensitivity,state.modelSignature,state.sensitivityMeta);activateWorkspaceTab('sensitivity');
 });
 assert.match(await page.locator('#sensitivity-results').innerText(),/Baseline: 2000 MPa/);assert.match(await page.locator('#sensitivity-results').innerText(),/-3000 MPa \/ m/);
 const downloadPromise=page.waitForEvent('download');await page.locator('#sensitivity-csv').click();const download=await downloadPromise;await download.saveAs(path.join(out,'stress-sensitivity.csv'));const csv=fs.readFileSync(path.join(out,'stress-sensitivity.csv'),'utf8');assert(csv.includes('"-3000000000"'));assert(csv.includes('"Pa / m"'));
 const popupPromise=context.waitForEvent('page');await page.locator('#btn-sensitivity-data-table').click();const table=await popupPromise;await table.waitForSelector('.sensitivity-value');await table.locator('#table-mode').selectOption('all');
 assert.match(await table.locator('#baseline').innerText(),/2000 MPa/);assert.equal(await table.locator('.sensitivity-value').innerText(),'-3000');assert.match(await table.locator('.table-color-scale').innerText(),/MPa \/ m/);await table.screenshot({path:path.join(out,'stress-sensitivity-table.png')});
 checks.push('Sensitivity response, derivative, detached table and scales use MPa; CSV retains full-precision Pa');
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,metadata,errors},null,2));console.log('Result display browser: '+checks.length+' groups passed');
}catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
