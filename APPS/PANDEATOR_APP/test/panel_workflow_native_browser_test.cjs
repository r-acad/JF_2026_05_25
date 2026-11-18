'use strict';
// Explicit integration check against an isolated, already-running Julia server.
// It runs one small real SOL105/analytical adjoint + two-step FD job. The mock
// contract test is separate and does not make numerical validation claims.
// node panel_workflow_native_browser_test.cjs SERVER_URL PRIVATE_EVIDENCE_DIR PLAYWRIGHT_MODULE [EXISTING_JOB_ID]
// An existing job ID replays only its retained GET result; it never starts a
// second calculation. Use the identical fixed test parameters for this replay.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [origin,out,playwrightPath='playwright',existingJobId]=process.argv.slice(2);
if(!origin||!out)throw Error('Provide an isolated server URL and a private evidence directory.');
if(new URL(origin).port==='8080')throw Error('This test must not use the interactive user server on port 8080.');
fs.mkdirSync(out,{recursive:true});
const app=path.resolve(__dirname,'..'),MP=require(path.join(app,'vendor','msgpack.min.js'));
(async()=>{
 const {chromium}=require(playwrightPath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1680,height:1120},acceptDownloads:true}),errors=[],jobs=[];let heartbeat;
 page.on('pageerror',error=>errors.push(error.stack));
 // Ask the real integration job to export the already-solved baseline once,
 // so this same FD job also exercises mode parsing/rendering. Production FD
 // defaults keep full-field exports off; no extra forward calculation is made.
 await page.route('**/panel/jobs',async route=>{const request=route.request();if(request.method()!=='POST')return route.continue();const payload=MP.decode(new Uint8Array(request.postDataBuffer()));if(payload.operation==='validate')payload.options.include_binary=true;jobs.push(payload);if(existingJobId)return route.fulfill({status:200,contentType:'application/msgpack',body:Buffer.from(MP.encode({ok:true,id:existingJobId,status:'queued'}))});await route.continue({postData:Buffer.from(MP.encode(payload))});});
 page.setDefaultTimeout(30000);
 try{
  await page.goto(origin);await page.waitForFunction(()=>typeof panelWorkflow!=='undefined'&&panelWorkflow?.model&&!panelWorkflow.busy);
  const values={R:0,nx:4,ny:4,nz:2,nf:2,nModes:5,Nxy:12};
  for(const [id,value] of Object.entries(values))await page.locator('#'+id).fill(String(value));
  await page.locator('#previewBtn').click();await page.waitForFunction(()=>!panelWorkflow.busy&&panelWorkflow.model?.params?.R===0);
  const preview=await page.evaluate(()=>({params:panelWorkflow.model.params,report:panelWorkflow.model.model_report,counts:panelWorkflow.model.geometry.counts,mass:document.getElementById('massBox').textContent,bcMarkers:bcMeshes.length}));
  assert(preview.counts.nNodes>0&&preview.counts.nQuads>0);assert(preview.bcMarkers>0);assert.match(preview.mass,/kg/);
  for(const id of ['tSkin','tWeb','tFoot'])await page.locator('#panel-variable-list input[value="'+id+'"]').setChecked(id==='tSkin');
  await page.locator('#panel-derivative-modes').fill('3');
  await page.locator('#panel-validate').click();await page.waitForFunction(()=>panelWorkflow.busy&&document.getElementById('panel-cancel').disabled===false);
  heartbeat=setInterval(async()=>{try{console.log((await page.locator('#panel-job-state').textContent()).trim());}catch(_){}},30000);
  await page.waitForFunction(()=>!panelWorkflow.busy,{},{timeout:2700000});clearInterval(heartbeat);heartbeat=null;
  const result=await page.evaluate(()=>panelWorkflow.result);assert(result,await page.locator('#panel-workflow-error').textContent());
  assert.deepEqual(result.parameters,preview.params,'Retained numerical results belong to the exact canonical test model.');
  assert.equal(jobs.length,1);assert.equal(jobs[0].operation,'validate');assert.deepEqual(jobs[0].variables,['tSkin']);assert.deepEqual(jobs[0].options.fd_steps,[.001,.0005]);assert.equal(jobs[0].options.include_binary,true);
  assert(result.responses.length>=7);assert(result.sensitivities.length>=7);assert(result.validation.length>=14);
  const invalid=result.validation.filter(row=>row.status!=='passed');assert.deepEqual(invalid,[],'Every real tSkin FD check must pass.');
  assert(result.responses.some(row=>row.kind==='sol105'));assert(result.responses.some(row=>row.kind==='analytical'));
  const viewer=await page.evaluate(()=>({preview:!!femData._isPreview,nNodes:femData.nNodes,eigenvalues:Array.from(femData.eigenvalues||[]),files:analysisFiles.length,modes:femData._results?.filter(row=>row.mode).length}));
  assert.equal(viewer.preview,false);assert.equal(viewer.nNodes,preview.counts.nNodes);assert(viewer.files>=1&&viewer.modes>=5&&viewer.eigenvalues.length>=5,'The same baseline has real mode artifacts in the viewer.');
  await page.evaluate(()=>{const index=femData._results.findIndex(row=>row.mode);document.getElementById('modeSelect').value=String(index);document.getElementById('modeSelect').dispatchEvent(new Event('change'));});
  await page.waitForFunction(()=>scene.isReady());await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  await page.screenshot({path:path.join(out,'native-fe-buckling-mode.png')});
  assert.equal(await page.locator('#panel-study-results').isVisible(),true);assert(!((await page.locator('#panel-result-table').textContent()).includes('[object Object]')));
  await page.screenshot({path:path.join(out,'native-fd-validation.png')});
  await page.locator('[data-result-tab="responses"]').click();await page.screenshot({path:path.join(out,'native-buckling-factors.png')});
  await page.locator('[data-result-tab="sensitivities"]').click();await page.screenshot({path:path.join(out,'native-adjoint-matrix.png')});
  const jsonPromise=page.waitForEvent('download');await page.locator('#panel-export-json').click();await(await jsonPromise).saveAs(path.join(out,'native-results.json'));
  const csvPromise=page.waitForEvent('download');await page.locator('#panel-export-csv').click();await(await csvPromise).saveAs(path.join(out,'native-sensitivities.csv'));
  assert.deepEqual(errors,[]);const maximumRelativeError=Math.max(...result.validation.map(row=>row.relative_error).filter(Number.isFinite));
  const summary={passed:true,kind:'real Julia server integration and tSkin two-step finite-difference validation with same-baseline mode artifacts',origin,replayed_existing_job:existingJobId||null,preview,viewer,request:jobs[0],responses:result.responses.map(({id,value,raw_lambda,status,diagnostics})=>({id,value,raw_lambda,status,diagnostics})),validationCount:result.validation.length,maximumRelativeError,output_dir:result.output_dir,errors};
  fs.writeFileSync(path.join(out,'native-summary.json'),JSON.stringify(summary,null,2));console.log('PASS native PANDEATOR browser: '+result.responses.length+' responses, '+result.validation.length+' passed finite differences; maximum relative derivative error '+maximumRelativeError+'.');
 }catch(error){if(heartbeat)clearInterval(heartbeat);fs.writeFileSync(path.join(out,'native-failure.json'),JSON.stringify({error:error.stack,errors,jobs,replayed_existing_job:existingJobId||null,note:'The server job is retained; a browser/test failure does not request cancellation. Replay the existing job to inspect its final result without another calculation.'},null,2));await page.screenshot({path:path.join(out,'native-failure.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
