'use strict';
// Replay solved VLM panels in the actual app using isolated HTTP fixtures.
// node aero_case_difference_browser_test.cjs OUT BOOTSTRAP_FIXTURE RESULT_JSON PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,resultArg,playwrightArg,browserArg]=process.argv.slice(2);
const out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web');
const {chromium}=require(path.resolve(playwrightArg)),native=JSON.parse(fs.readFileSync(resultArg,'utf8'));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
assert(native.cases.length>=2&&!native.mesh_only,'Provide at least two solved VLM conditions.');

(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),
  args:['--use-angle=swiftshader','--enable-unsafe-swiftshader','--disable-gpu-compositing']});
 const page=await browser.newPage({viewport:{width:1600,height:1000}}),checks=[],errors=[];
 let signature='',servedCases=native.cases;
 page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));
 const pane=(key,p=page)=>p.locator('[data-aero-pane="'+key+'"]').click();
 const close=(p=page)=>p.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();
 const snapshot=p=>p.evaluate(()=>{
  // A detached viewport shares app state with its opener.
  const app=window.opener||window,c=app.eval('state').aerodynamicStudy.displayedCase;
  const canvas=document.querySelector('.aero-canvas');
  const scene=app.BABYLON.Engine.Instances.flatMap(e=>e.scenes).find(s=>s.getEngine().getRenderingCanvas()===canvas);
  return{comparison:document.querySelector('.aero-case-controls').dataset.difference,
   selected:[document.querySelector('[aria-label="Case A"]').value,document.querySelector('[aria-label="Subtract case B"]').value],
   enabled:document.querySelector('[aria-label="Show case difference A minus B"]').checked,
   difference:c?.difference||null,force:c?.force_N,
   panels:c?.panels.map(p=>({force:p.force_N,pressure:p.pressure_vector_Pa,
    scalars:['delta_cp','delta_pressure_Pa','circulation_m2_s','speed_ratio'].map(k=>p[k])})),
   arrows:scene?.meshes.filter(m=>m.metadata?.aerodynamicLoadArrows).length||0,
   geometry:Array.from(scene?.getMeshByName('independent-aero-panels')?.getVerticesData('position')||[]),
   camera:scene?{alpha:scene.activeCamera.alpha,beta:scene.activeCamera.beta,radius:scene.activeCamera.radius,target:scene.activeCamera.target.asArray()}:null,
   legendHidden:document.querySelector('.aero-vector-legend').hidden};
 });
 const assertZero=s=>{
  assert.equal(s.comparison,'true','Self-comparison must remain active instead of showing absolute case loads.');
  assert(s.enabled&&s.difference);assert.deepEqual(s.force,[0,0,0]);
  for(const p of s.panels){assert(p.force.every(x=>x===0));assert(p.pressure.every(x=>x===0));assert(p.scalars.every(x=>x===0));}
  assert.equal(s.arrows,0,'Previously rendered load arrows must be disposed.');assert(s.legendHidden);
 };
 try{
  await page.route('http://127.0.0.1:43986/**',async route=>{
   const url=new URL(route.request().url());
   if(url.pathname==='/api/input')return route.fulfill({json:schema});
   if(url.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
   if(['/api/generate','/api/prepare_workspace'].includes(url.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
   if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(url.pathname==='/api/aerodynamics/run'){
    signature=route.request().postDataJSON().signature;
    return route.fulfill({json:{id:'self-difference-regression'}});
   }
   if(url.pathname==='/api/aerodynamics/status')return route.fulfill({json:{state:'done',seconds:0}});
   if(url.pathname==='/api/aerodynamics/results')return route.fulfill({json:{...native,cases:servedCases,signature}});
   if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated aerodynamic comparison fixture'}});
   const file=url.pathname.startsWith('/shared/')?path.join(web,'../..',url.pathname.slice('/shared/'.length)):
    path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
  });
  await page.goto('http://127.0.0.1:43986/');await page.waitForFunction(()=>state.schema?.length);
  await page.evaluate(()=>{
   for(const d of document.querySelectorAll('dialog[open]'))d.close();
   state.autosave?.destroy();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
   cancelAutoMeshTimer();activateWorkspaceTab('aerostudy');
  });
  await page.locator('[data-action=run]').click();await page.waitForFunction(()=>state.aerodynamicStudy.result&&!state.aerodynamicStudy.busy);
  await page.getByRole('button',{name:'Close aerodynamic status',exact:true}).click();
  if(await page.locator('.aero-drawer').isVisible())await close();
  const raw=await page.evaluate(()=>JSON.stringify(state.aerodynamicStudy.result));
  await pane('display');await page.getByLabel('Arrow magnitude',{exact:true}).selectOption('force');await close();
  const initial=await snapshot(page);assert(initial.arrows>0,'The solved source must initially have nonzero arrows.');
  await page.getByLabel('Show case difference A minus B').check();
  const self=await snapshot(page);assert.deepEqual(self.selected,['0','0'],'Enabling subtraction must preserve the chosen B case.');assertZero(self);
  assert.deepEqual(self.geometry,initial.geometry);assert.deepEqual(self.camera,initial.camera);
  checks.push('Enabling A minus A preserves both selections and yields exact zero fields with no stale force arrows.');
  await pane('display');await page.getByLabel('Arrow magnitude',{exact:true}).selectOption('pressure');await close();assertZero(await snapshot(page));
  checks.push('Force and force-per-area vector modes both show no load arrows for self-subtraction.');

  await page.getByLabel('Subtract case B',{exact:true}).selectOption('1');
  const nonzero=await snapshot(page);assert(nonzero.arrows>0);assert(nonzero.panels.some(p=>p.force.some(x=>x!==0)));
  await page.getByLabel('Case A',{exact:true}).selectOption('1');assertZero(await snapshot(page));
  await page.getByLabel('Show case difference A minus B').uncheck();assert((await snapshot(page)).arrows>0);
  await page.getByLabel('Show case difference A minus B').check();assertZero(await snapshot(page));
  assert.equal(await page.evaluate(()=>JSON.stringify(state.aerodynamicStudy.result)),raw);
  checks.push('Switching from A minus B to B minus B and toggling subtraction clears arrows and preserves every solved result.');

  await pane('exports');const csvDownload=page.waitForEvent('download');await page.locator('[data-action=panels]').click();
  await(await csvDownload).saveAs(path.join(out,'self-difference.csv'));await close();
  const rows=fs.readFileSync(path.join(out,'self-difference.csv'),'utf8').trim().split(/\r?\n/).map(row=>row.split(',').map(v=>v.slice(1,-1)));
  const headers=rows.shift();for(const row of rows){const record=Object.fromEntries(headers.map((h,i)=>[h,row[i]]));
   assert.equal(record.operation,'A - B');assert.equal(record.case_A,record.case_B);
   for(const key of ['Fx_N','Fy_N','Fz_N','pressure_x_Pa','pressure_y_Pa','pressure_z_Pa','delta_cp','delta_pressure_Pa','speed_ratio','Gamma_m2_s'])assert.equal(Number(record[key]),0,key);
  }
  await pane('display');const svgDownload=page.waitForEvent('download');await page.locator('[data-action=view-svg]').click();
  await(await svgDownload).saveAs(path.join(out,'self-difference.svg'));await close();
  assert(!fs.readFileSync(path.join(out,'self-difference.svg'),'utf8').includes('data-arrow-quantity='));
  checks.push('CSV exports exact zero differences and SVG contains no load-vector polylines.');
  await page.screenshot({path:path.join(out,'self-difference.png')});

  const popupEvent=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const popup=await popupEvent;
  popup.on('pageerror',e=>errors.push(e.message));await popup.locator('.aero-canvas').waitFor();assertZero(await snapshot(popup));
  await popup.locator('[data-action=detach]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);assertZero(await snapshot(page));
  checks.push('The self-comparison survives transfer to a detached viewport and return.');

  servedCases=[native.cases[0]];await page.locator('[data-action=run]').click();
  await page.waitForFunction(()=>state.aerodynamicStudy.result?.cases.length===1&&!state.aerodynamicStudy.busy);
  await page.getByRole('button',{name:'Close aerodynamic status',exact:true}).click();
  const toggle=page.getByLabel('Show case difference A minus B');assert(await toggle.isEnabled());await toggle.check();assertZero(await snapshot(page));
  checks.push('A single solved condition also supports a valid zero self-comparison.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));
  console.log(JSON.stringify({passed:true,checks}));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));
  await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});throw error;
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
