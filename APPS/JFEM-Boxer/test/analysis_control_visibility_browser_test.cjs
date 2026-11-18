'use strict';
// Actual Boxer page and canonical forms. Only the transport is intercepted;
// no solver responses or reserve factors are invented or requested here.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,playwrightArg='playwright']=process.argv.slice(2);
const fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const {chromium}=require(playwrightArg),origin='http://127.0.0.1:43983';
const schema=JSON.parse(fs.readFileSync(path.join(fixture,fs.existsSync(path.join(fixture,'schema.json'))?'schema.json':'default_warm_schema.json'),'utf8'));
schema.defaults??=schema.values;
const payload=fs.readFileSync(path.join(fixture,fs.existsSync(path.join(fixture,'payload.msgpack'))?'payload.msgpack':'default_warm_payload.msgpack'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1550,height:1150}}),errors=[],requests=[],checks=[];
 page.setDefaultTimeout(60000);page.on('pageerror',error=>errors.push(error.stack));
 try{
  await page.route(origin+'/**',async route=>{
   const url=new URL(route.request().url());
   if(url.pathname.startsWith('/api/'))requests.push(url.pathname);
   if(url.pathname==='/api/input')return route.fulfill({json:{...schema,ok:true}});
   if(['/api/prepare_workspace','/api/generate'].includes(url.pathname))return route.fulfill({contentType:'application/msgpack',body:payload});
   if(['/api/restore_workspace','/api/validate_workspace'].includes(url.pathname))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
   if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true,repo:'same root'}});
   if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'No analysis operation is authorized by this UI test.'}});
   const file=url.pathname.startsWith('/shared/')?path.join(web,'../..',url.pathname.slice(8)):path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing asset'});
  });
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();
  await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy);
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('analysis');});
  const visible=async id=>page.locator('#'+id.replaceAll('.','\\.')).isVisible();
  for(const sol of ['101','103','105','106','103','101']){
   await page.locator('[id="p-output.solution"]').selectOption(sol);
   assert.equal(await visible('analysis-eigen-fields'),['103','105'].includes(sol));
   assert.equal(await visible('analysis-nonlinear-fields'),sol==='106');
   assert.equal(await visible('row-nonlinear.method'),sol==='106');
   assert.equal(await visible('analysis-buckling-fields'),sol==='105');
   assert.equal(await visible('group-sizing-load-policy'),sol!=='103');
   assert.equal(await visible('row-assessment.strength_safety_factor'),['101','106'].includes(sol));
   assert.equal(await visible('row-assessment.buckling_policy_factor'),sol!=='103');
   assert.equal(await visible('row-output.buckling_energy_density'),false);
   checks.push('SOL'+sol+' shows its own numerical and assessment controls.');
   if(sol==='103'){
    assert.match(await page.locator('[id="row-output.n_modes"] .field-label label').textContent(),/^Requested modes$/);
    await page.screenshot({path:path.join(out,'normal-modes-controls.png')});
   }
   if(sol==='105'){
    assert.match(await page.locator('[id="row-output.n_modes"] .field-label label').textContent(),/^Requested buckling roots$/);
    assert(!/Strength compares/.test(await page.locator('#sizing-load-policy-note').textContent()));
    await page.screenshot({path:path.join(out,'buckling-controls.png')});
   }
  }
  await page.locator('[id="p-assessment.strength_safety_factor"]').fill('1.7');
  await page.locator('[id="p-assessment.buckling_policy_factor"]').fill('1.2');
  await page.locator('[id="p-output.solution"]').selectOption('103');
  assert.equal(await page.locator('[id="p-assessment.strength_safety_factor"]').inputValue(),'1.7');
  await page.locator('[id="p-output.solution"]').selectOption('106');
  assert.equal(await page.locator('[id="p-assessment.strength_safety_factor"]').inputValue(),'1.7');
  assert.equal(await page.locator('[id="p-assessment.buckling_policy_factor"]').inputValue(),'1.2');
  checks.push('Switching solutions retains authored assessment values.');
  // Exercise the real imported-deck selector and source-solution contract.
  await page.evaluate(()=>{
   const deck={name:'visibility-fixture.bdf',solution:'103',signature:'visibility-only',cases:[],source:{kind:'reference',name:'visibility-fixture.bdf',text:'SOL 103\nCEND\nBEGIN BULK\nENDDATA',analysis:{solution:'source'}}};
   globalThis.visibilityImportedDeck=deck;
   globalThis.visibilityImportedController=WingImportedAnalysis.create({host:document.getElementById('imported-analysis'),read:()=>deck,onChange:value=>{deck.source.analysis=value;}});
   visibilityImportedController.refresh();
  });
  assert.equal(await visible('group-sizing-load-policy'),false);
  assert.equal(await page.locator('#imported-analysis [data-key="follower"]').isVisible(),false);
  await page.locator('#imported-analysis [data-key="solution"]').selectOption('105');
  assert.equal(await visible('row-assessment.buckling_policy_factor'),true);
  assert.equal(await visible('row-assessment.strength_safety_factor'),false);
  assert.equal(await page.locator('#imported-analysis [data-eigen]').isVisible(),true);
  await page.locator('#imported-analysis [data-key="solution"]').selectOption('106');
  assert.equal(await visible('row-assessment.strength_safety_factor'),true);
  assert.equal(await page.locator('#imported-analysis [data-nonlinear]').isVisible(),true);
  assert.equal(await page.locator('#imported-analysis [data-key="follower"]').isVisible(),true);
  checks.push('Imported source and override solutions also control policy visibility.');
  await page.locator('#imported-analysis [data-key="follower"]').selectOption('force');
  await page.locator('#imported-analysis [data-key="solution"]').selectOption('103');
  assert.equal(await page.locator('#imported-analysis [data-key="follower"]').isVisible(),true);
  assert.match(await page.locator('#imported-analysis [data-note]').textContent(),/Select fixed forces/);
  await page.locator('#imported-analysis [data-key="follower"]').selectOption('fixed');
  assert.equal(await page.locator('#imported-analysis [data-key="follower"]').isVisible(),false);
  checks.push('An incompatible retained follower override remains reachable until cleared.');
  assert(!requests.some(url=>/run_jfem|rf_sensitivity\/start|sensitivit(?:y|ies)\/start/.test(url)));
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,errors},null,2));
  console.log(JSON.stringify({passed:true,checks:checks.length,analysisRequests:0}));
 }catch(error){
  await page.screenshot({path:path.join(out,'failed.png')}).catch(()=>{});
  fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,requests},null,2));throw error;
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
