'use strict';
// node component_mass_report_browser_test.cjs OUTPUT PLAYWRIGHT_MODULE WEIGHTS_JSON
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outPath,playwrightPath,fixturePath]=process.argv.slice(2);
const out=path.resolve(outPath),{chromium}=require(playwrightPath);
const web=path.resolve(__dirname,'../web'),fixture=JSON.parse(fs.readFileSync(fixturePath,'utf8'));

(async()=>{
  fs.mkdirSync(out,{recursive:true});
  const browser=await chromium.launch({channel:'chrome',headless:true});
  const page=await browser.newPage({viewport:{width:720,height:1100}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  try{
    await page.setContent('<body style="font:14px system-ui;background:#162432;color:white"><main style="width:440px;margin:auto"><h1>Mass properties</h1><div id="weights-report"></div></main></body>');
    for(const file of ['numbers.js','weights.js','summary_export.js'])await page.addScriptTag({path:path.join(web,file)});
    await page.addStyleTag({path:path.join(web,'weights.css')});
    await page.evaluate(data=>{
      window.weights=WingWeights.create(document.getElementById('weights-report'));
      weights.update(data);
    },fixture);

    const actual=await page.evaluate(()=>{
      const host=document.getElementById('weights-report');
      const values=selector=>Array.from(host.querySelectorAll(selector+' td'),node=>Number(node.dataset.value));
      const exports={};
      for(const format of ['csv','md','html']){
        exports[format]=WingSummaryExport.serialize(WingSummaryExport.collect(host,{title:'Mass properties'}),format);
      }
      return{
        leading:values('.weights-totals [data-component="leading_edge"]'),
        controls:values('.weights-totals [data-component="control_surfaces"]'),
        dry:values('.weights-centers [data-component="structure"]'),
        nose:values('.weights-centers [data-component="leading_edge_structure"]'),
        movable:values('.weights-centers [data-component="movable_surfaces"]'),
        loaded:values('.weights-centers [data-component="loaded"]'),
        inertia:values('.weights-inertia [data-component="loaded"]'),
        exports,
        centersFit:host.querySelector('.weights-centers').getBoundingClientRect().right<=host.getBoundingClientRect().right+1,
        horizontalOverflow:document.documentElement.scrollWidth>window.innerWidth
      };
    });
    const properties=Object.fromEntries(fixture.mass_properties.map(row=>[row.id,row]));
    assert.deepEqual(actual.leading,[fixture.totals.leading_edge_mass_kg,fixture.totals.leading_edge_weight_N]);
    assert.deepEqual(actual.controls,[fixture.totals.control_surface_mass_kg,fixture.totals.control_surface_weight_N]);
    for(const[id,key]of [['structure','dry'],['leading_edge_structure','nose'],['movable_surfaces','movable'],['loaded','loaded']]){
      assert.deepEqual(actual[key],[properties[id].mass_kg,...properties[id].center_of_gravity_m]);
    }
    const tensor=properties.loaded.inertia_kg_m2;
    assert.deepEqual(actual.inertia,[tensor[0][0],tensor[1][1],tensor[2][2],tensor[0][1],tensor[0][2],tensor[1][2]]);
    for(const[format,content]of Object.entries(actual.exports)){
      assert.match(content,/Of which leading-edge structure/);
      assert.match(content,/Of which control-surface structures/);
      assert.match(content,/Centers of gravity/);
      assert.match(content,/CG X/);
      assert.match(content,/Inertia about each center of gravity/);
      fs.writeFileSync(path.join(out,'mass-properties.'+format),content);
    }
    assert.equal(actual.horizontalOverflow,false);
    assert.equal(actual.centersFit,true);
    assert.deepEqual(errors,[]);
    await page.locator('details').filter({has:page.locator('summary', {hasText:'Inertia about each center'})}).evaluate(node=>node.open=true);
    await page.screenshot({path:path.join(out,'component-mass-properties.png'),fullPage:true});
    fs.writeFileSync(path.join(out,'browser_summary.json'),JSON.stringify({passed:true,source:'Generated LE, control, fuel and engine fixture',coverage:['Structural subtotals','Component centers','Loaded center','Loaded inertia tensor','CSV/Markdown/HTML exports','Compact pane layout'],pageErrors:errors},null,2));
    console.log('PASS leading-edge/control subtotals, exact CG/inertia fields, three exported formats and compact pane layout');
  }finally{
    await browser.close();
  }
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
