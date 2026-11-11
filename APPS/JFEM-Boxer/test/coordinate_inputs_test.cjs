'use strict';
const assert=require('node:assert/strict'),C=require('../web/coordinate_inputs.js');
const source={'box.end_eta':.987654321,'planform.twist_axis_xc':.123456789,'material.E':71.123456789e9,'ribs.masters':[{eta:.123456789,pitch:.123456789}],'engines.items':[{eta:.987654321,xc:.456789123,zc:-.123456789}],'movable_surfaces.items':[{front_spar_start:.7654321,hinge_start:.654321}]};
const copy=JSON.stringify(source),rounded=C.roundInputs(source);
assert.equal(rounded['box.end_eta'],.9877);assert.equal(rounded['planform.twist_axis_xc'],.1235);assert.equal(rounded['material.E'],source['material.E']);assert.equal(rounded['ribs.masters'][0].pitch,.123456789);assert.equal(rounded['ribs.masters'][0].eta,.1235);assert.equal(rounded['engines.items'][0].zc,-.1235);assert.equal(rounded['movable_surfaces.items'][0].hinge_start,.6543);assert.equal(JSON.stringify(source),copy);
assert.deepEqual(C.roundInputs([['eta',.123456789],['pitch',.123456789]]),[['eta',.1235],['pitch',.123456789]]);
for(const key of ['eta','eta_start','end_eta','x_c','z/c','dxc','x_over_c'])if(key!=='z/c')assert(C.isKey(key),key);
const N=require('../web/numeric_inputs.js'),labels=require('../web/numbers.js');
for(const[value,text]of[[.337,'0.337'],[.3371234,'0.3371'],[.000123456,'0.0001235'],[-.987654,'-0.9877'],[0,'0'],[1,'1']]){
 assert.equal(N.format(value,{coordinate:true}),text);assert.equal(labels.coordinate(value),text);
}
console.log('PASS Four significant figures and plain decimal coordinate labels; unrelated dimensions and constants retain their precision policy.');
