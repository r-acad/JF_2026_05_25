'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),version='rib_aero_bay_mass_wrenches_pg_v2';
const state={data:{nodes:{count:1},loads:{load_application_version:version},load_cases:[{id:1}]},modelSignature:'current',jobSignature:'current',values:{'output.solution':'101'}};
const context={state,asF32:v=>Float32Array.from(v),asI32:v=>Int32Array.from(v),permute:v=>v,formSignature:()=>state.modelSignature,resultsHavePendingDrafts:()=>false,document:{querySelector:()=>null,getElementById:()=>null}};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function decodeResultCase('),source.indexOf('/* --- Babylon scene')),context);
vm.runInContext(source.slice(source.indexOf('function analysisValidity()'),source.indexOf('function sensitivityResultsAvailable()')),context);
const base={node_count:1,static:{disp:[0,0,0],max_disp:0},contours:[],modes:[]},decode=(changes={},envelope={node_count:1})=>context.decodeResultCase({...base,...changes},envelope,'current');
let checks=0;
for(const metadata of [{},{load_application_version:'rib_aero_bay_mass_wrenches_v1'}]){
 const result=decode(metadata);assert(result.matches&&result.static&&result.historical);assert.match(result.message,/Historical load formulation/);
 state.resultCases=new Map([[1,result]]);assert(!context.analysisValidity().current);checks++;
}
const fresh=decode({load_application_version:version});assert(fresh.matches&&!fresh.historical);state.resultCases=new Map([[1,fresh]]);assert(context.analysisValidity().current);checks++;
assert(decode({load_application_version:version},{node_count:1,load_application_version:'old'}).historical);checks++;
assert(decode({load_application_version:version,historical:true}).historical);checks++;
state.importedDeck={signature:'deck-a',solution:'101',cases:[{id:1}]};
const imported=decode({imported_signature:'deck-a'},{node_count:1,imported_signature:'deck-a'});
assert(imported.matches&&!imported.historical);state.resultCases=new Map([[1,imported]]);assert(context.analysisValidity().current);checks++;
assert(!decode({imported_signature:'deck-b'},{node_count:1,imported_signature:'deck-a'}).matches);checks++;
console.log('Generated load-formulation history and independent imported-deck compatibility: '+checks+' checks passed');
