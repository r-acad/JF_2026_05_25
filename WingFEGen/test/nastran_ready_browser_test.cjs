'use strict';
const assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 try{
  const page=await browser.newPage();await page.setContent('<html><body></body></html>');
  await page.addStyleTag({path:path.join(__dirname,'../web/nastran_import.css')});
  await page.addScriptTag({path:path.join(__dirname,'../web/nastran_import.js')});
  await page.evaluate(()=>{
   window.prepared=false;window.allowImport=null;window.requests=[];
   window.importer=WingNastranImport.create({
    prepareImporter:async()=>({state:prepared?'ready':'preparing',seconds:2}),
    pickFile:async()=>({path:'C:/models/selected.bdf'}),
    onImport:async request=>{requests.push(request);await new Promise(resolve=>allowImport=resolve);throw Error('Fixture retry');}
   });importer.open();
  });
  await page.waitForFunction(()=>document.getElementById('nastran-local-path').value.length>0);
  assert.equal(await page.locator('#nastran-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  await page.evaluate(()=>prepared=true);
  await page.waitForFunction(()=>document.getElementById('nastran-read').classList.contains('deck-ready'));
  assert.equal(await page.locator('#nastran-read').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(23, 100, 62)');
  await page.locator('#nastran-local-path').fill('');
  assert.equal(await page.locator('#nastran-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  await page.locator('#nastran-local-path').fill('C:/models/selected.bdf');
  await page.locator('#nastran-read').click();
  assert.equal(await page.locator('#nastran-read').evaluate(e=>e.classList.contains('deck-ready')),false);
  assert(await page.locator('#nastran-read').isDisabled());
  await page.evaluate(()=>allowImport());
  await page.waitForFunction(()=>document.getElementById('nastran-read').classList.contains('deck-ready'));
  assert.deepEqual(await page.evaluate(()=>requests),[{path:'C:/models/selected.bdf'}]);
  assert(await page.locator('#nastran-import-error').isVisible());
  console.log('Read deck ready state: selected path, asynchronous preparation, green style, reading state and retry verified.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
