'use strict';
// Real stylesheet: attention affects only the Inspect label, including the
// active tab, and honors reduced motion. Class synchronization is app-owned.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[];
 const html='<link rel="stylesheet" href="/style.css"><nav id="workspace-nav"><div id="workspace-tablist"><button id="tab-results" class="workspace-tab">Results</button><button id="tab-inspect" class="workspace-tab">Inspect</button></div></nav>';
 const server=http.createServer((req,res)=>{if(req.url==='/style.css'){res.setHeader('Content-Type','text/css');return res.end(fs.readFileSync(path.join(web,'style.css')));}res.setHeader('Content-Type','text/html');res.end(html);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})}),page=await browser.newPage({viewport:{width:600,height:180}});
 page.on('pageerror',error=>errors.push(error.stack));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  const styles=await page.evaluate(()=>{
   const inspect=document.getElementById('tab-inspect'),other=document.getElementById('tab-results');
   function style(button){const css=getComputedStyle(button),rect=button.getBoundingClientRect();return{color:css.color,background:css.backgroundColor,border:css.borderBottomColor,width:rect.width,height:rect.height,animation:css.animationName};}
   const normal=style(inspect),otherBefore=style(other);inspect.classList.add('rf-inspect-attention');
   const animation=inspect.getAnimations()[0];animation.pause();animation.currentTime=0;const dim=style(inspect);animation.currentTime=1000;const bright=style(inspect);
   inspect.classList.add('active');const active=style(inspect);inspect.classList.remove('active');
   return{normal,dim,bright,active,otherBefore,otherAfter:style(other)};
  });
  assert.equal(styles.dim.animation,'rf-inspect-label-pulse');assert.notEqual(styles.dim.color,styles.bright.color);
  for(const state of[styles.dim,styles.bright]){assert.equal(state.background,styles.normal.background);assert.equal(state.border,styles.normal.border);assert.equal(state.width,styles.normal.width);assert.equal(state.height,styles.normal.height);const[r,g,b]=state.color.match(/[\d.]+/g).map(Number);assert(r>220&&g>170&&b<180,'Both pulse phases must retain readable yellow text');}
  assert.equal(styles.active.color,styles.bright.color,'Selected Inspect must keep its yellow invitation');
  assert.deepEqual(styles.otherAfter,styles.otherBefore,'Other tabs must remain unchanged');
  await page.screenshot({path:path.join(out,'yellow-inspect.png')});
  await page.emulateMedia({reducedMotion:'reduce'});
  const reduced=await page.evaluate(()=>{const element=document.getElementById('tab-inspect'),css=getComputedStyle(element);return{animation:css.animationName,color:css.color,shadow:css.textShadow,background:css.backgroundColor};});
  assert.equal(reduced.animation,'none');assert.equal(reduced.color,'rgb(255, 216, 106)');assert.equal(reduced.shadow,'none');assert.equal(reduced.background,styles.normal.background);
  const cleared=await page.evaluate(()=>{const element=document.getElementById('tab-inspect');element.classList.remove('rf-inspect-attention');const css=getComputedStyle(element);return{animation:css.animationName,color:css.color};});
  assert.equal(cleared.animation,'none');assert.equal(cleared.color,styles.normal.color);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,styles,reduced,cleared,errors},null,2));console.log('RF Inspect label: readable text-only pulse, active tab, stable layout, reduced motion and clearing pass.');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
