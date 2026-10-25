'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const thrust=require('../web/engine_thrust.js'),engines=require('../web/engines.js');
let checks=0;
const catalog=[{name:'Inner',enabled:true},{name:'Outer',enabled:false}],rows=[{engine:'Inner',thrust_n:15000},{engine:'Outer',thrust_n:-2000}];
assert.deepEqual(thrust.normalize(rows,catalog),rows);checks++;
assert.deepEqual(thrust.normalize([{engine:'Inner'}],catalog),[{engine:'Inner',thrust_n:0}]);checks++;
for(const invalid of [null,{},[{engine:'Inner',thrust_n:null}],[{engine:'Inner',thrust_n:Infinity}],[{engine:'Inner',thrust_n:'300'}],[{engine:'',thrust_n:3}],rows.concat(rows[0]),[{engine:'Inner',thrust_n:1,unit:'kN'}]]){
  assert.throws(()=>thrust.normalize(invalid,catalog));checks++;
}
assert.throws(()=>thrust.normalize([{engine:'Removed',thrust_n:10}],catalog),/no matching engine/);checks++;
assert.deepEqual(thrust.normalize([{engine:'Removed',thrust_n:0}],catalog),[{engine:'Removed',thrust_n:0}]);checks++;
assert.deepEqual(thrust.canonical([{engine:'Outer',thrust_n:0},...rows.slice(0,1)]),thrust.canonical(rows.slice(0,1)));checks++;
assert.deepEqual(thrust.canonical([...rows].reverse()),thrust.canonical(rows));checks++;
assert.deepEqual(thrust.renamed(rows,'Inner','Port')[0],{engine:'Port',thrust_n:15000});assert.equal(rows[0].engine,'Inner');checks++;
assert.throws(()=>thrust.renamed(rows,'Inner','Outer'),/already exist/);checks++;

const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const parameters={'engines.items':[engines.defaults],'loads.engine_thrust':rows,'loads.cases':[{id:2,label:'Inherited'}]};
const schema=[{key:'engines.items',kind:'engines'},{key:'loads.engine_thrust',kind:'enginethrust'},{key:'loads.cases',kind:'loadcases'}];
const fields=new Map(Object.entries(parameters).map(([key,value])=>['p-'+key,{value:JSON.stringify(value)}]));
const state={schema,values:parameters,loadCases:structuredClone(parameters['loads.cases'])};
const context={state,WingEngines:engines,WingEngineThrust:thrust,JSON_TABLE_KINDS:new Set(['engines','enginethrust']),CASE_FIELDS:[['engine_thrust','Engine thrust','loads.engine_thrust']],affectsModel:()=>true,document:{getElementById:id=>fields.get(id)}};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function baseCaseValue('),source.indexOf('function updateEngineThrustAssignments(')),context);
vm.runInContext(source.slice(source.indexOf('function formSignature('),source.indexOf('function syncLeadingEdgeOrientation(')),context);
const effective=context.effectiveCase(state.loadCases[0]);assert.deepEqual(JSON.parse(JSON.stringify(effective.engine_thrust)),rows);effective.engine_thrust[0].thrust_n=4;assert.equal(context.effectiveCase(null).engine_thrust[0].thrust_n,15000);checks++;
assert.equal(context.formSignature(),context.formSignature(parameters));checks++;
const explicit=structuredClone(parameters);explicit['loads.cases'][0].engine_thrust=structuredClone(rows);assert.equal(context.formSignature(parameters),context.formSignature(explicit));checks++;
explicit['loads.cases'][0].engine_thrust[0].thrust_n=15001;assert.notEqual(context.formSignature(parameters),context.formSignature(explicit));checks++;
const old=structuredClone(parameters),zero=structuredClone(parameters);delete old['loads.engine_thrust'];zero['loads.engine_thrust']=[{engine:'Engine 1',thrust_n:0}];assert.equal(context.formSignature(old),context.formSignature(zero));checks++;
const empty=structuredClone(parameters);empty['loads.cases'][0].engine_thrust=[];assert.notEqual(context.formSignature(parameters),context.formSignature(empty));checks++;
console.log('Engine thrust schedules, validation, inheritance and result identity: '+checks+' checks passed');
