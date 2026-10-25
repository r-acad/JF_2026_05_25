'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const E = require('../web/engines.js'), locks = require('../web/parameter_locks.js');
let checks = 0;
assert.deepEqual(E.normalize([]), []); checks++;
assert.deepEqual(E.normalize([{name:' A '}])[0], {...E.defaults,name:'A'}); checks++;
assert.equal(E.normalize([{name:'A',front_rib:3,aft_rib:3}])[0].aft_rib,3); checks++;
for (const edit of [{name:''},{name:null},{enabled:1},{mass:0},{length:0},{mass:NaN},{length:Infinity},{x:null},{y:'1'},{z:Infinity},{front_rib:0},{aft_rib:1.5},{aft_xc:-.1},{aft_xc:1.1},{unknown:1},
 {E:0},{G:-1},{A:0},{I1:0},{I2:0},{J:0},{E:Infinity},{G:null},{A:'0.01'},{I1:NaN},{I2:Infinity},{J:null}]) {
  assert.throws(() => E.normalize([{...E.defaults,...edit}])); checks++;
}
assert.throws(()=>E.normalize([{name:'A'},{name:' A '}])); checks++;
assert.throws(()=>E.normalize(Array.from({length:101},(_,i)=>({name:'E'+i})))); checks++;
assert.equal(locks.scope('engines.items'),'mesh'); checks++;
assert(locks.GROUPS.mesh.includes('Engines')); checks++;

// Exercise the real application identity function: old studies with no engines
// remain identical to normalized empty definitions, while physical edits make
// existing result snapshots stale.
const source=fs.readFileSync(path.resolve(__dirname,'../web/app.js'),'utf8');
const signatureSource=source.slice(source.indexOf('function formSignature(params)'),source.indexOf('\nfunction syncLeadingEdgeOrientation()'));
const context={state:{schema:[{key:E.KEY,kind:'engines'}]},affectsModel:()=>true,WingEngines:E};
vm.createContext(context);vm.runInContext(signatureSource+'\nthis.signature=formSignature;',context);
assert.equal(context.signature({}),context.signature({[E.KEY]:[]}));checks++;
const input={[E.KEY]:[{name:'A'}]}, normalized={[E.KEY]:E.normalize(input[E.KEY])};
assert.equal(context.signature(input),context.signature(normalized));checks++;
for(const [key,value]of [['mass',1200],['length',5],['x',2],['y',3],['z',-2],['front_rib',4],['aft_rib',5],['aft_xc',.6],['enabled',false],['E',68e9],['G',25e9],['A',.012],['I1',1.6e-4],['I2',1.8e-4],['J',3e-4]]) {
  const modified=structuredClone(normalized);modified[E.KEY][0][key]=value;
  assert.notEqual(context.signature(normalized),context.signature(modified));checks++;
}
console.log(JSON.stringify({passed:true,checks,scope:'Engine validation, missing defaults, mesh locks and actual model/result identity'}));
