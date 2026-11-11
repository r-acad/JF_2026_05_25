'use strict';
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 try{
  const page=await browser.newPage();await page.setContent('<html><body></body></html>');
  await page.addStyleTag({path:path.join(__dirname,'../web/style.css')});
  await page.addStyleTag({path:path.join(__dirname,'../web/reference_import.css')});
  await page.addScriptTag({path:path.join(__dirname,'../web/reference_import.js')});
  await page.evaluate(()=>{
   window.prepared=false;window.allowImport=null;window.requests=[];
   window.importer=WingReferenceImport.create({
    prepareImporter:async()=>({state:prepared?'ready':'preparing',seconds:2}),
    pickFile:async()=>({path:'C:/models/selected.bdf'}),
    onImport:async request=>{requests.push(request);await new Promise(resolve=>allowImport=resolve);throw Error('Fixture retry');}
   });importer.open();
  });
  await page.waitForFunction(()=>document.getElementById('reference-local-path').value.length>0);
  assert.equal(await page.locator('#reference-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  await page.evaluate(()=>prepared=true);
  await page.waitForFunction(()=>document.getElementById('reference-read').classList.contains('deck-ready'));
  await page.waitForTimeout(200);
  assert.equal(await page.locator('#reference-read').getAttribute('data-ready'),'true');
  assert.equal(await page.locator('#reference-read').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(27, 129, 80)');
  await page.locator('#reference-read').hover();await page.waitForTimeout(200);
  assert.equal(await page.locator('#reference-read').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(35, 148, 94)');
  await page.mouse.move(0,0);
  if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});await page.waitForTimeout(200);await page.screenshot({path:path.join(process.argv[2],'read-nastran-ready.png')});}
  await page.locator('#reference-local-path').evaluate(e=>{e.value='';e.dispatchEvent(new Event('change',{bubbles:true}));});
  assert.equal(await page.locator('#reference-read').getAttribute('data-ready'),'false');
  await page.locator('#reference-local-path').fill('');
  assert.equal(await page.locator('#reference-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  await page.locator('#reference-local-path').fill('C:/models/selected.bdf');
  await page.locator('#reference-read').click();
  assert.equal(await page.locator('#reference-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  assert(await page.locator('#reference-read').isDisabled());
  await page.evaluate(()=>allowImport());
  await page.waitForFunction(()=>document.getElementById('reference-read').classList.contains('deck-ready'));
  assert.deepEqual(await page.evaluate(()=>requests),[{path:'C:/models/selected.bdf'}]);
  assert(await page.locator('#reference-import-error').isVisible());
  console.log('Read deck ready state: selected path, asynchronous preparation, green style, reading state and retry verified.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
