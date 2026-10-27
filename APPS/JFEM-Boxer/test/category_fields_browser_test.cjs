'use strict';
// Rendering acceptance only: synthetic category labels on an actual app mesh.
// node category_fields_browser_test.cjs URL OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[url,out,modulePath='playwright']=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1700,height:1050}});
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.data?.nodes?.count&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:240000});
  const result=await page.evaluate(()=>{
   document.getElementById('auto-save').checked=false;state.autosave?.destroy();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
   const defaultEfficiency=state.defaults['fuel.fill_efficiency'];
   const pids=[...new Set([...state.elements.values()].map(e=>e.group?.pid).filter(Boolean))];
   const includedCases=Array.from({length:6},(_,i)=>({caseKey:(i+1)+':default',caseId:i+1,solution:101,label:'Display check '+(i+1)+' · SOL101'}));
   const rows=pids.map((pid,i)=>({pid,rowKey:'P'+pid,label:'P'+pid,complete:true,coverage:{recovered:1,total:1},reserveFactor:1.2,
    envelopeCaseKey:includedCases[i%6].caseKey,combined:{governingMode:'von_mises',governingModeLabel:'Von Mises stress',governingScope:'Full property P'+pid,sentinel:false},caseResults:[]}));
   const report={failureMode:'minimum_rf',rows,includedCases,excludedCases:[],missingCases:[]};
   const contour=WingRFFieldData.project({elements:state.elements},report,{kind:'critical_case'});
   contour.caseLabel='Synthetic category rendering check — no RF analysis';
   state.propertyDisplay?.setEnabled(false);state.rfField={request:{kind:'critical_case',onlyBelowOne:false},contour,message:'Rendering check',previous:{animate:false,resultsHidden:true}};
   document.getElementById('animate').checked=false;applyContour();state.scene.render();
   const misses=[];for(const mesh of state.shellMeshes){const c=mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind);if(!c)continue;
    for(let e=0;e<mesh.elementIds.length;e++){const want=contour.colorById.get(mesh.elementIds[e])||[.32,.36,.41];for(let k=0;k<3;k++)if(Math.abs(c[e*mesh.nodesPerElement*4+k]-want[k])>2e-6)misses.push(mesh.elementIds[e]);}}
   const propertyCategories=Array.from({length:12},(_,i)=>({value:i,label:'P'+(i+1)})),property={categories:propertyCategories,min:0,max:11,kind:'properties'};
   const a=propertyCategories.map(c=>contourRGB(property,c.value));WingLegends.setPalette('properties','grayscale');const b=propertyCategories.map(c=>contourRGB(property,c.value));
   const filtered=WingRFFieldData.project({elements:state.elements},{...report,rows:rows.filter(r=>r.envelopeCaseKey==='3:default'),includedCases:[includedCases[2]]},{kind:'critical_case'});
   return{defaultEfficiency,colors:contour.categories,legend:propertyLegendCategories(contour),misses,propertyBefore:a,propertyAfter:b,
    filteredColor:filtered.categories[0]?.color,fullColor:contour.categories.find(c=>c.caseKey==='3:default')?.color,webgpu:state.engine.isWebGPU};
  });
  assert(result.webgpu);assert.equal(new Set(result.colors.map(c=>JSON.stringify(c.color))).size,6);assert.deepEqual(result.misses,[]);
  assert.deepEqual(result.propertyBefore,result.propertyAfter);assert.equal(new Set(result.propertyBefore.map(JSON.stringify)).size,12);assert.deepEqual(result.filteredColor,result.fullColor);
  for(let i=0;i<result.colors.length;i++)assert.equal(result.legend[i].color,'#'+result.colors[i].color.map(v=>Math.round(v*255).toString(16).padStart(2,'0')).join(''));
  assert.equal(result.defaultEfficiency,0.9);assert.deepEqual(errors,[]);
  checks.push('Six distinct case colors reach actual shell vertex buffers and match discrete legend swatches.','Property IDs use twelve distinct colors unaffected by a continuous grayscale selection.','Load case retains its color when filtered.','New fill-efficiency schema default is 0.9.');
  await page.screenshot({path:path.join(out,'categorical-field-webgpu.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,result},null,2));console.log(checks.join('\n'));
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
