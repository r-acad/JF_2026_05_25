'use strict';
// Actual Boxer UI with generated geometry and explicitly synthetic solver jobs.
// node analysis_result_lifecycle_app_test.cjs FIXTURE_DIR OUTPUT_DIR PLAYWRIGHT_MODULE
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const [fixtureArg, outputArg, playwrightPath = 'playwright'] = process.argv.slice(2);
const fixture = path.resolve(fixtureArg), output = path.resolve(outputArg);
const web = path.resolve(__dirname, '../web'), origin = 'http://127.0.0.1:43981';
const {chromium} = require(playwrightPath), MessagePack = require(path.join(web, 'vendor/msgpack.min.js'));
const schema = JSON.parse(fs.readFileSync(path.join(fixture, 'schema.json'), 'utf8'));
schema.defaults ??= schema.values;
const geometry = MessagePack.decode(fs.readFileSync(path.join(fixture, 'payload.msgpack')));
let currentParams = structuredClone(schema.values), releaseFeStart, releaseAeroStart;
let rfOperation = 'jacobian', rfParameters, generated = 0;
const response = {id:'material:fixture', response_id:'material:fixture', label:'Fixture upper skin', case_id:1,
  failure_mode:'von_mises', status:'ok', raw_RF:2, utilization:.5};
const variable = {id:'skin_t', label:'Upper skin thickness', path:['properties.t_skin_upper'], field_key:'shell.thickness',
  unit:'m', value:Number(schema.values['properties.t_skin_upper']), lower_bound:.0005, upper_bound:.01};
function modelPayload(parameters) {
  currentParams = structuredClone(parameters); generated++;
  const data = structuredClone(geometry);
  data.model_params = currentParams;
  for (const group of data.groups) if (group.name.startsWith('UPPER_SKIN') && group.properties)
    group.properties.thickness_m = currentParams['properties.t_skin_upper'];
  return Buffer.from(MessagePack.encode(data));
}
function resultPayload() {
  const count = geometry.nodes.count;
  return Buffer.from(MessagePack.encode({analysis_type:'SOL101', node_count:count, model_params:currentParams,
    load_application_version:geometry.loads?.load_application_version, report_md:'CURRENT ANALYSIS RESULT',
    static:{disp:new Uint8Array(new Float32Array(count * 3).fill(.0001).buffer), max_disp:.0001},
    modes:[], contours:[], element_results:{}}));
}
const aeroResult = {signature:'lifecycle-aero', mesh_only:true, limitations:'Synthetic visualization fixture', cases:[{
  id:1, panel_count:1, min_panel_aspect_ratio:1, max_panel_aspect_ratio:1, area_m2:1, span_m:2, mac_m:1,
  reference:[.25,0,0], condition:{alpha:3,beta:0}, panels:[{id:1, side:'right', eta:.5, chord_fraction:.5,
    area_m2:1, position:[.5,.5,0], corners:[[0,0,0],[1,0,0],[1,1,0],[0,1,0]], force_N:[0,0,10], delta_cp:1, delta_pressure_Pa:10}],
  bounds:{min:[0,0,0],max:[1,1,0]}}]};
