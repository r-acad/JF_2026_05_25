'use strict';
const assert=require('node:assert/strict');
const summary=require('../web/summary_export.js');
function parseCSV(source){
  const rows=[];let row=[],cell='',quoted=false;
  for(let i=source.charCodeAt(0)===0xfeff?1:0;i<source.length;i++){
    const c=source[i];if(c==='"'){if(quoted&&source[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}
    else if(c===','&&!quoted){row.push(cell);cell='';}
    else if(c==='\r'&&!quoted&&source[i+1]==='\n'){row.push(cell);rows.push(row);row=[];cell='';i++;}
    else cell+=c;
  }return rows;
}
const report={title:'Mass properties',model:'Box <A> | "test"',source:'changes.wingfem.json',caseLabel:'Case 2 · Cruise',generatedAt:'2026-10-19T10:11:12.000Z',stale:true,
  blocks:[{type:'paragraph',text:'Mass is a subtotal. Do not add it again.'},{type:'heading',text:'Fuel by physical rib bay'},
    {type:'table',rows:[{header:true,cells:[{text:'Component'},{text:'Mass (kg)'},{text:'Weight (N)'}]},
      {cells:[{text:'Rib, "A"'},{text:'-1.2345e-7'},{text:'12.5'}]},
      {cells:[{text:'=HYPERLINK("private")'},{text:'0'},{text:'Unavailable'}]}]},
    {type:'heading',text:'Calculation basis and element counts'},
    {type:'paragraph',text:'Line 1\nLine 2 | _note_ `code` <script>alert("bad")</script>'}]};
const csv=summary.csv(report),rows=parseCSV(csv);
assert.equal(csv.charCodeAt(0),0xfeff);assert(csv.endsWith('\r\n'));
assert.deepEqual(rows.find(row=>row[0]==='Model'),['Model',report.model]);
assert.deepEqual(rows.find(row=>row[0]==='Rib, "A"'),['Rib, "A"','-1.2345e-7','12.5']);
assert.deepEqual(rows.find(row=>row[0].startsWith("'=HYPERLINK")),["'=HYPERLINK(\"private\")",'0','Unavailable']);
assert(rows.some(row=>row.includes('Mass (kg)')));assert(rows.some(row=>row[0]==='Fuel by physical rib bay'));
assert(rows.some(row=>row[0].includes('Line 1\nLine 2')));assert(rows.some(row=>row[1]?.includes('last-created model')));
console.log('1: CSV round-trips units, metadata, commas, quotes and newlines; spreadsheet formulas are inert.');
const md=summary.md(report);assert(md.startsWith('# Mass properties\n'));assert(md.includes('**Load case:** Case 2 · Cruise'));
assert(md.includes('| Component | Mass (kg) | Weight (N) |'));assert(md.includes('## Fuel by physical rib bay'));
assert(md.includes('\\| \\_note\\_ \\`code\\` \\<script\\>'));assert(md.includes('Line 1<br>Line 2'));
assert(!md.includes('\n<script>'));assert(md.endsWith('\n'));
console.log('2: Markdown retains table headers and units and escapes model labels and report text.');
const html=summary.html(report);assert(html.startsWith('<!doctype html>'));assert(html.includes('<meta charset="utf-8">'));
assert(html.includes('&lt;script&gt;alert(&quot;bad&quot;)&lt;/script&gt;'));assert(!html.includes('<script>'));assert(!html.includes('src='));
assert(html.includes('<th>Mass (kg)</th>'));assert(html.includes('<h2>Calculation basis and element counts</h2>'));
assert(html.includes('Inputs changed; this summary describes the last-created model.'));
assert(html.includes('Box &lt;A&gt; | &quot;test&quot;'));
console.log('3: Standalone HTML has no script or external resources and preserves report structure.');
const general={title:'General model summary',model:'Basic',blocks:[{type:'table',rows:[{cells:[{text:'Shells'},{text:'120'}]},{cells:[{text:'Length'},{text:'2.3 m'}]}]}]};
assert(summary.md(general).includes('| Item | Value |'));assert(!summary.csv(general).includes('Load case'));
assert.equal(summary.filename(report,'csv'),'Box_A_test_Mass_properties_Case_2_Cruise.csv');
assert.equal(summary.filename({...report,model:'../.. /<>',caseLabel:''},'html'),'.._.._Mass_properties.html');
assert.equal(summary.serialize(report,'html'),summary.html(report));assert.throws(()=>summary.serialize(report,'pdf'),/Unknown/);
console.log('4: Key/value summaries and absent load cases stay truthful; format dispatch and filenames are deterministic.');
