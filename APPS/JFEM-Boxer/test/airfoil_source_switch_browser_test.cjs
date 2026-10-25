'use strict';
// node airfoil_source_switch_browser_test.cjs <evidence-dir> <playwright-module>
// Tests the production airfoil editor, with deterministic local UIUC responses.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const coordinates='Local section\n1 0\n.75 .04\n.5 .06\n.25 .05\n0 0\n.25 -.03\n.5 -.04\n.75 -.02\n1 0\n';
const fileProfile={...require('../web/airfoils.js').parseCoordinateFile(coordinates,{filename:'original.dat'}),raw_sha256:crypto.createHash('sha256').update(coordinates).digest('hex'),imported_at:'2026-10-24T00:00:00Z'};
const uiucProfile=id=>({version:1,id,name:id,source_kind:'uiuc',source_url:'https://m-selig.ae.illinois.edu/ads/coord/'+id,fetched_at:'2026-10-24T00:00:00Z',raw_sha256:'0'.repeat(64),xu:[0,.5,1],xl:[0,.5,1],zu:[0,.07,0],zl:[0,-.07,0]});
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],requests=[],checks=[];
 const server=http.createServer((req,res)=>{
  requests.push(req.url);
  if(req.url==='/airfoils.js'){res.setHeader('Content-Type','text/javascript; charset=utf-8');res.end(fs.readFileSync(path.join(web,'airfoils.js')));return;}
  if(req.url.startsWith('/api/airfoils')){res.setHeader('Content-Type','application/json');const id=new URL(req.url,'http://localhost').searchParams.get('id');setTimeout(()=>res.end(JSON.stringify(id?{profile:uiucProfile(id)}:{items:[{id:'fast.dat',label:'Fast profile'},{id:'slow.dat',label:'Slow profile'}]})),id==='slow.dat'?400:0);return;}
  res.setHeader('Content-Type','text/html; charset=utf-8');res.end('<!doctype html><style>[hidden]{display:none!important}body{font:14px system-ui}.airfoil-source-editor{width:600px}svg{width:600px;height:240px}</style><section id="host"></section><script src="/airfoils.js"></script>');
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({headless:true,channel:'chrome'}),page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(fileProfile=>{
   window.buildFixture=function(saved){
    window.editor?.destroy();const host=document.getElementById('host');host.innerHTML='<h2>Airfoils</h2>';window.observed=[];
    const field=(key,value,choices)=>{const row=document.createElement('label');row.id='row-'+key;const input=document.createElement(choices?'select':'input');input.id='p-'+key;if(choices)for(const choice of choices){const option=document.createElement('option');option.value=option.textContent=choice;input.append(option);}input.value=saved?.[key]??value;row.append(key,input);host.append(row);return input;};
    for(const station of ['root','tip']){
     const source=field('airfoil.'+station+'_source','file',['naca','uiuc','file']);field('airfoil.'+station,'NACA2412');field('airfoil.'+station+'_profile',JSON.stringify(fileProfile));
     // Boxer has a parameter handler before the editor installs its listeners.
     source.addEventListener('change',()=>observed.push({source:source.value,profile:document.getElementById('p-airfoil.'+station+'_profile').value}));
    }
    field('airfoil.n_points','121');const closed=field('airfoil.closed_trailing_edge','');closed.type='checkbox';closed.checked=true;
    field('airfoil.interpolation','linear',['linear','cosine']);field('airfoil.stations',JSON.stringify([{eta:.5,source:'file',code:fileProfile.id,profile:fileProfile}]));
    window.editor=WingAirfoils.install(host);window.snapshot=()=>Object.fromEntries([...document.querySelectorAll('[id^="p-"]')].map(el=>[el.id.slice(2),el.value]));
   };buildFixture();
  },fileProfile);
  const stations=[{name:'root',source:'[id="p-airfoil.root_source"]',stored:'p-airfoil.root_profile'},{name:'tip',source:'[id="p-airfoil.tip_source"]',stored:'p-airfoil.tip_profile'},{name:'station-1',source:'#airfoil-station-1-source'}];
  const selected=station=>page.evaluate(station=>station.stored?JSON.parse(document.getElementById(station.stored).value||'null'):editor.readDrafts()['airfoil.stations'][0].profile,station);
  const invalid=()=>page.evaluate(()=>{try{editor.assertValidDraft();return '';}catch(e){return e.message;}});
  for(const station of stations){
   await page.locator(station.source).selectOption('uiuc');
   assert.equal(await selected(station),null,station.name+' does not reuse a local file as a UIUC profile');
   assert.match(await invalid(),/Select a UIUC/);assert.equal(await page.locator('#airfoil-'+station.name+'-card .airfoil-selected svg').count(),0);
   await page.waitForFunction(name=>document.getElementById('airfoil-'+name+'-choices').options.length===2,station.name);
   await page.locator('#airfoil-'+station.name+'-choices').selectOption('fast.dat');await page.locator('#airfoil-'+station.name+'-use').click();
   await page.waitForFunction(name=>document.getElementById('airfoil-'+name+'-card').dataset.profileState==='ready',station.name);
   assert.equal((await selected(station)).id,'fast.dat');assert.equal(await invalid(),'');
   await page.locator(station.source).selectOption('file');assert.equal((await selected(station)).filename,'original.dat');
   await page.locator('#airfoil-'+station.name+'-file').setInputFiles({name:station.name+'-replacement.dat',mimeType:'text/plain',buffer:Buffer.from(coordinates)});
   await page.waitForFunction(name=>document.getElementById('airfoil-'+name+'-card').querySelector('.airfoil-local-file [role=status]').textContent.includes('Embedded'),station.name);
   assert.equal((await selected(station)).filename,station.name+'-replacement.dat');
   await page.locator(station.source).selectOption('naca');if(station.name==='station-1'){assert.match(await invalid(),/NACA/);await page.locator('#airfoil-station-1-code').fill('NACA2412');}assert.equal(await invalid(),'');assert.equal(await page.locator('#airfoil-'+station.name+'-card .airfoil-selected svg').count(),1);
   await page.locator(station.source).selectOption('uiuc');assert.equal((await selected(station)).id,'fast.dat');
   await page.locator(station.source).selectOption('file');assert.equal((await selected(station)).filename,station.name+'-replacement.dat');
   checks.push(station.name+': file/UIUC/NACA transitions, preview, generation validation and independent cached choices');
  }
  assert((await page.evaluate(()=>observed)).every(row=>!row.profile||JSON.parse(row.profile).source_kind===row.source),'Existing parameter change listeners see the updated matching payload');
  checks.push('Source/profile transition is atomic before other change handlers');
  // A response for an abandoned selection must not overwrite the active source.
  await page.locator(stations[0].source).selectOption('uiuc');await page.locator('#airfoil-root-browse').click();
  const slow=page.waitForResponse(response=>response.url().includes('profile?id=slow.dat'));
  await page.locator('#airfoil-root-choices').selectOption('slow.dat');await page.locator(stations[0].source).selectOption('file');await slow;
  assert.equal((await selected(stations[0])).filename,'root-replacement.dat');
  checks.push('Abandoned asynchronous UIUC request cannot overwrite a local file selection');
  await page.evaluate(()=>{const original=File.prototype.arrayBuffer;File.prototype.arrayBuffer=function(){return this.name==='slow-file.dat'?new Promise(resolve=>setTimeout(resolve,200)).then(()=>original.call(this)):original.call(this);};});
  await page.locator('#airfoil-root-file').setInputFiles({name:'slow-file.dat',mimeType:'text/plain',buffer:Buffer.from(coordinates)});
  await page.locator(stations[0].source).selectOption('naca');
  await page.waitForTimeout(300);assert.equal(await page.locator('[id="p-airfoil.root_profile"]').inputValue(),'');
  await page.locator(stations[0].source).selectOption('file');assert.equal((await selected(stations[0])).filename,'root-replacement.dat');
  checks.push('Abandoned asynchronous local-file read cannot overwrite NACA or the last accepted local file');
  const saved=await page.evaluate(()=>snapshot());await page.evaluate(saved=>buildFixture(saved),saved);
  assert.equal(await invalid(),'');assert.equal((await selected(stations[0])).filename,'root-replacement.dat');
  assert.equal((await selected(stations[1])).filename,'tip-replacement.dat');assert.equal((await selected(stations[2])).filename,'station-1-replacement.dat');
  checks.push('Saved active selections reopen with their actual file coordinates for root, tip and intermediate station');
  await page.evaluate(saved=>buildFixture({...saved,'airfoil.root_source':'uiuc'}),saved);
  assert.match(await invalid(),/Select a UIUC/);assert.equal(await page.locator('#airfoil-root-card svg').count(),0);
  await page.locator(stations[0].source).selectOption('file');assert.equal((await selected(stations[0])).filename,'root-replacement.dat');assert.equal(await invalid(),'');
  checks.push('An existing inconsistent source/profile draft is rejected clearly and recovers by selecting its actual file source');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'airfoil_source_switch.json'),JSON.stringify({passed:true,checks,errors,requests},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'airfoil-source-failure.png'),fullPage:true});throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