(async()=>{
  fs.mkdirSync(output,{recursive:true});
  const browser = await chromium.launch({headless:true, executablePath:process.env.CHROME_PATH || undefined,
    args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  const page = await browser.newPage({viewport:{width:1650,height:1100}}), errors=[], requests=[], checks=[];
  page.setDefaultTimeout(60000);page.on('pageerror',error=>errors.push(error.stack));
  try {
    await page.route(origin+'/**',async route=>{
      const url = new URL(route.request().url()), body = route.request().method()==='POST' ? route.request().postDataJSON() : null;
      if(url.pathname.startsWith('/api/'))requests.push(url.pathname);
      if(url.pathname==='/api/input')return route.fulfill({json:{...schema,ok:true}});
      if(['/api/validate_workspace','/api/restore_workspace'].includes(url.pathname))return route.fulfill({json:{ok:true,parameters:body}});
      if(['/api/generate','/api/prepare_workspace'].includes(url.pathname))return route.fulfill({body:modelPayload(body),contentType:'application/msgpack'});
      if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
      if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
      if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true,repo:'fixture'}});
      if(url.pathname==='/api/run_jfem') {
        await new Promise(resolve=>{releaseFeStart=resolve;});
        return route.fulfill({json:{job:'current-fe',deck:'fixture.bdf',deck_lines:20,solution:'SOL101',repo:'fixture',command:'synthetic FE job'}});
      }
      if(url.pathname==='/api/jfem_status')return route.fulfill({json:{state:'done',seconds:1,next_line:0,total_lines:0,log_done:true,lines:[],results_available:true}});
      if(url.pathname==='/api/jfem_results')return route.fulfill({body:resultPayload(),contentType:'application/msgpack'});
      if(url.pathname==='/api/rf_sensitivity/catalog')return route.fulfill({json:{ok:true,catalog:{responses:[response],variables:[variable]}}});
      if(url.pathname==='/api/rf_sensitivity/start'){rfOperation=body.operation;rfParameters=body.params;return route.fulfill({json:{ok:true,id:'rf-fixture',state:'running'}});}
      if(url.pathname==='/api/rf_sensitivity/status')return route.fulfill({json:{ok:true,state:'done',message:'Fixture complete'}});
      if(url.pathname==='/api/rf_sensitivity/result')return route.fulfill({json:{ok:true,id:'rf-fixture',result:{operation:rfOperation,quantity:'utilization',
        responses:[response],variables:[variable],complete:true,...(rfOperation==='optimize'?{
          optimized_params:{...rfParameters,'properties.t_skin_upper':.003123456789},design:[.003123456789],
          dimension_updates:[{...variable,initial_value:variable.value,optimized_value:.003123456789}],
          history:[{iteration:1,mass:9,maximum_utilization:.8,constraint_violation:0}],mass:9,
          final_verification:{complete:true,feasible:true,independent_forward_solve:true},converged:true
        }:{jacobian:[[-100]]})}}});
      if(url.pathname==='/api/aerodynamics/mesh')return route.fulfill({json:{id:'aero-old'}});
      if(url.pathname==='/api/aerodynamics/run'){await new Promise(resolve=>{releaseAeroStart=resolve;});return route.fulfill({json:{id:'aero-next'}});}
      if(url.pathname==='/api/aerodynamics/status')return route.fulfill({json:{state:'done',seconds:1,message:'Fixture ready'}});
      if(url.pathname==='/api/aerodynamics/results')return route.fulfill({json:aeroResult});
      if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Synthetic UI fixture'}});
      const file = url.pathname.startsWith('/shared/') ? path.join(web,'../..',url.pathname.slice(8)) : path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
      return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
    });
    await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();
    await page.waitForFunction(()=>state.autoMeshReady && !state.workspaceBusy);
    if(!await page.evaluate(()=>!!state.data))await page.locator('#btn-create').click();
    await page.waitForFunction(()=>state.data && !state.meshRequestInFlight);
    await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('stressreport');});
    assert.equal(await page.locator('#stress-report-failure-mode').inputValue(),'minimum_rf');
    assert.equal(await page.locator('#stress-report-field-kind').inputValue(),'minimum_rf');
    checks.push('Assessment and 3D field start at Minimum RF.');
    await page.evaluate(()=>{
      const n=state.nodeIds.length,raw={analysis_type:'SOL101',node_count:n,model_params:collectParams(),load_application_version:state.data.loads?.load_application_version,
        static:{disp:new Uint8Array(new Float32Array(n*3).fill(.01).buffer),max_disp:.01},modes:[],contours:[],element_results:{},report_md:'OLD ANALYSIS RESULT'};
      state.results=decodeResultCase(raw,raw,state.modelSignature);state.resultCases=new Map([[1,state.results]]);showResults();
      state.sensitivityResult={rows:[{id:'old-variable',derivative:42}]};refreshSensitivityMapCard();
    });
    assert.equal(await page.locator('#results-card').evaluate(node=>node.hidden),false);
    await page.evaluate(()=>void runJfem());await page.waitForFunction(()=>state.solverStarting && state.results===null);
    assert.equal(await page.locator('#results-card').isHidden(),true);
    assert.equal(await page.evaluate(()=>state.resultCases),null);
    assert.equal(await page.evaluate(()=>state.sensitivityResult),null);
    assert.equal(await page.evaluate(()=>state.stressReport.report),null);
    assert(!await page.locator('#report-text').textContent());
    while(!releaseFeStart)await page.waitForTimeout(20);releaseFeStart();
    await page.waitForFunction(()=>!state.polling && !state.solverStarting && state.results?.report==='CURRENT ANALYSIS RESULT');
    assert(!await page.locator('#report-text').textContent().then(text=>text.includes('OLD ANALYSIS RESULT')));
    checks.push('Starting the actual FE command immediately clears old FE/scalar/RF results, and publishes only the new job result.');

    await page.evaluate(()=>{activateWorkspaceTab('aerostudy');void state.aerodynamicStudy.run(true);});
    await page.waitForFunction(()=>state.aerodynamicStudy.result?.mesh_only && !state.aerodynamicStudy.busy);
    assert(await page.evaluate(()=>BABYLON.Engine.Instances.flatMap(e=>e.scenes).some(s=>s.getMeshByName('independent-aero-panels'))));
    await page.evaluate(()=>void state.aerodynamicStudy.run(false));
    await page.waitForFunction(()=>state.aerodynamicStudy.busy && state.aerodynamicStudy.result===null);
    assert(!await page.evaluate(()=>BABYLON.Engine.Instances.flatMap(e=>e.scenes).some(s=>s.getMeshByName('independent-aero-panels'))));
    assert.equal(await page.locator('.aero-summary').textContent(),'');
    await page.evaluate(()=>state.aerodynamicStudy.clearResults());
    while(!releaseAeroStart)await page.waitForTimeout(20);releaseAeroStart();
    await page.waitForTimeout(150);assert.equal(await page.evaluate(()=>state.aerodynamicStudy.result),null);
    checks.push('New aerodynamic analysis clears prior meshes, fields and tables; a superseded start cannot restore them.');

    await page.evaluate(()=>{
      activateWorkspaceTab('stressreport');state.propertyDisplay.restore({enabled:true,field:'pid',materialRole:'single'});
      state.camera.alpha=.7;state.camera.beta=1.1;state.camera.radius=4;state.camera.setTarget(new BABYLON.Vector3(.1,.2,.3));
      WingViewportTools.stopMotion(state.camera);
    });
    const camera=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()}));
    await page.locator('#rf-sensitivity>summary').click();await page.getByRole('button',{name:'Read RFs and design variables',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('.rf-sensitivity-status').textContent.includes('Catalog ready'));
    await page.getByRole('button',{name:'Select matching RFs',exact:true}).click();await page.getByRole('button',{name:'Select matching variables',exact:true}).click();
    await page.getByText('Operation',{exact:true}).locator('..').locator('select').selectOption('optimize');
    await page.getByRole('button',{name:'Run minimum-mass sizing',exact:true}).click();
    await page.waitForFunction(()=>state.rfSensitivity?.result?.operation==='optimize' && !state.meshRequestInFlight && !state.modelDirty && state.propertyDisplay?.enabled);
    const colored=await page.evaluate(()=>{
      const contour=state.propertyDisplay.contour(),entry=[...state.elements.values()].find(e=>e.group.name.startsWith('UPPER_SKIN'));
      const mesh=state.shellMeshes.find(m=>m.elementIds.includes(entry.id)),index=mesh.elementIds.indexOf(entry.id);
      const actual=Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind).slice(index*mesh.nodesPerElement*4,index*mesh.nodesPerElement*4+3));
      return{value:collectParams()['properties.t_skin_upper'],field:contour.field,colorValue:contour.byId.get(entry.id),actual,expected:contourRGB(contour,contour.byId.get(entry.id)),
        mass:state.rfSensitivity.result.mass,camera:{alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()}};
    });
    assert.equal(colored.value,.003123456789);assert.equal(colored.field,'shell_thickness');assert.equal(colored.colorValue,.003123456789*1000);
    assert.equal(await page.evaluate(()=>state.rfSensitivity.catalog.variables[0].value),.003123456789);
    colored.actual.forEach((value,index)=>assert(Math.abs(value-colored.expected[index])<1e-6));assert.deepEqual(colored.camera,camera);
    assert.match(await page.locator('#viewport-legends').innerText(),/Total thickness/);assert.equal(colored.mass,9);
    checks.push('Completed sizing applies exact dimensions, regenerates updated thickness metadata and actual vertex colors, preserves the camera and keeps sizing history.');
    await page.evaluate(()=>state.scene.render());
    await page.screenshot({path:path.join(output,'optimized-property-colors.png')});
    const retry=await page.evaluate(async()=>{
      const original=createFEM,result={variables:[{id:'skin_t',path:['properties.t_skin_upper'],label:'Upper skin thickness',field_key:'shell.thickness'}]};
      const attempt=async(edit)=>{
        const params={...collectParams(),'properties.t_skin_upper':.004};
        createFEM=async()=>{
          if(edit){document.getElementById('p-properties.t_skin_upper').value='.005';parameterEdited('properties.t_skin_upper');}
          return false;
        };
        try{await applyOptimizedDesign(params,result);throw Error('Expected mesh failure');}
        catch(error){return{certified:error.optimizedDimensionsApplied===true,targetMatches:error.definitionSignature===formSignature()};}
      };
      try{return{ownFailure:await attempt(false),externalEdit:await attempt(true)};}finally{createFEM=original;}
    });
    assert.deepEqual(retry.ownFailure,{certified:true,targetMatches:true});
    assert.deepEqual(retry.externalEdit,{certified:false,targetMatches:false});
    checks.push('A failed optimized-mesh update certifies its own applied dimensions for retry, and an intervening user edit invalidates that certificate.');
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({passed:true,synthetic_solver_jobs:true,checks,colored,retry,generated,requests,errors},null,2));
    console.log('PASS analysis result lifecycle and optimized property rendering ('+checks.length+' groups)');
  } catch(error) {
    fs.writeFileSync(path.join(output,'failure.json'),JSON.stringify({error:error.stack,checks,requests,errors},null,2));
    await page.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});throw error;
  } finally {releaseFeStart?.();releaseAeroStart?.();await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
