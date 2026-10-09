'use strict';
const assert=require('node:assert/strict');
const map=require('../web/sensitivity_map.js');
const row=(id,value,derivative,extra={})=>({id,value,derivative,unit:'m',derivative_unit:'m / m',status:'ok',field_key:'shell.thickness',field_label:'Shell thickness',...extra});
const result={case_id:1,baseline:{value:2,unit:'m'},rows:[row('upper',.004,-20),row('lower',.003,30)]};
const scope={variables:{upper:{eids:[1,2]},lower:{eids:[3,4]}}};
const key=map.fields(result,scope)[0].key;
const before=JSON.stringify({result,scope});
const normalized=map.buildField(result,scope,key),raw=map.buildField(result,scope,key,'derivative');
assert.equal(normalized.byId.get(1),-.04);assert.equal(normalized.byId.get(3),.045);
assert.equal(raw.byId.get(2),-20);assert.equal(raw.byId.get(4),30);
assert.equal(raw.unit,'m / m');assert.equal(raw.min,-20);assert.equal(raw.max,30);
assert.equal(raw.rowsById.get(1).id,'upper');assert.equal(raw.rowsById.get(3).id,'lower');
assert.equal(JSON.stringify({result,scope}),before);

const overlap={variables:{upper:{eids:[1,2]},lower:{eids:[2,3]}}};
const ambiguous=map.buildField(result,overlap,key);
assert.deepEqual([...ambiguous.byId.keys()],[1,3]);assert.match(ambiguous.note,/1 elements have overlapping/);
const failed={...result,rows:[result.rows[0],{...result.rows[1],status:'failed'}]};
const partlyFailed=map.buildField(failed,overlap,key);
assert.deepEqual([...partlyFailed.byId.keys()],[1]);assert(!partlyFailed.rowsById.has(2));
assert.match(partlyFailed.note,/1 unavailable/);
const nonfinite=map.buildField({...result,rows:[result.rows[0],{...result.rows[1],derivative:Infinity}]},scope,key);
assert.deepEqual([...nonfinite.byId.keys()],[1,2]);
assert.throws(()=>map.buildField(result,{variables:{upper:{eids:[1]},lower:{eids:[1]}}},key),/unambiguous/);

const zero={...result,baseline:{value:0,unit:'m'}};
assert.throws(()=>map.buildField(zero,scope,key),/zero baseline/);
assert.equal(map.buildField(zero,scope,key,'derivative').byId.get(1),-20);
const negative=map.buildField({...result,baseline:{value:-2,unit:'m'}},scope,key);
assert.equal(negative.byId.get(1),.04);
const duplicate=map.buildField(result,{variables:{upper:{eids:['1',1,2]},lower:{eids:[3]}}},key);
assert.equal(duplicate.byId.size,3);assert(duplicate.byId.has(1));
assert.throws(()=>map.buildField(result,scope,'missing'),/Choose a structural/);

const families={...result,rows:[...result.rows,row('incompatible',1,1,{derivative_unit:'Pa / m'}),row('unmapped',1,1)]};
assert.equal(map.fields(families,{variables:{...scope.variables,incompatible:{eids:[5]}}}).length,2);
assert.equal(map.fields(families,{variables:{}}).length,0);

// Global material variables can cover every element of a dense mesh. No
// argument spreading may depend on browser/Node call-stack limits.
const dense={variables:{upper:{eids:Array.from({length:150000},(_,i)=>i+1)}}};
const large=map.buildField(result,dense,key,'derivative');
assert.equal(large.byId.size,150000);assert.equal(large.min,-20);assert.equal(large.max,-20);assert.equal(large.byId.get(150000),-20);
const local=row('panel',.006,7,{panel_key:'upper:bay1:stringer1:segment1'});
const localScope={variables:{upper:{eids:[1,2]},panel:{eids:[1]}}};
for(const rows of [[result.rows[0],local],[local,result.rows[0]]]){
 const field=map.buildField({...result,rows},localScope,key,'derivative');
 assert.equal(field.byId.get(1),7);assert.equal(field.byId.get(2),-20);
 assert.equal(field.rowsById.get(1).id,'panel');
}
const unavailableLocal=map.buildField({...result,rows:[result.rows[0],{...local,status:'failed'}]},localScope,key,'derivative');
assert(!unavailableLocal.byId.has(1));assert.equal(unavailableLocal.byId.get(2),-20);
console.log('Sensitivity fields: 36 signed-value, ownership, local-precedence, failure and dense-mesh assertions passed');
