'use strict';
// Fixture-free. node test/deck_search_browser_test.cjs <evidence-dir> [playwright-module]
// CHROME_PATH optionally selects a browser; default is Playwright Chromium.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2])throw Error('An evidence directory is required.');
const out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[3]||'playwright');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const page=await browser.newPage({viewport:{width:1100,height:820}});
 try{
  page.on('pageerror',e=>errors.push(e.stack));
  const index=fs.readFileSync(path.join(web,'index.html'),'utf8'),toolbar=index.slice(index.indexOf('<div class="deck-search"'),index.indexOf('<pre id="deck-text"'));
  await page.setContent('<!DOCTYPE html><meta charset="utf-8"><title>Deck search regression</title><style>body{background:#182029;color:#dde6ef;font:14px sans-serif;padding:15px}#deck-text{height:610px;width:900px;overflow:auto;font:12px/18px Consolas,monospace;white-space:pre}input,button{padding:6px;background:#203c52;color:#eef4fa;border:1px solid #7993a6}</style><h1>Deck search</h1>'+toolbar+'<pre id="deck-text" tabindex="0"></pre>');
  await page.addStyleTag({path:path.join(web,'model_workspace.css')});await page.addScriptTag({path:path.join(web,'deck_view.js')});
  await page.evaluate(()=>{
   window.host=document.getElementById('deck-text');window.viewer=WingDeckView.create(host,{search:{input:document.getElementById('deck-search-input'),button:document.getElementById('deck-search-first'),matchCase:document.getElementById('deck-search-case'),status:document.getElementById('deck-search-status')}});
   window.source=Array.from({length:100000},(_,i)=>'GRID,'+(i+1)+',,'+(i===99995?'LAST_[+].*CARD':i)+',0.,0.\r\n').join('');viewer.setText(source);window.blocks=[...host.querySelectorAll('.deck-chunk')];
  });
  const search=async value=>{await page.locator('#deck-search-input').fill(value);await page.locator('#deck-search-first').click();};
  await search('last_[+].*card');await page.waitForFunction(()=>host.scrollTop>1000000);
  assert.equal(await page.locator('.deck-search-match').textContent(),'LAST_[+].*CARD');assert.match(await page.locator('#deck-search-status').textContent(),/line 99996, column 13/);
  assert(await page.evaluate(()=>host.textContent===source&&blocks.every((b,i)=>b===host.querySelectorAll('.deck-chunk')[i])));
  checks.push('Literal case-insensitive search finds and reveals the first offscreen match in a 100,000-line deck; untouched chunk identities and complete text are retained');
  await page.screenshot({path:path.join(out,'first-match.png')});
  await page.locator('#deck-search-case').check();assert.equal(await page.locator('.deck-search-match').count(),0);assert.equal(await page.locator('#deck-search-status').textContent(),'No match in this deck.');
  await search('LAST_[+].*CARD');assert.equal(await page.locator('.deck-search-match').count(),1);
  checks.push('Match case distinguishes exact case; punctuation is treated literally, and missing matches clear old highlights');
  await page.locator('#deck-search-case').uncheck();await page.locator('#deck-search-input').fill('grid,2,');await page.locator('#deck-search-input').press('Enter');
  assert.equal(await page.locator('.deck-search-match').textContent(),'GRID,2,');assert.match(await page.locator('#deck-search-status').textContent(),/line 2, column 1/);
  await page.locator('#deck-search-input').press('Escape');assert.equal(await page.locator('#deck-search-input').inputValue(),'');assert.equal(await page.locator('.deck-search-match').count(),0);
  checks.push('Enter searches from the deck beginning and Escape clears the search without changing the source');
  const boundary=await page.evaluate(()=>{const before=performance.now(),result=viewer.findFirst('399,0.,0.\r\nGRID,401');return{result,marks:host.querySelectorAll('mark').length,text:host.textContent===source,ms:performance.now()-before};});
  assert(boundary.result.found);assert.equal(boundary.result.line,400);assert.equal(boundary.marks,2);assert(boundary.text);
  checks.push('A match spanning two rendering chunks highlights both portions while preserving CRLF source bytes');
  await page.evaluate(()=>{viewer.setText('SOL 105\nEIGRL,1,1e-6,50,10\nEIGRL,2,0,20,5\n$ <img src=x onerror=alert(1)>\nENDDATA\n');});
  await search('EIGRL');assert.match(await page.locator('#deck-search-status').textContent(),/line 2, column 1/);assert.equal(await page.locator('mark').count(),1);
  const same=await page.evaluate(()=>{const mark=host.querySelector('mark');return{changed:viewer.setText(host.textContent),same:host.querySelector('mark')===mark};});assert.deepEqual(same,{changed:false,same:true});
  await search('<img src=x onerror=alert(1)>');assert.equal(await page.locator('img').count(),0);assert.equal(await page.locator('mark').textContent(),'<img src=x onerror=alert(1)>');
  checks.push('Small-deck search highlights only the first occurrence, reusing identical decks preserves it, and HTML-like deck content stays literal');
  await search('EIGRL');await page.evaluate(()=>viewer.setText('SOL 101\nENDDATA\n'));assert.equal(await page.locator('mark').count(),0);assert.equal(await page.locator('#deck-search-status').textContent(),'No match in this deck.');
  await page.evaluate(()=>viewer.setText('EIGRL,7,1e-6,60,6\n'));assert.equal(await page.locator('mark').textContent(),'EIGRL');assert.match(await page.locator('#deck-search-status').textContent(),/line 1, column 1/);
  await page.locator('#deck-search-input').fill('');assert.equal(await page.locator('mark').count(),0);assert.equal(await page.locator('#deck-search-status').textContent(),'');
  checks.push('Replacing the displayed case re-evaluates the query and clears obsolete matches; clearing the input restores unmarked text');
  // Use the production case-selection function with the actual search markup,
  // without launching a mesh or solver just to exercise deck wiring.
  await page.goto('about:blank');await page.setContent('<!DOCTYPE html>'+toolbar+'<div id="deck-path"></div><a id="deck-download"></a><pre id="deck-text"></pre>');
  await page.addScriptTag({path:path.join(web,'deck_view.js')});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');
  await page.addScriptTag({content:'const state={lastDeck:{deck_text:"SOL 101\\n",case_decks:[{case_id:1,deck_text:"FORCE,1,5,0,10,0,0,1\\n",path:"case-one.bdf"},{case_id:2,deck_text:"MOMENT,2,8,0,3,1,0,0\\n",path:"case-two.bdf"}]}};'+app.slice(app.indexOf('function showDeckCase('),app.indexOf('function refreshDeckMetadata('))});
  await page.evaluate(()=>showDeckCase(1));await search('FORCE');assert.equal(await page.locator('mark').textContent(),'FORCE');assert.equal(await page.locator('#deck-download').getAttribute('download'),'case-one.bdf');
  await page.evaluate(()=>showDeckCase(2));assert.equal(await page.locator('mark').count(),0);assert.equal(await page.locator('#deck-search-status').textContent(),'No match in this deck.');
  await search('MOMENT');assert.equal(await page.locator('mark').textContent(),'MOMENT');assert.equal(await page.locator('#deck-download').getAttribute('download'),'case-two.bdf');
  const download=await page.evaluate(async()=>await(await fetch(document.getElementById('deck-download').href)).text());assert.equal(download,'MOMENT,2,8,0,3,1,0,0\n');
  checks.push('Production showDeckCase connects search controls, switches cases without stale matches and downloads the original unmodified deck text');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,boundary,errors},null,2));console.log('Deck search: '+checks.length+' browser groups passed.');
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
