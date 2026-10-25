'use strict';
// node test/airfoil_candidate_browser_test.cjs EVIDENCE_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const profile=id=>({version:1,id,name:id,source_kind:'uiuc',source_url:'https://m-selig.ae.illinois.edu/ads/coord/'+id,fetched_at:'2026-10-25T00:00:00Z',raw_sha256:'0'.repeat(64),xu:[0,.5,1],xl:[0,.5,1],zu:[0,id==='new.dat'?.09:.06,0],zl:[0,-.06,0]});
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const server=http.createServer((req,res)=>{
  const name=req.url.slice(1);if(['airfoils.js','airfoils.css'].includes(name)){res.setHeader('Content-Type',(name.endsWith('.js')?'application/javascript':'text/css')+'; charset=utf-8');return res.end(fs.readFileSync(path.join(web,name)));}
  if(req.url.startsWith('/api/airfoils')){res.setHeader('Content-Type','application/json');const id=new URL(req.url,'http://localhost').searchParams.get('id');return setTimeout(()=>res.end(JSON.stringify(id?{profile:id==='broken.dat'?{...profile(id),zu:[0,-.5,0]}:profile(id)}:{items:['new.dat','slow.dat','broken.dat'].map(id=>({id,label:id}))})),id==='slow.dat'?350:10);}
  res.setHeader('Content-Type','text/html; charset=utf-8');res.end('<!doctype html><head><link rel="stylesheet" href="/airfoils.css"><style>body{background:#13202b;color:#dcebf6;font:13px system-ui;margin:14px}.airfoil-source-editor{width:400px}button{background:#243b4f;color:white;padding:6px;border:1px solid #426078;border-radius:4px}[hidden]{display:none!important}.row{display:flex;justify-content:space-between;gap:8px}.pick-note{line-height:1.5}</style></head><section id="host"></section><script src="/airfoils.js"></script>');
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:800,height:1100}});page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);await page.evaluate(original=>{
   const host=document.getElementById('host');host.innerHTML='<h2>Airfoils</h2>';window.edits=[];window.locked=false;
   const field=(key,value,choices)=>{const row=document.createElement('label');row.id='row-'+key;row.className='row';row.textContent=key;const el=document.createElement(choices?'select':'input');el.id='p-'+key;if(choices)for(const value of choices){const opt=document.createElement('option');opt.value=opt.textContent=value;el.append(opt);}el.value=value;row.append(el);host.append(row);return el;};
   for(const station of ['root','tip']){field('airfoil.'+station+'_source',station==='root'?'naca':'uiuc',['naca','uiuc','file']);field('airfoil.'+station,'NACA2412');field('airfoil.'+station+'_profile',station==='root'?'':JSON.stringify(original));}
   field('airfoil.n_points','121');const closed=field('airfoil.closed_trailing_edge','');closed.type='checkbox';closed.checked=true;field('airfoil.stations','[]');
   window.editor=WingAirfoils.install(host,{onEdit:key=>edits.push(key),isLocked:()=>locked});
  },profile('original.dat'));
  const value=station=>page.locator('[id="p-airfoil.'+station+'_profile"]').inputValue();
  const ready=station=>page.waitForFunction(station=>!document.getElementById('airfoil-'+station+'-use').disabled,station);
  const tipOriginal=await value('tip');
  await page.locator('#airfoil-tip-browse').click();await ready('tip');
  assert.match(await page.locator('#airfoil-tip-card .airfoil-candidate strong').textContent(),/new.dat/);
  assert.equal(await value('tip'),tipOriginal);assert.deepEqual(await page.evaluate(()=>edits),[]);
  assert.equal(await page.evaluate(()=>{editor.assertValidDraft();return true;}),true);
  assert.equal(await page.locator('#airfoil-tip-use').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(22, 116, 200)');
  await page.locator('#airfoil-tip-card').screenshot({path:path.join(out,'uiuc-candidate-preview.png')});
  await page.locator('#airfoil-tip-cancel').click();assert.equal(await value('tip'),tipOriginal);
  assert.equal(await page.locator('#airfoil-tip-card .airfoil-selected').isVisible(),true);
  assert.match(await page.locator('#airfoil-tip-card .airfoil-selected strong').textContent(),/original.dat/);
  checks.push('Candidate preview and blue Use button appear immediately; Cancel preserves the committed profile and generation validation');
  await page.locator('[id="p-airfoil.root_source"]').selectOption('uiuc');await ready('root');
  await page.locator('#airfoil-root-cancel').click();
  assert.equal(await page.locator('[id="p-airfoil.root_source"]').inputValue(),'naca');assert.equal(await value('root'),'');assert.equal(await page.locator('[id="p-airfoil.root"]').inputValue(),'NACA2412');
  assert.match(await page.locator('#airfoil-root-card .airfoil-selected strong').textContent(),/NACA 2412/);
  checks.push('Cancel after entering UIUC restores the original NACA source, code and preview');
  await page.locator('[id="p-airfoil.root_source"]').selectOption('file');
  await page.locator('#airfoil-root-file').setInputFiles({name:'original.dat',mimeType:'text/plain',buffer:Buffer.from('Local\n1 0\n.75 .04\n.5 .06\n.25 .05\n0 0\n.25 -.03\n.5 -.04\n.75 -.02\n1 0\n')});
  await page.waitForFunction(()=>document.querySelector('#airfoil-root-card .airfoil-local-file [role=status]').textContent.includes('Embedded'));
  const fileOriginal=await value('root');await page.locator('[id="p-airfoil.root_source"]').selectOption('uiuc');await ready('root');
  await page.locator('#airfoil-root-search').press('Escape');assert.equal(await value('root'),fileOriginal);assert.equal(await page.locator('[id="p-airfoil.root_source"]').inputValue(),'file');
  checks.push('Escape restores an original embedded local file without losing provenance');
  await page.locator('#airfoil-tip-browse').click();await ready('tip');
  const slow=page.waitForResponse(response=>response.url().includes('profile?id=slow.dat'));
  await page.locator('#airfoil-tip-choices').selectOption('slow.dat');assert.equal(await page.locator('#airfoil-tip-use').isDisabled(),true);
  await page.locator('#airfoil-tip-cancel').click();await slow;
  assert.equal(await value('tip'),tipOriginal);assert.equal(await page.locator('#airfoil-tip-card .airfoil-candidate').isHidden(),true);
  checks.push('Cancel while loading invalidates the abandoned asynchronous preview');
  await page.locator('#airfoil-tip-browse').click();await ready('tip');
  const late=page.waitForResponse(response=>response.url().includes('profile?id=slow.dat'));
  await page.locator('#airfoil-tip-choices').selectOption('slow.dat');await page.locator('#airfoil-tip-choices').selectOption('new.dat');await ready('tip');await late;
  assert.match(await page.locator('#airfoil-tip-card .airfoil-candidate strong').textContent(),/new.dat/);assert.equal(await value('tip'),tipOriginal);
  await page.locator('#airfoil-tip-choices').selectOption('broken.dat');await page.waitForFunction(()=>document.querySelector('#airfoil-tip-card .airfoil-browser [role=status]').textContent.includes('cross'));
  assert.equal(await page.locator('#airfoil-tip-use').isDisabled(),true);assert.equal(await value('tip'),tipOriginal);assert.equal(await page.evaluate(()=>{editor.assertValidDraft();return true;}),true);
  checks.push('Rapid selections reject stale responses; invalid preview geometry leaves the original model valid');
  await page.locator('#airfoil-tip-choices').selectOption('new.dat');await ready('tip');const beforeEdits=await page.evaluate(()=>edits.length);
  await page.locator('#airfoil-tip-use').click();assert.equal(JSON.parse(await value('tip')).id,'new.dat');assert.equal(await page.evaluate(()=>edits.length),beforeEdits+1);
  assert.equal(await page.locator('#airfoil-tip-card .airfoil-browser').isHidden(),true);
  assert.match(await page.locator('#airfoil-tip-card .airfoil-selected strong').textContent(),/new.dat/);
  checks.push('Use commits only the validated candidate exactly once and closes the chooser');
  await page.locator('#airfoil-tip-browse').click();await ready('tip');await page.evaluate(()=>{locked=true;document.getElementById('host').dispatchEvent(new Event('parameterlockchange'));});
  assert.equal(await page.locator('#airfoil-tip-use').isDisabled(),true);assert.equal(await page.locator('#airfoil-tip-cancel').isDisabled(),true);
  assert.equal(JSON.parse(await value('tip')).id,'new.dat');checks.push('Planform lock cancels candidate use and retains the committed profile');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'airfoil_candidate.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'airfoil-candidate-failure.png'),fullPage:true});throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
