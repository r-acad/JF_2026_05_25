'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
const web=path.join(__dirname,'../web');
const source=fs.readFileSync(path.join(web,'index.html'),'utf8');
const fieldset=source.match(/<fieldset id="solidcraft-export"[\s\S]*?<\/fieldset>/)[0];
const origin='http://127.0.0.1:44653';

(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  try{
    const page=await browser.newPage();
    const errors=[],requests=[];let mode='success',polls=0,cancelled=false,releaseStart;
    page.on('pageerror',error=>errors.push(error.message));
    await page.route(origin+'/**',async route=>{
      const url=new URL(route.request().url());
      if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:'<!doctype html><html><body>'+fieldset+
        '<div id="activity-status" hidden><span class="activity-spinner"></span><div><strong id="activity-label"></strong><small id="activity-detail"></small></div><span id="activity-time"></span></div><p id="mesh-status"></p></body></html>'});
      requests.push({path:url.pathname,body:route.request().postDataJSON()});
      if(url.pathname==='/api/solidcraft/start'){
        polls=0;cancelled=false;
        if(mode==='delayed-start')await new Promise(resolve=>{releaseStart=resolve;});
        return route.fulfill({json:{ok:true,id:'solid-test',state:'running',message:'Opening SolidCraft'}});
      }
      if(url.pathname==='/api/solidcraft/cancel'){
        assert.equal(route.request().headers()['content-type'],'application/json');
        assert.deepEqual(route.request().postDataJSON(),{});
        cancelled=true;return route.fulfill({json:{ok:true,id:'solid-test',state:'cancelled',message:'Export cancelled'}});
      }
      if(url.pathname==='/api/solidcraft/status'){
        polls++;
        if(cancelled)return route.fulfill({json:{ok:true,id:'solid-test',state:'cancelled',message:'Export cancelled'}});
        if(mode==='failure')return route.fulfill({json:{ok:true,id:'solid-test',state:'failed',error:'<img src=x onerror=alert(1)> bridge failed'}});
        if(mode==='publication-failure')return route.fulfill({json:{ok:true,id:'solid-test',state:'failed',
          message:'The complete model was saved, but its SolidCraft window could not be opened.',
          result:{path:'/home/user/wing study/Complete_wing.sc',bodies:5,closed_solids:5}}});
        if(mode==='saved-cancelled')return route.fulfill({json:{ok:true,id:'solid-test',state:'cancelled',
          message:'Export cancelled after saving the complete native model.',result:{path:'/home/user/wing study/Complete_wing.sc'}}});
        if(mode==='running'||polls<2)return route.fulfill({json:{ok:true,id:'solid-test',state:'running',message:'Creating closed wing bodies',completed:2,total:5}});
        return route.fulfill({json:{ok:true,id:'solid-test',state:'done',result:{path:'/home/user/wing study/Wing.sc',bodies:5,closed_solids:5}}});
      }
      return route.fulfill({status:404,json:{ok:false,error:'Unknown test endpoint'}});
    });
    await page.goto(origin);
    await page.addStyleTag({path:path.join(web,'activity.css')});
    await page.addScriptTag({path:path.join(web,'activity.js')});
    await page.addScriptTag({path:path.join(web,'solidcraft_export.js')});
    await page.evaluate(()=>{
      WingActivity.end(WingActivity.startup);WingActivity.startup=null;
      window.available=false;window.imported=false;window.logs=[];
      window.installExporter=()=>WingSolidCraftExport.create({document,activity:WingActivity,pollMs:25,
        isAvailable:()=>available,isImported:()=>imported,getParameters:()=>({'planform.area':41,'output.title':'Study with no FEM'}),
        log:(message,kind)=>logs.push({message,kind})});
      window.exporter=installExporter();
    });
    assert(await page.locator('#solidcraft-create').isDisabled());
    assert.equal(requests.length,0);
    await page.evaluate(()=>{available=true;exporter.refresh();});
    assert(await page.locator('#solidcraft-create').isEnabled());
    assert.equal(await page.evaluate(()=>!!document.querySelector('#render')),false);
    console.log('1. A loaded wing Study enables solid export before any FEM or renderer exists.');

    mode='running';
    await page.click('#solidcraft-create');
    await page.waitForFunction(()=>document.getElementById('solidcraft-status').textContent.includes('2 / 5'));
    assert(await page.locator('#solidcraft-create').isDisabled());
    assert(await page.locator('#solidcraft-cancel').isVisible());
    assert.equal(await page.evaluate(()=>exporter.start()),false);
    await page.waitForTimeout(1100);
    assert.equal(await page.evaluate(()=>WingActivity.count),1);
    assert.equal(await page.evaluate(()=>WingActivity.inlineCount),1);
    assert(Number(await page.locator('#solidcraft-export .activity-inline-elapsed').getAttribute('data-seconds'))>=1);
    const request=requests.find(row=>row.path==='/api/solidcraft/start');
    assert.deepEqual(request.body.parameters,{'planform.area':41,'output.title':'Study with no FEM'});
    assert.deepEqual(request.body.options,{structure:true,mirror:false,deflected:false,cli_path:'',app_path:''});
    mode='success';
    await page.waitForFunction(()=>!exporter.busy);
    assert.equal(await page.locator('#solidcraft-path').inputValue(),'/home/user/wing study/Wing.sc');
    assert(await page.locator('#solidcraft-output').isVisible());
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    const stoppedAt=polls;await page.waitForTimeout(100);assert.equal(polls,stoppedAt);
    console.log('2. Current parameters/options are submitted once, progress clocks advance, and success preserves the native path and releases timers.');

    mode='failure';
    await page.click('#solidcraft-create');
    await page.waitForFunction(()=>!exporter.busy);
    assert((await page.locator('#solidcraft-status').textContent()).includes('<img src=x'));
    assert.equal(await page.locator('#solidcraft-export img').count(),0);
    assert.equal(await page.locator('#solidcraft-path').inputValue(),'');
    assert(await page.locator('#solidcraft-output').isHidden());
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    console.log('3. Native errors remain readable text and the export can be retried without leaked activities.');

    mode='publication-failure';
    await page.click('#solidcraft-create');
    await page.waitForFunction(()=>!exporter.busy);
    assert((await page.locator('#solidcraft-status').textContent()).includes('window could not be opened'));
    assert.equal(await page.locator('#solidcraft-path').inputValue(),'/home/user/wing study/Complete_wing.sc');
    assert(await page.locator('#solidcraft-output').isVisible());
    await page.click('#solidcraft-copy-path');
    assert.equal(await page.locator('#solidcraft-path').evaluate(input=>input.selectionEnd-input.selectionStart),
      '/home/user/wing study/Complete_wing.sc'.length);
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    mode='saved-cancelled';
    await page.click('#solidcraft-create');
    await page.waitForFunction(()=>!exporter.busy);
    assert((await page.locator('#solidcraft-status').textContent()).includes('cancelled after saving'));
    assert.equal(await page.locator('#solidcraft-path').inputValue(),'/home/user/wing study/Complete_wing.sc');
    assert(await page.locator('#solidcraft-output').isVisible());
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    console.log('4. A saved complete model remains accessible after publication failure or cancellation, with readable status and a copyable path.');

    mode='delayed-start';
    await page.click('#solidcraft-create');
    while(!releaseStart)await new Promise(resolve=>setTimeout(resolve,10));
    await page.click('#solidcraft-cancel');
    releaseStart();releaseStart=null;
    await page.waitForFunction(()=>!exporter.busy);
    assert.equal(requests.filter(row=>row.path==='/api/solidcraft/cancel').length,1);
    assert((await page.locator('#solidcraft-status').textContent()).includes('cancelled'));
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    console.log('5. Cancellation before the start response reaches the created job and releases every progress timer.');

    const count=requests.length;
    await page.evaluate(()=>{imported=true;exporter.refresh();});
    assert(await page.locator('#solidcraft-create').isDisabled());
    assert.equal(await page.evaluate(()=>exporter.start()),false);assert.equal(requests.length,count);
    await page.evaluate(()=>{imported=false;available=false;exporter.refresh();});
    assert(await page.locator('#solidcraft-create').isDisabled());
    mode='running';
    await page.evaluate(()=>{available=true;exporter.refresh();});
    await page.click('#solidcraft-create');
    await page.waitForFunction(()=>document.getElementById('solidcraft-status').textContent.includes('2 / 5'));
    await page.evaluate(()=>exporter.destroy());
    await page.waitForFunction(()=>WingActivity.count+WingActivity.inlineCount===0);
    await page.waitForTimeout(100);
    assert.equal(requests.filter(row=>row.path==='/api/solidcraft/cancel').length,2);
    mode='delayed-start';
    await page.evaluate(()=>{exporter=installExporter();});
    await page.click('#solidcraft-create');
    while(!releaseStart)await new Promise(resolve=>setTimeout(resolve,10));
    await page.evaluate(()=>exporter.destroy());
    releaseStart();releaseStart=null;
    await page.waitForTimeout(100);
    assert.equal(requests.filter(row=>row.path==='/api/solidcraft/cancel').length,3);
    assert.equal(await page.evaluate(()=>WingActivity.count+WingActivity.inlineCount),0);
    assert.equal(await page.locator('#solidcraft-export .activity-inline').count(),0);
    assert.deepEqual(errors,[]);
    console.log('6. Imported/unloaded sources are excluded; active and late-job teardown sends JSON cancellation and releases clocks.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
