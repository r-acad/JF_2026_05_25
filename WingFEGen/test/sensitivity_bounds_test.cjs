'use strict';
const assert=require('node:assert/strict'),T=require('../web/sensitivity_table_data.js'),M=require('../web/sensitivity_map.js');
const row=(n,d,extra={})=>({id:'properties.panels#upper:bay'+n+':stringer1:segment1#skin#thickness',panel_key:'upper:bay'+n+':stringer1:segment1',value:.002,unit:'m',derivative_unit:'m / m',derivative:d,status:'ok',field_key:'shell.thickness',...extra});
const rows=[row(1,-8),row(2,-2),row(3,-5),row(4,-100,{status:'failed'}),row(5,NaN),row(6,400,{panel_key:'lower:bay6:stringer1:segment1',id:'properties.panels#lower:bay6:stringer1:segment1#skin#thickness'}),row(7,900,{field_key:'section.height',id:'properties.panels#upper:bay7:stringer1:segment1#stringer#height'})];
const snapshot={result:{baseline:{value:2,unit:'m'},rows}},options={mode:'panels',skin:'upper',field:'shell.thickness|m / m',quantity:'derivative'};
let s=T.colorScales(snapshot,options).get('m / m');assert.deepEqual(s,{unit:'m / m',min:-8,max:-2,count:3});
assert.notEqual(T.valueColor(-8,s),T.valueColor(-2,s));assert.equal(T.valueColor(-100,s),T.valueColor(-8,s));assert.equal(T.valueColor(NaN,s),null);
assert.deepEqual(T.colorStops(s).map(v=>v.value),[-8,-5,-2]);assert.deepEqual(T.colorStops(s).map(v=>v.position),[0,.5,1]);
s=T.colorScales(snapshot,{...options,quantity:'normalized'}).get('dimensionless');assert.deepEqual(s,{unit:'dimensionless',min:-.008,max:-.002,count:3});
assert.equal(T.colorScales({...snapshot,result:{...snapshot.result,baseline:{value:0,unit:'m'}}},{...options,quantity:'normalized'}).size,0);
s=T.colorScales(snapshot,{...options,filter:'bay2:'}).get('m / m');assert.deepEqual(s,{unit:'m / m',min:-2,max:-2,count:1});assert.equal(T.colorStops(s).length,1);assert(T.valueColor(-2,s));
assert.equal(T.colorScales(snapshot,{...options,filter:'absent'}).size,0);
const mixed={result:{baseline:{value:2,unit:'m'},rows:[row(1,-2),row(2,6),row(3,0),row(4,1000,{derivative_unit:'m / GPa'}),row(5,9999,{status:'unavailable'})]}};
const ranges=T.colorScales(mixed,{mode:'all',quantity:'derivative'});assert.equal(ranges.size,2);s=ranges.get('m / m');assert.deepEqual(s,{unit:'m / m',min:-2,max:6,count:3});assert.equal(T.colorStops(s)[1].position,.25);assert.equal(T.colorStops(s)[1].value,0);
assert.equal(T.valueColor(0,s),'rgb(242, 243, 239)');assert.deepEqual(T.colorStops({min:2,max:6}).map(v=>v.value),[2,4,6]);assert.equal(T.valueColor(0,{min:0,max:0}),'rgb(242, 243, 239)');
const variables=Object.fromEntries(rows.map((r,i)=>[r.id,{eids:[i+1]}])),map=M.buildField(snapshot.result,{variables},options.field,'derivative');assert.equal(map.min,-8);assert.equal(map.max,400);assert(!map.byId.has(4));assert(!map.byId.has(5));assert(!map.byId.has(7));
assert.deepEqual(M.valueRange([-5,Infinity,NaN,undefined,-2]),{min:-5,max:-2,count:2});assert.deepEqual(M.valueRange([]),{min:0,max:0,count:0});
const constant=M.build(snapshot.result,rows[0],{variables},1,'absolute');assert.equal(constant.min,constant.effect.deltaResponse);assert.equal(constant.max,constant.min);
// Scope ownership excludes even finite extreme derivatives when a local panel
// supersedes the global default on all of its elements.
const global={...row(8,-9000),id:'shared',panel_key:undefined},local=row(9,-3),r={...snapshot.result,rows:[global,local]};
const owned=M.buildField(r,{variables:{shared:{eids:[1]},[local.id]:{eids:[1]}}},options.field,'derivative');assert.equal(owned.min,-3);assert.equal(owned.max,-3);
console.log('Sensitivity bounds: exact finite, scoped, signed, uniform, normalized, ownership and missing-value checks passed');
