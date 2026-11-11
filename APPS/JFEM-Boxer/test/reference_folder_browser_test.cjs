'use strict';
// Standalone importer: recursive scan, native-path browser and import are explicit fixtures.
// node reference_folder_browser_test.cjs OUT PLAYWRIGHT [CHROME]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,modulePath,chromeArg]=process.argv.slice(2),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(path.resolve(modulePath));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(chromeArg?{executablePath:chromeArg}:{})}),page=await browser.newPage({viewport:{width:1300,height:1000}}),errors=[],checks=[];
 try{
  page.on('pageerror',error=>errors.push(error.message));await page.setContent('<html><body></body></html>');
  for(const file of ['style.css','reference_import.css'])await page.addStyleTag({path:path.join(web,file)});await page.addScriptTag({path:path.join(web,'reference_import.js')});
  await page.evaluate(()=>{
   window.ready=false;window.pending=[];window.requests=[];window.browseRequests=[];window.rejectImport=true;
   window.importer=WingReferenceImport.create({
    prepareImporter:async()=>({state:ready?'ready':'preparing',seconds:1}),
    scanFolder:request=>new Promise(resolve=>pending.push({request,resolve})),
    listFolder:async request=>{browseRequests.push(request);const dir=request.path||'C:/models';return{ok:true,directory:dir,parent:dir==='C:/models'?null:'C:/models',drives:['C:/'],total:2,next_offset:null,entries:[{name:'sub',path:'C:/models/sub',directory:true},{name:'notes.txt',path:dir+'/notes.txt',directory:false,bytes:100}]};},
    onImport:async request=>{requests.push(request);if(rejectImport)throw Error('Conflicting GRID ID 42: mesh/a.inc line 10 and mesh/b.inc line 11. No definition was overwritten.');return true;}
   });importer.open({mode:'folder',browse:false});
  });
  const read=page.locator('#reference-read'),folderPath=page.locator('#reference-folder-path');
  assert(await page.locator('#reference-single-source').isHidden());assert(await read.isDisabled());
  await folderPath.fill('"C:/models/A"');await page.locator('#reference-folder-scan').click();assert(await read.isDisabled());assert.equal(await page.evaluate(()=>pending[0].request.path),'C:/models/A');
  await page.locator('#reference-folder-scan-cancel').click();
  await page.evaluate(()=>pending[0].resolve({ok:true,path:'C:/models/A',files:[{path:'stale.bdf',bytes:10}]}));await page.waitForTimeout(50);
  assert(await page.locator('#reference-folder-review').isHidden());assert(await read.isDisabled());
  await page.locator('#reference-folder-scan').click();await folderPath.fill('C:/models/B');await page.locator('#reference-folder-scan').click();
  await page.evaluate(()=>pending[1].resolve({ok:true,path:'C:/models/A',files:[{path:'stale_again.bdf',bytes:10}]}));await page.waitForTimeout(50);assert.equal(await folderPath.inputValue(),'C:/models/B');assert(await page.locator('#reference-folder-review').isHidden());
  await page.evaluate(()=>pending[2].resolve({ok:true,directory:'C:/models/B',scan_id:'reviewed-manifest',total_bytes:4096,primary_required:true,primary_candidates:['analysis/main.dat','analysis/alternate.dat'],files:[{path:'analysis/main.dat',bytes:1024},{path:'analysis/alternate.dat',bytes:1024},{path:'mesh/<skin>.inc.gz',bytes:2048}],warnings:['One Abaqus input was skipped because it is not Nastran.']}));
  await page.locator('#reference-folder-review').waitFor();assert.equal(await page.locator('#reference-scan-rows tr').count(),3);assert((await page.locator('#reference-folder-summary').innerText()).includes('3 / 3 files'));assert.equal(await page.evaluate(()=>requests.length),0);
  assert.equal(await read.getAttribute('data-ready'),'false');await page.locator('#reference-folder-primary').selectOption('analysis/main.dat');assert.equal(await read.getAttribute('data-ready'),'false');
  await page.evaluate(()=>ready=true);await page.waitForFunction(()=>document.getElementById('reference-read').dataset.ready==='true');
  checks.push('Cancelled and obsolete asynchronous scans are ignored; a recursive review never imports automatically and readiness requires both a primary header and a prepared parser');
  await page.locator('#reference-scan-rows tr').first().locator('input').uncheck();assert.equal(await read.getAttribute('data-ready'),'false');assert.equal(await page.locator('#reference-folder-primary').inputValue(),'');
  await page.locator('#reference-scan-rows tr').first().locator('input').check();await page.locator('#reference-folder-primary').selectOption('analysis/main.dat');
  await page.locator('#reference-scan-rows tr').nth(1).locator('input').uncheck();assert((await page.locator('#reference-folder-summary').innerText()).includes('2 / 3 files'));assert.equal(await read.getAttribute('data-ready'),'true');
  await read.click();await page.locator('#reference-import-error').waitFor();assert((await page.locator('#reference-import-error').innerText()).includes('mesh/a.inc line 10'));
  const request=await page.evaluate(()=>requests[0]);assert.deepEqual(request,{path:'C:/models/B',mode:'folder',selected_files:['mesh/<skin>.inc.gz','analysis/main.dat'],ignore_unresolved_includes:false,primary_file:'analysis/main.dat',scan_id:'reviewed-manifest'});
  await page.waitForFunction(()=>document.getElementById('reference-read').dataset.ready==='true');
  checks.push('Reviewed file selections and the manifest ID reach import; conflicting definitions display actionable file/line diagnostics and retain the review for correction');
  await page.screenshot({path:path.join(out,'folder-fragments-review.png')});
  await page.locator('#reference-folder-browse').click();await page.locator('#reference-file-browser').waitFor();assert.equal(await read.getAttribute('data-ready'),'false');
  await page.locator('#reference-folder-list [data-kind=folder]').first().click();await page.waitForFunction(()=>document.getElementById('reference-directory-path').value==='C:/models/sub');
  assert(await page.locator('#reference-folder-list [data-kind=file]').isDisabled());await page.locator('#reference-folder-cancel').click();assert.equal(await read.getAttribute('data-ready'),'true');
  await page.locator('#reference-folder-browse').click();await page.locator('#reference-file-browser').waitFor();await page.screenshot({path:path.join(out,'folder-picker-in-app.png')});
  await page.locator('#reference-folder-list [data-kind=folder]').first().click();await page.waitForFunction(()=>document.getElementById('reference-directory-path').value==='C:/models/sub');await page.locator('#reference-folder-use').click();
  assert.equal(await folderPath.inputValue(),'C:/models/sub');await page.waitForFunction(()=>pending.length===4);
  await page.evaluate(()=>pending[3].resolve({ok:true,directory:'C:/models/sub',scan_id:'new-manifest',total_bytes:25,primary_candidates:[],files:[{path:'mesh.bdf',bytes:25}]}));
  await page.waitForFunction(()=>document.getElementById('reference-read').dataset.ready==='true');assert(await page.locator('#reference-folder-primary-row').isHidden());
  checks.push('Folder navigation remains inside the importer, supports cancellation, disables file entries and scans the chosen directory without any system picker');
  assert.equal(await page.locator('#reference-folder-ignore-includes').isChecked(),false);await page.locator('#reference-folder-ignore-includes').check();assert(await read.isDisabled());assert(await page.locator('#reference-folder-review').isHidden());await page.locator('#reference-folder-scan').click();await page.waitForFunction(()=>pending.length===5);
  assert.equal(await page.evaluate(()=>pending[4].request.ignore_unresolved_includes),true);
  await page.evaluate(()=>pending[4].resolve({ok:true,directory:'C:/models/sub',scan_id:'ignore-reviewed',total_bytes:25,primary_candidates:[],files:[{path:'mesh.bdf',bytes:25}],warnings:['Unresolved INCLUDE old/location/parts.inc is ignored by explicit user choice.']}));await page.waitForFunction(()=>document.getElementById('reference-read').dataset.ready==='true');
  checks.push('Ignoring missing INCLUDE paths is opt-in, invalidates the previous scan and passes the explicit choice through the reviewed import');
  await page.setViewportSize({width:390,height:900});await page.screenshot({path:path.join(out,'folder-fragments-narrow.png')});
  const overflow=await page.locator('.reference-import-dialog').evaluate(el=>({scroll:el.scrollWidth,client:el.clientWidth}));assert(overflow.scroll<=overflow.client+1);
  await page.evaluate(()=>rejectImport=false);await read.click();await page.waitForFunction(()=>!document.querySelector('.reference-import-dialog').open);assert.equal(await page.evaluate(()=>requests.length),2);
  assert.equal(await page.evaluate(()=>requests[1].ignore_unresolved_includes),true);
  assert.deepEqual(errors,[]);checks.push('The narrow dialog contains its file review and a successful read closes cleanly with no browser errors');
  fs.writeFileSync(path.join(out,'folder-import-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log('Recursive folder importer: '+checks.length+' groups passed.');
 }catch(error){fs.writeFileSync(path.join(out,'folder-import-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'folder-import-failure.png')}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
