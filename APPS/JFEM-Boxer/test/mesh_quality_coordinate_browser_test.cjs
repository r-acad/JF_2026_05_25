'use strict';
// node mesh_quality_coordinate_browser_test.cjs OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage();
 try{
  await page.setContent('<main class="workspace-live"></main>');await page.addScriptTag({path:path.resolve(__dirname,'../web/mesh_quality_review.js')});
  await page.evaluate(()=>{
   Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{window.copiedEta=text;}}});
   window.review=WingMeshQualityReview.connect({document,onLocate:point=>{window.locatedPoint=point;}});
   review.update({mesh_quality:{warning_element_count:2,issues:[{component:'Front spar web',rib_start:11,rib_end:12,count:2,element_ids:[1,2],minimum_corner_deg:4,maximum_corner_deg:120,maximum_edge_ratio:12,nearby_controls:[{key:'box.front_spar_points',row:2,nearest_rib:11,label:'Front spar point2',rib_eta:.4185798815789473,distance_mm:17.464,menu:'Structure / Spars'}]}]}});
  });
  await page.locator('#btn-mesh-quality').click();assert.equal(await page.locator('#mesh-quality-dialog code').innerText(),'0.4186');assert(!(await page.locator('#mesh-quality-dialog').innerText()).includes('4185798815789473'));
  await page.getByRole('button',{name:'Copy exact η',exact:true}).click();assert.equal(await page.evaluate(()=>copiedEta),'0.4185798815789473');
  await page.getByRole('button',{name:'Open Structure / Spars',exact:true}).click();assert.equal(await page.evaluate(()=>locatedPoint.rib_eta),.4185798815789473);assert.equal(await page.locator('#mesh-quality-dialog').isVisible(),false);
  const summary={passed:true,checks:['Readable four-significant-figure eta labels never replace exact diagnostic coordinates.','Copy exact eta and editor navigation preserve the full target station.']};fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
