'use strict';
// Optional fixture-free browser checks. Arguments: output directory, Playwright module.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]||'playwright'),out=path.resolve(process.argv[2]||'deck-browser-output'),web=path.resolve(__dirname,'../web'),checks=[],errors=[];
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})}),page=await browser.newPage({viewport:{width:1200,height:800}});
try{
 page.on('pageerror',error=>errors.push(error.stack));await page.route('http://127.0.0.1:43953/**',route=>{const url=new URL(route.request().url());return route.fulfill(url.pathname==='/'?{contentType:'text/html',body:'<!DOCTYPE html><link rel="stylesheet" href="model_workspace.css"><style>body{background:#182029;color:white;font:14px sans-serif}#deck-text{height:600px;width:650px;overflow:auto;font:12px/18px Consolas,monospace;white-space:pre}</style><h1>Large deck display</h1><pre id="deck-text" tabindex="0"></pre><script src="deck_view.js"></script>'}:{path:path.join(web,url.pathname)});});
 await page.goto('http://127.0.0.1:43953/');
 const initial=await page.evaluate(()=>{
  window.source=Array.from({length:100000},(_,i)=>'GRID,'+(i+1)+',,'+(i===99995?'UNIQUE_LAST_CARD':i)+',0.,0.\r\n').join('');window.host=document.getElementById('deck-text');window.viewer=WingDeckView.create(host);
  const start=performance.now();viewer.setText(source);const height=host.scrollHeight;return{ms:performance.now()-start,height,chunks:host.childElementCount,text:host.textContent===source,spanCount:host.querySelectorAll('.deck-chunk').length};
 });
 assert(initial.text);assert.equal(initial.spanCount,250);assert.equal(initial.chunks,1);assert(initial.height>1000000);checks.push('Complete 100,000-line CRLF deck is retained exactly in bounded-layout chunks');
 const find=await page.evaluate(()=>{const found=window.find('UNIQUE_LAST_CARD'),selection=getSelection();if(found)selection.getRangeAt(0).startContainer.parentElement.scrollIntoView({block:'center'});return{found,top:host.scrollTop};});assert(find.found);await page.waitForFunction(()=>host.scrollTop>1000000);
 const selected=await page.evaluate(()=>{const range=document.createRange();range.selectNodeContents(host);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);const text=selection.toString();selection.removeAllRanges();const normalize=s=>s.replaceAll('\r\n','\n').replace(/\n$/,'');return{normalized:normalize(text)===normalize(source),length:text.length,expected:source.length};});
 assert(selected.normalized);checks.push('Browser find locates an offscreen last-page card, scrolling reveals its chunk, and select-all retains every source line');
 const identity=await page.evaluate(()=>{const child=host.firstChild,urlPosition=host.scrollTop;return{changed:viewer.setText(source),same:host.firstChild===child,position:host.scrollTop===urlPosition};});assert.deepEqual(identity,{changed:false,same:true,position:true});checks.push('Reusing an identical deck keeps DOM identity and scroll position');
 const timing=await page.evaluate(()=>{const measure=()=>{const at=performance.now();for(let i=0;i<20;i++){host.style.width=(550+i*8)+'px';void host.clientWidth;}return performance.now()-at;};host.scrollTop=0;const chunkedMs=measure();viewer.setText('SOL 101\nENDDATA\n');const small=host.textContent==='SOL 101\nENDDATA\n'&&!host.classList.contains('deck-chunked');return{chunkedMs,small};});assert(timing.small);checks.push('Small decks use ordinary text and replacement resets the previous scroll position');
 await page.evaluate(()=>{viewer.setText(source);host.scrollTop=399*18;});await page.screenshot({path:path.join(out,'chunk-boundary.png')});
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,initial,selected,timing,errors},null,2));console.log(checks.join('\n'));
}catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
