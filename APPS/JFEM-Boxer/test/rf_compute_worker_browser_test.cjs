'use strict';
// Synthetic fixed-load oracle: real Worker transport, provenance and cancellation.
// node rf_compute_worker_browser_test.cjs OUTPUT_DIR [PLAYWRIGHT_MODULE]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [output,modulePath='playwright']=process.argv.slice(2),out=path.resolve(output),web=path.resolve(__dirname,'../web');
const {chromium}=require(modulePath),origin='http://127.0.0.1:43996';
const scripts=['color_scales','material_allowables','euler_column_data','stringer_blade_data','skin_buckling_data','component_buckling_data','minimum_rf_data','stress_report_data','rf_incremental','rf_compute_client'];
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,channel:process.env.CHROME_PATH?undefined:'chrome',executablePath:process.env.CHROME_PATH||undefined});
 try{
  const context=await browser.newContext(),page=await context.newPage(),errors=[];
  page.on('pageerror',error=>errors.push(error.stack));
  await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;return p==='/'?route.fulfill({contentType:'text/html',body:'<!doctype html><title>RF Worker regression</title>'+scripts.map(f=>'<script src="'+f+'.js"></script>').join('')}):route.fulfill({path:path.join(web,p)});});
  await page.goto(origin+'/');
  const result=await page.evaluate(async()=>{
   const p=t=>({type:'PSHELL',material_id:1,material:{id:1,type:'MAT1'},thickness_m:t}),element=(pid,t)=>({group:{pid,kind:'quad',name:'Synthetic P'+pid,properties:p(t)}}),vm=x=>({stress:{z1:{von_mises:x},z2:{von_mises:x}}});
   const base={generated:false,studyEpoch:1,meshIdentity:'fixed',signature:'base',failureMode:'minimum_rf',caseId:'all',method:'maximum',percentile:95,allowables:[{material_id:1,mode:'stress',stress:100}],elements:new Map([[1,element(1,.001)],[2,element(2,.001)]]),cases:new Map([[1,{analysis:'SOL101',matches:true,available:true,status:'complete',static:{},signature:'base',meshIdentity:'fixed',elementResults:{1:vm(10),2:vm(20)}}]]),eulerColumns:[],stringerBlades:[],skinBucklingPanels:[],componentBuckling:{web_panels:[],columns:[],blades:[]}};
   // Runtime functions must never enter structured-clone messages.
   base.elements.get(1).runtimeMesh={notCloneable(){}};
   const compute=WingRFCompute.create();
   try{
    const initial=await compute.evaluate(base);
    const edited={...base,estimated:true,signature:'edited',elements:new Map([[1,element(1,.002)],[2,base.elements.get(2)]]),cases:new Map([[1,{...base.cases.get(1),signature:'edited',elementResults:{1:vm(5),2:vm(20)}}]])};
    const updated=await compute.evaluate(edited,initial,base),oracle=WingStressReportData.build(edited);
    const superseded=compute.evaluate(base).then(()=>false,error=>error.name==='AbortError');
    const newest=await compute.evaluate(edited,updated,edited);
    return{initial:initial.rows.map(r=>[r.pid,r.reserveFactor]),actual:updated.rows.map(r=>[r.pid,r.reserveFactor,r.complete]),expected:oracle.rows.map(r=>[r.pid,r.reserveFactor,r.complete]),incremental:updated.incremental,current:WingStressReportData.currentContext(updated,edited),cancelled:await superseded,newest:newest.rows.map(r=>[r.pid,r.reserveFactor])};
   }finally{compute.destroy();}
  });
  assert.deepEqual(result.initial,[[1,10],[2,5]]);assert.deepEqual(result.actual,result.expected);
  assert.deepEqual(result.incremental.properties,[1]);assert.equal(result.incremental.modes.von_mises,1);
  assert(result.incremental.reusedRows>0&&result.current&&result.cancelled);
  assert.deepEqual(result.newest,[[1,20],[2,5]]);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,synthetic:true,result,errors},null,2));
  console.log('PASS RF Worker: full and scoped oracles, runtime-object isolation, freshness and latest-request cancellation.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
