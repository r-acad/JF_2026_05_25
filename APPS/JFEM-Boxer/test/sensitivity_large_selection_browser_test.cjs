'use strict';
// Fixture-free browser contract: generated catalogue metadata, no numerical solves.
// node sensitivity_large_selection_browser_test.cjs <private-evidence-dir> [playwright-module]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web');
const checks=[],errors=[],timings={};
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const executablePath=process.env.CHROME_BIN||process.env.CHROME_PATH;
 const browser=await chromium.launch({headless:true,...(executablePath?{executablePath}:{})});
 const page=await browser.newPage({viewport:{width:1200,height:1100}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));
  await page.route('http://127.0.0.1:43964/**',route=>{const url=new URL(route.request().url());assert(!url.pathname.startsWith('/api/'),'Selection must not launch an analysis');
   return url.pathname==='/'?route.fulfill({contentType:'text/html',body:'<!DOCTYPE html><meta charset="utf-8"><link rel="stylesheet" href="style.css"><link rel="stylesheet" href="sensitivity.css"><style>body{overflow:auto}#host{max-width:850px;margin:24px auto;padding:20px}</style><main id="host"></main><script src="result_display.js"></script><script src="sensitivity.js"></script><script src="workspace.js"></script>'}):route.fulfill({path:path.join(web,decodeURIComponent(url.pathname))});
  });
  await page.goto('http://127.0.0.1:43964/');
  await page.evaluate(async()=>{
   window.ctx={ready:true,dirty:false,blocked:false,catalogVisible:true,signature:'large-native',meshIdentity:1};
   window.panels=Array.from({length:12037},(_,i)=>({id:'properties.panels#'+(i%2?'lower':'upper')+':bay'+(i+1)+':stringer1:segment1#skin#thickness',label:'P'+(i+1)+' '+(i%2?'Lower':'Upper')+' skin thickness',value:.002,unit:'m'}));
   window.components=Array.from({length:11003},(_,i)=>({id:'properties.components#front_web:'+(i+1)+'#thickness',label:'Spar web bay '+(i+1),value:.003,unit:'m'}));
   window.family='properties.t_spar_web';window.material={id:'material.E',label:'Elastic modulus',value:70e9,unit:'Pa'};
   window.catalog={max_variables:4096,variables:[{id:family,label:'Shared spar thickness'},...panels,...components,material],selection_replacements:{[family]:components.map(row=>row.id)},selection_aliases:{[family]:{label:'All spar web bays'}}};
   window.allIDs=[...panels,...components,material].map(row=>row.id);window.runs=[];window.editCount=0;
   window.editor=WingSensitivity.create(document.querySelector('#host'),{autoRefreshCatalog:false,context:()=>ctx,cases:()=>[{id:1,label:'Flight'}],catalog:async()=>structuredClone(catalog),onEdit:()=>editCount++,run:request=>runs.push(request)});
   window.settings={case_id:1,objective:{type:'displacement',node_id:12,component:'z'},variables:[]};editor.restore(settings);await editor.readCatalog();
  });
  const total=await page.evaluate(()=>allIDs.length),panelCount=12037,componentCount=11003;
  const bounded=async()=>assert((await page.locator('#sensitivity-variables input').count())<=64,'Only a bounded row window may be mounted');
  const selection=()=>page.evaluate(()=>editor.capture().variables);
  await bounded();assert.match(await page.locator('#sensitivity-variable-count').textContent(),new RegExp('0 selected / '+total+' available'));
  await page.locator('#sensitivity-filter').fill('P*');const start=Date.now();await page.locator('#sensitivity-select-shown').click();timings.add_12037_ms=Date.now()-start;
  assert.equal((await selection()).length,panelCount);assert(await page.locator('#sensitivity-select-shown').isDisabled());await bounded();
  assert.match(await page.locator('#sensitivity-filter-status').textContent(),/12037 selected \(12037 shown, 0 outside/);
  checks.push('P* Add matches selects all 12,037 panel variables despite legacy max_variables=4096, with at most 64 mounted checkboxes');

  await page.locator('#sensitivity-filter').fill('*upper*');await page.locator('#sensitivity-remove-matches').click();
  assert.equal((await selection()).length,6018);assert(await page.evaluate(()=>{const lower=new Set(panels.filter((_,i)=>i%2).map(row=>row.id));return editor.capture().variables.every(id=>lower.has(id));}));
  await page.locator('#sensitivity-select-shown').click();assert.equal((await selection()).length,panelCount);
  await page.locator('#sensitivity-filter').fill('[');await page.locator('#sensitivity-filter-mode').selectOption('regex');assert(await page.locator('#sensitivity-select-shown').isDisabled());assert.equal((await selection()).length,panelCount);
  await page.locator('#sensitivity-filter-mode').selectOption('wildcard');await page.locator('#sensitivity-clear-filter').click();assert.equal((await selection()).length,panelCount);
  await page.locator('#sensitivity-select-shown').click();assert.equal((await selection()).length,total);assert(await page.locator('#sensitivity-run').isEnabled());await bounded();
  checks.push('Filtered removal and additive re-selection preserve all hidden selections; invalid regex and Clear filter leave the selection unchanged; Add all reaches all 23,041 independent variables');

  await page.locator('#sensitivity-variables').evaluate(node=>{node.scrollTop=node.scrollHeight;});
  const last=page.locator('#sensitivity-variables input[value="material.E"]');await last.waitFor();assert(await last.isChecked());const previous=await page.locator('#sensitivity-variables').evaluate(node=>node.scrollTop);
  await last.uncheck();assert.equal((await selection()).length,total-1);assert.equal(await last.evaluate(node=>node.ownerDocument.activeElement===node),true);assert.equal(await page.locator('#sensitivity-variables').evaluate(node=>node.scrollTop),previous);
  await last.check();await bounded();assert.match(await page.locator('#sensitivity-variable-range').textContent(),new RegExp('of '+(total+1)+' matching entries'));
  await page.locator('#sensitivity-variables').evaluate(node=>{node.scrollTop=0;});await page.waitForFunction(()=>document.querySelector('#sensitivity-variables input')?.dataset.variableIndex==='0');
  await page.locator('#sensitivity-variables input').first().focus();for(let i=0;i<80;i++)await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(()=>document.activeElement.dataset.variableIndex),'80');await bounded();
  checks.push('Scrolling reaches the last variable; individual toggles preserve scroll and focus; keyboard Tab traverses beyond the mounted window');

  await page.evaluate(async()=>{
   window.savedConfig=editor.capture();const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:1,beta:.7,radius:12},activeCase:1,workspace:{activeTab:'sensitivity',width:430,collapsed:false,maximizedTab:null},reference:{selectedIndex:-1,mode:'off'}};
   window.study=await WingWorkspace.snapshot({'sensitivity.settings':editor.serialize()},null,view);
   editor.restore(WingWorkspace.parse(JSON.stringify(study)).data.parameters['sensitivity.settings']);
  });
  assert.equal((await selection()).length,total);await page.evaluate(()=>editor.readCatalog());
  assert(await page.evaluate(()=>JSON.stringify(editor.capture())===JSON.stringify(savedConfig)));await bounded();
  assert.equal(await page.evaluate(()=>runs.length),0);await page.locator('#sensitivity-run').click();
  assert(await page.evaluate(()=>runs.length===1&&JSON.stringify(runs[0])===JSON.stringify(savedConfig)));
  checks.push('Study capture, serialization, restore, catalogue refresh and explicit Run preserve every selected ID in the complete request; no selection action runs an analysis');

  await page.evaluate(async()=>{editor.restore({...settings,variables:[family,'material.E']});await editor.readCatalog();});
  assert.equal((await selection()).length,componentCount+1);assert(await page.evaluate(()=>{const selected=new Set(editor.capture().variables);return components.every(row=>selected.has(row.id));}));
  await page.locator('#sensitivity-clear').click();const familyBox=page.locator('#sensitivity-variables input[data-selection-family]');await familyBox.check();assert.equal((await selection()).length,componentCount);
  await page.locator('#sensitivity-filter').fill('no match');await page.locator('#sensitivity-clear').click();await page.locator('#sensitivity-add-components').click();assert.equal((await selection()).length,componentCount);
  await page.locator('#sensitivity-clear-filter').click();await page.locator('#sensitivity-select-shown').click();assert.equal((await selection()).length,total);
  checks.push('Study family expansion, family checkboxes and Add component variables each include all 11,003 local dimensions independently of the filter or legacy cap');

  await page.evaluate(async()=>{editor.restore({...editor.capture(),variables:[...allIDs,'unknown.saved.id']});await editor.readCatalog();});
  assert.equal((await selection()).length,total+1);assert(await page.locator('#sensitivity-run').isDisabled());assert.match(await page.locator('#sensitivity-context').textContent(),/1 selected property is no longer present/);
  await page.locator('#sensitivity-clear').click();await page.locator('#sensitivity-select-shown').click();assert.equal((await selection()).length,total);assert(await page.locator('#sensitivity-run').isEnabled());
  checks.push('Unknown saved IDs remain explicit blockers without discarding any valid selection; Clear selection and Add matches recover the whole catalogue');

  await page.evaluate(async()=>{catalog={imported:true,max_variables:4096,variables:panels.map((row,i)=>({...row,id:'reference.PSHELL#'+(i+1)+'#T'}))};ctx.signature='large-imported';ctx.meshIdentity=2;editor.restore(settings);await editor.readCatalog();});
  await page.locator('#sensitivity-select-shown').click();assert.equal((await selection()).length,panelCount);assert(await page.locator('#sensitivity-add-components').isHidden());assert(await page.locator('#sensitivity-run').isEnabled());
  await page.locator('#sensitivity-run').click();assert(await page.evaluate(()=>runs.length===2&&runs[1].variables.length===12037&&runs[1].variables.at(-1)==='reference.PSHELL#12037#T'));await bounded();
  checks.push('Imported catalogues likewise select and submit every one of 12,037 variables with the native controls correctly hidden');
  await page.screenshot({path:path.join(out,'large-selection.png'),fullPage:true});assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,timings,counts:{panels:panelCount,components:componentCount,independent_variables:total,max_mounted_checkboxes:64}},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,timings},null,2));await page.screenshot({path:path.join(out,'failure.png'),fullPage:true}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
