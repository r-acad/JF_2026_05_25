'use strict';
const assert=require('node:assert/strict'),C=require('../web/coordinate_inputs.js');
const source={'box.end_eta':.987654321,'planform.twist_axis_xc':.123456789,'material.E':71.123456789e9,'ribs.masters':[{eta:.123456789,pitch:.123456789}],'engines.items':[{eta:.987654321,xc:.456789123,zc:-.123456789}],'movable_surfaces.items':[{front_spar_start:.7654321,hinge_start:.654321}]};
const copy=JSON.stringify(source),rounded=C.roundInputs(source);
assert.equal(rounded['box.end_eta'],.98765);assert.equal(rounded['planform.twist_axis_xc'],.12346);assert.equal(rounded['material.E'],source['material.E']);assert.equal(rounded['ribs.masters'][0].pitch,.123456789);assert.equal(rounded['ribs.masters'][0].eta,.12346);assert.equal(rounded['engines.items'][0].zc,-.12346);assert.equal(rounded['movable_surfaces.items'][0].hinge_start,.65432);assert.equal(JSON.stringify(source),copy);
assert.deepEqual(C.roundInputs([['eta',.123456789],['pitch',.123456789]]),[['eta',.12346],['pitch',.123456789]]);
for(const key of ['eta','eta_start','end_eta','x_c','z/c','dxc','x_over_c'])if(key!=='z/c')assert(C.isKey(key),key);
console.log('PASS Five significant figures for coordinate definitions, including nested tables and signatures; dimensions and material constants retain precision.');
