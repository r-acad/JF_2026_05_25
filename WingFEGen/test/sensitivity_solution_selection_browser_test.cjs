'use strict';
// Fixture-free UI contract: mock capability metadata, never numerical results or solves.
// node sensitivity_solution_selection_browser_test.cjs <evidence-dir> [playwright-module] [catalog.json]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]||'sensitivity-solution-browser-output');
const {chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web');
const checks=[],errors=[];
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const page=await browser.newPage({viewport:{width:1100,height:1050}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));
  await page.route('http://127.0.0.1:43961/**',route=>{
   const url=new URL(route.request().url());assert(!url.pathname.startsWith('/api/'),'Selection must not launch an analysis');
   return url.pathname==='/'?route.fulfill({contentType:'text/html',body:'<!DOCTYPE html><meta charset="utf-8"><main id="host"></main><script src="sensitivity.js"></script><script src="workspace.js"></script>'}):route.fulfill({path:path.join(web,decodeURIComponent(url.pathname))});
  });
  await page.goto('http://127.0.0.1:43961/');
  await page.evaluate(()=>{
   window.ctx={ready:true,dirty:false,blocked:false,catalogVisible:true,signature:'imported',meshIdentity:1};
   window.fixture={imported:true,variables:[{id:'reference.PSHELL#10#T',label:'Thickness',value:.001,unit:'m'}],cases:[{id:17,label:'Physical preload'},{id:18,label:'Buckling companion'}],
    objectives:{displacement:[],shell_stress:[],bar_stress:[],frequency_eigenvalue:[],buckling_factor:[]},solutions:{
     '101':{available:true,objectives:['displacement','shell_stress','bar_stress'],case_ids:[17]},
     '103':{available:true,objectives:['frequency_eigenvalue'],case_ids:[17]},
     '105':{available:true,objectives:['buckling_factor'],case_ids:[18],case_reasons:{'17':'Use the buckling subcase linked to physical preload 17.'}},
     '106':{available:true,objectives:['displacement'],case_ids:[17],note:'Full-load displacement uses the converged nonlinear final-state adjoint.'}}};
   window.edits=[];window.runs=[];window.pending=[];window.defer=false;
   window.editor=WingSensitivity.create(document.getElementById('host'),{context:()=>ctx,cases:()=>[{id:17,label:'Physical preload'}],onEdit:text=>edits.push(JSON.parse(text)),catalog:()=>{const response=structuredClone(fixture);return defer?new Promise(resolve=>pending.push(()=>resolve(response))):Promise.resolve(response);},run:request=>runs.push(request)});
   window.saved={case_id:18,objective:{type:'buckling_factor',mode:3},variables:['reference.PSHELL#10#T'],derivative_method:'analytic'};
   editor.restore(saved);
  });
  await page.waitForFunction(()=>!document.querySelector('#sensitivity-run').disabled);
  assert.equal(await page.locator('#sensitivity-solution').inputValue(),'105');
  assert.equal(await page.locator('#sensitivity-case').inputValue(),'18');
  assert.equal(await page.locator('#sensitivity-objective option:enabled').count(),1);
  assert.deepEqual(await page.evaluate(()=>edits),[]);
  checks.push('Legacy buckling setup infers SOL105 and catalogue supplies its imported companion case without editing the Study');

  await page.locator('#sensitivity-solution').selectOption('103');
  assert.equal(await page.locator('#sensitivity-objective').inputValue(),'frequency_eigenvalue');
  assert.equal(await page.locator('#sensitivity-case').inputValue(),'17');
  assert.equal(await page.locator('#sensitivity-target').inputValue(),'3');
  assert.equal(await page.locator('#sensitivity-use-pick').isHidden(),true);
  assert.equal(await page.locator('#sensitivity-run').isEnabled(),true);
  checks.push('Explicit modal selection retains mode number and variables, and selects an eligible physical case');

  await page.locator('#sensitivity-solution').selectOption('106');
  assert.equal(await page.locator('#sensitivity-objective').inputValue(),'displacement');
  assert.deepEqual(await page.locator('#sensitivity-objective option:enabled').evaluateAll(nodes=>nodes.map(n=>n.value)),['displacement']);
  assert.equal(await page.locator('#sensitivity-method option[value="operator_differences"]').evaluate(node=>node.disabled),true);
  assert.match(await page.locator('#sensitivity-solution-note').textContent(),/nonlinear final-state adjoint/);
  await page.locator('#sensitivity-target').fill('42');await page.locator('#sensitivity-component').selectOption('z');
  assert.equal(await page.locator('#sensitivity-run').isEnabled(),true);
  const nonlinear=await page.evaluate(()=>editor.capture());assert.equal(nonlinear.solution,'106');assert.equal(nonlinear.objective.component,'z');
  assert.deepEqual(await page.evaluate(()=>runs),[]);
  checks.push('Nonlinear displacement is separate from linear displacement; unsupported stresses and legacy differences are disabled without a solve');

  await page.evaluate(async()=>{
   const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:1,beta:.7,radius:12},activeCase:17,resultVariant:'sensitivity_example_sol106',workspace:{activeTab:'sensitivity',width:430,collapsed:false,maximizedTab:null},reference:{selectedIndex:-1,mode:'off'}};
   const study=await WingWorkspace.snapshot({'sensitivity.settings':editor.serialize()},null,view);
   editor.restore(WingWorkspace.parse(JSON.stringify(study)).data.parameters['sensitivity.settings']);
  });
  await page.waitForFunction(()=>!document.querySelector('#sensitivity-run').disabled);
  assert.deepEqual(await page.evaluate(()=>editor.capture()),nonlinear);
  await page.locator('#sensitivity-run').click();assert.equal(await page.evaluate(()=>runs.length),1);
  assert.equal(await page.evaluate(()=>runs[0].solution),'106');
  checks.push('Study serialization retains the nonlinear solution and selected baseline variant; only Run sends one explicit SOL106 request');

  await page.evaluate(()=>{
   window.historical={solution:'106',case_id:17,method:'analytic_discrete_adjoint',objective:structuredClone(editor.capture().objective),request:editor.capture(),baseline:{value:1,unit:'m'},rows:[]};
   window.historicalJSON=JSON.stringify(historical);editor.complete(historical,ctx.signature);
  });
  assert.equal(await page.evaluate(()=>editor.isSetupCurrent()),true);
  await page.locator('#sensitivity-solution').selectOption('101');
  assert.equal(await page.evaluate(()=>editor.isSetupCurrent()),false);
  assert.equal(await page.evaluate(()=>JSON.stringify(historical)===historicalJSON),true);
  await page.locator('#sensitivity-solution').selectOption('106');
  assert.equal(await page.evaluate(()=>editor.isSetupCurrent()),true);
  checks.push('Changing only the solution marks results stale and returning restores validity; the historical request is unchanged');

  await page.evaluate(()=>{fixture.solutions['106']={available:false,objectives:['displacement'],case_ids:[17],reason:'Follower-force nonlinear sensitivities are not supported.'};editor.readCatalog();});
  await page.waitForFunction(()=>document.querySelector('#sensitivity-solution option[value="106"]').disabled);
  assert.equal(await page.locator('#sensitivity-solution').inputValue(),'106');
  assert.match(await page.locator('#sensitivity-context').textContent(),/Follower-force/);
  assert.equal(await page.locator('#sensitivity-run').isDisabled(),true);
  assert.equal(await page.evaluate(()=>editor.capture().solution),'106');
  checks.push('Unavailable nonlinear capability retains the selected solution and explains the blocker instead of silently running SOL101');

  await page.evaluate(()=>editor.restore({...saved,solution:'105',case_id:17}));
  await page.waitForFunction(()=>document.querySelector('#sensitivity-context').textContent.includes('linked to physical preload 17'));
  assert.equal(await page.locator('#sensitivity-case').inputValue(),'17');
  assert.equal(await page.locator('#sensitivity-run').isDisabled(),true);
  checks.push('A restored ineligible case remains visible with its exact catalogue reason, awaiting an explicit user correction');

  await page.evaluate(()=>{defer=true;editor.readCatalog();});await page.waitForFunction(()=>pending.length===1);
  await page.evaluate(()=>{ctx.signature='restored';ctx.meshIdentity=2;fixture.solutions['103'].available=false;fixture.solutions['103'].reason='No positive structural mass for modal analysis.';editor.restore({...saved,solution:'103',case_id:17,objective:{type:'frequency_eigenvalue',mode:2}});});
  await page.waitForFunction(()=>pending.length===2);await page.evaluate(()=>pending[0]());
  assert.equal(await page.locator('#sensitivity-run').isDisabled(),true);await page.evaluate(()=>pending[1]());
  await page.waitForFunction(()=>document.querySelector('#sensitivity-context').textContent.includes('No positive structural mass'));
  assert.equal(await page.locator('#sensitivity-solution').inputValue(),'103');
  assert.equal(await page.evaluate(()=>runs.length),1);assert.deepEqual(errors,[]);
  checks.push('An old in-flight catalogue cannot enable a restored solution or overwrite its request; no implicit analyses occur');
  if(process.argv[4]){
   const catalogue=JSON.parse(fs.readFileSync(process.argv[4],'utf8'));
   await page.evaluate(catalogue=>{defer=false;fixture=catalogue;ctx.signature='actual-catalogue';ctx.meshIdentity=3;editor.restore({solution:'101',case_id:catalogue.cases[0].id,objective:{type:'displacement',node_id:1,component:'z'},variables:[catalogue.variables[0].id],derivative_method:'analytic'});},catalogue);
   await page.waitForFunction(()=>!document.querySelector('#sensitivity-refresh').disabled);
   for(const [solution,info] of Object.entries(catalogue.solutions)){
    assert.equal(await page.locator('#sensitivity-solution option[value="'+solution+'"]').evaluate(node=>node.disabled),!info.available);
    if(!info.available)continue;
    await page.locator('#sensitivity-solution').selectOption(solution);
    assert.deepEqual(await page.locator('#sensitivity-objective option:enabled').evaluateAll(nodes=>nodes.map(node=>node.value)),info.objectives);
    assert.deepEqual(await page.locator('#sensitivity-case option:enabled').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),info.case_ids);
    assert.equal(await page.evaluate(()=>editor.capture().solution),solution);
   }
   assert.equal(await page.evaluate(()=>runs.length),1);
   checks.push('The supplied real backend catalogue drives every solution, objective and eligible case without a solve');
  }
  await page.screenshot({path:path.join(out,'solution-selection.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
