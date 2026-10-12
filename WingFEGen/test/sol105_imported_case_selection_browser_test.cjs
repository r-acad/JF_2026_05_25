'use strict';
// Real saved solver values: direct native static subcase and its buckling variants.
// Usage: WING_PLAYWRIGHT_MODULE=<module> node this-file <fixture-directory>
// Fixtures are exported separately; this test never starts a solver or app server.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {chromium}=require(process.env.WING_PLAYWRIGHT_MODULE||'playwright');
const web=path.resolve(__dirname,'../web'),out=path.resolve(process.argv[2]);
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  const rows=[],checks=[];
  try {
    for(const scenario of ['native','legacy']) {
      const page=await browser.newPage({viewport:{width:1500,height:1050}}),errors=[];
      page.on('pageerror',error=>errors.push(error.stack));
      const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
      await page.route('http://127.0.0.1:43986/**',route=>{
        const pathname=new URL(route.request().url()).pathname;
        return pathname==='/index.html'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,pathname)});
      });
      await page.goto('http://127.0.0.1:43986/index.html');
      for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
      for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
      const source=fs.readFileSync(path.join(web,'app.js'),'utf8'),cut=source.indexOf('(async function start()');
      assert(cut>0,'Recognized application bootstrap is required');await page.addScriptTag({content:source.slice(0,cut)});
      const fixtureFiles=['model','results'].map(kind=>path.join(out,scenario+'_'+kind+'.msgpack'));
      const initial=await page.evaluate(async({model,results,schema})=>{
        initScene();state.engine.stopRenderLoop();state.schema=schema.schema;
        state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;
        const payload=MessagePack.decode(Uint8Array.from(results));
        state.importedDeck={...state.data.imported_deck,source:{...state.data.model_source,analysis:payload.imported_analysis}};
        state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
        buildForm(state.schema,state.values);buildModel(state.data);state.modelDirty=false;
        state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.activeCase=17;
        const fetch=window.fetch,calls=[];window.fetch=async url=>{calls.push(String(url));return{ok:true,arrayBuffer:async()=>Uint8Array.from(results).buffer};};
        let loaded;try{loaded=await loadJfemResults();}finally{window.fetch=fetch;}
        setBusy(false);document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
        activateWorkspaceTab('results');document.getElementById('animate').checked=false;applyDeformation();state.scene.render();
        return {loaded,calls,case:state.activeCase,analysis:state.results.analysis,source:state.results.source,matches:state.results.matches,mode:state.activeMode,modes:state.results.modes.length,
          cases:[...document.getElementById('result-case-select').options].map(o=>o.value),results:[...state.resultCases.keys()],variantHostHidden:document.getElementById('result-comparison').hidden,
          directDisp:[...state.results.static.disp],directContours:state.results.contours.map(c=>({name:c.name,unit:c.unit,values:[...c.values]}))};
      },{model:[...fs.readFileSync(fixtureFiles[0])],results:[...fs.readFileSync(fixtureFiles[1])],schema:JSON.parse(fs.readFileSync(path.join(out,'schema.json'),'utf8'))});
      assert(initial.loaded&&initial.matches,JSON.stringify(initial));assert.equal(initial.case,17);assert.equal(initial.analysis,'SOL101_STATIC');assert.equal(initial.source,'buckling_preload');
      assert.equal(initial.mode,-1);assert.equal(initial.modes,0);assert.deepEqual(initial.cases,['17','18']);assert.deepEqual([...initial.results].sort((a,b)=>a-b),[17,18]);assert(initial.variantHostHidden);
      assert.equal(initial.calls.length,1);assert(!initial.calls.some(url=>/solve|generate/.test(url)));
      checks.push(scenario+': original static case 17 remains selected after loading actual native results');

      await page.locator('#contour-select').selectOption({label:'Displacement magnitude'});
      await page.locator('#btn-real-scale').click();
      const physical=await page.evaluate(()=>{
        document.getElementById('animate').checked=false;applyDeformation();state.scene.render();
        const shape=activeShape(),expected=[];
        for(let i=0;i<shape.shape.length;i+=3)expected.push(state.baseline[i]+shape.shape[i+1],state.baseline[i+1]+shape.shape[i+2],state.baseline[i+2]+shape.shape[i]);
        return {unit:contourValues().unit,amplitude:amplitude(),peak:shape.maxDisp,maxPoseError:Math.max(...expected.map((v,i)=>Math.abs(v-state.deformed[i]))),
          shells:state.shellMeshes.filter(mesh=>mesh.isEnabled()&&!mesh.material.wireframe).length,reactions:state.results.reactions.forces.length,realScale:document.getElementById('deform-scale-txt').textContent};
      });
      assert.equal(physical.unit,'m');assert.equal(physical.amplitude,1);assert(physical.peak>0);assert(physical.maxPoseError<1e-7);assert(physical.shells>0&&physical.reactions>0);assert.equal(physical.realScale,'1:1');
      checks.push(scenario+': physical static displacement uses metres and true 1:1 mesh coordinates with support reactions');
      const stressName=initial.directContours.find(c=>c.unit==='Pa'&&c.values.some(v=>v!==0))?.name;
      assert(stressName,'Actual solver stress contour exists');await page.locator('#contour-select').selectOption({label:stressName});
      const stress=await page.evaluate(()=>{state.scene.render();const c=contourValues();return {name:c.name,unit:c.unit,location:c.location,ids:c.elementIds?[...c.elementIds]:null,values:[...c.values],min:c.min,max:c.max};});
      assert.equal(stress.unit,'Pa');assert.deepEqual(stress.values,initial.directContours.find(c=>c.name===stressName).values);assert(stress.values.some(v=>v!==0));
      await page.screenshot({path:path.join(out,scenario+'_case17_static.png')});
      checks.push(scenario+': direct static case exposes unchanged recovered stress values through the contour selector');

      await page.locator('#result-case-select').selectOption('18');
      const buckling=await page.evaluate(()=>({case:state.activeCase,variant:state.results.variantId,mode:state.activeMode,modes:state.results.modes.length,kind:state.results.modeKind,
        options:[...document.getElementById('result-analysis-select').options].map(o=>({value:o.value,text:o.text})),factors:state.results.modes.map(m=>m.loadFactor)}));
      assert.equal(buckling.case,18);assert.equal(buckling.variant,'sol105');assert.equal(buckling.mode,0);assert(buckling.modes>=2);assert.equal(buckling.kind,'buckling');
      assert.deepEqual(buckling.options.map(o=>o.value),['sol101','sol105']);assert.match(buckling.options[0].text,/SOL101 preload/);assert(buckling.factors.every(v=>v>0));
      await page.locator('#contour-select').selectOption({label:'Displacement magnitude'});await page.locator('#animate').uncheck();
      await page.locator('#mode-1').click();
      const second=await page.evaluate(()=>{
        const paired=[...currentResultVariants().values()].filter(r=>r.static),saved=paired.map(r=>r.static.maxDisp),before=amplitude();
        let altered;try{paired.forEach(r=>r.static.maxDisp*=9);altered=amplitude();}finally{paired.forEach((r,i)=>r.static.maxDisp=saved[i]);}
        return {mode:state.activeMode,unit:contourValues().unit,realDisabled:document.getElementById('btn-real-scale').disabled,shape:[...activeShape().shape],expected:[...state.results.modes[1].shape],
          amplitude:before,amplitudeAfterPreloadPerturbation:altered,expectedAmplitude:0.1*state.diag/activeShape().maxDisp*scaleFactor(),renderedPeak:before*activeShape().maxDisp,
          expectedRenderedPeak:0.1*state.diag*scaleFactor(),modePeak:activeShape().maxDisp,preloadPeak:state.results.static.maxDisp};
      });
      assert.equal(second.mode,1);assert.equal(second.unit,'normalised');assert(second.realDisabled);assert.deepEqual(second.shape,second.expected);
      assert(Math.abs(second.amplitude/second.expectedAmplitude-1)<1e-12,'Mode display scale must use its own normalized peak independently of the physical preload: '+JSON.stringify(second));
      assert.equal(second.amplitudeAfterPreloadPerturbation,second.amplitude);assert(Math.abs(second.renderedPeak/second.expectedRenderedPeak-1)<1e-12);
      checks.push(scenario+': eigenmode peak is 10% of model diagonal at default scale and remains independent of paired static peak');
      await page.evaluate(()=>state.scene.render());await page.screenshot({path:path.join(out,scenario+'_case18_buckling.png')});
      checks.push(scenario+': buckling case 18 exposes both analyses and selectable normalized positive eigenmodes');

      await page.locator('#result-analysis-select').selectOption('sol101');
      const variant=await page.evaluate(()=>({case:state.activeCase,variant:state.results.variantId,mode:state.activeMode,modes:state.results.modes.length,unit:contourValues().unit,disp:[...state.results.static.disp],contours:state.results.contours.map(c=>({name:c.name,unit:c.unit,values:[...c.values]}))}));
      assert.equal(variant.case,18);assert.equal(variant.variant,'sol101');assert.equal(variant.mode,-1);assert.equal(variant.modes,0);assert.equal(variant.unit,'m');
      assert.deepEqual(variant.disp,initial.directDisp);assert.deepEqual(variant.contours,initial.directContours);
      await page.locator('#result-case-select').selectOption('17');
      const directAgain=await page.evaluate(()=>({case:state.activeCase,mode:state.activeMode,analysis:state.results.analysis,disp:[...state.results.static.disp]}));
      assert.equal(directAgain.case,17);assert.equal(directAgain.mode,-1);assert.equal(directAgain.analysis,'SOL101_STATIC');assert.deepEqual(directAgain.disp,initial.directDisp);
      await page.locator('#result-case-select').selectOption('18');
      assert.equal(await page.locator('#result-analysis-select').inputValue(),'sol101');
      await page.locator('#result-analysis-select').selectOption('sol105');
      assert.equal(await page.evaluate(()=>state.activeMode),0);
      checks.push(scenario+': preload variant exactly matches original static results; case and analysis navigation preserves both');
      assert.deepEqual(errors,[]);rows.push({scenario,initial,physical,stress,buckling,second_mode:second,fixture_sha256:fixtureFiles.map(sha),page_errors:errors});await page.close();
    }
    const report={passed:true,check_groups:checks.length,checks,scenarios:rows,backend_fixture_receipt:JSON.parse(fs.readFileSync(path.join(out,'fixture_receipt.json'),'utf8')),
      browser:'Isolated local Playwright/Chrome fallback; in-app browser bootstrap unavailable and browser list empty',new_solver_runs:0,
      source_hashes:Object.fromEntries(['app.js','index.html'].map(f=>[f,sha(path.join(web,f))])),test_sha256:sha(__filename)};
    fs.writeFileSync(path.join(out,'browser_case_selection_summary.json'),JSON.stringify(report,null,2));console.log('Imported SOL105 case selection passed '+checks.length+' groups (native and legacy).');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
