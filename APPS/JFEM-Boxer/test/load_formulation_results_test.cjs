'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),version=fs.readFileSync(path.join(__dirname,'../src/load_moments.jl'),'utf8').match(/const APPLIED_LOAD_VERSION = "([^"]+)"/)[1];
assert.notEqual(version,'rib_aero_bay_mass_wrenches_pg_v2','Fixed runout section changes must advance the formulation token');
const state={data:{nodes:{count:1},loads:{load_application_version:version},load_cases:[{id:1}]},modelSignature:'current',jobSignature:'current',values:{'output.solution':'101'}};
const context={state,WingImportedAnalysis:require('../web/imported_analysis.js'),asF32:v=>Float32Array.from(v),asI32:v=>Int32Array.from(v),permute:v=>v,formSignature:()=>state.modelSignature,resultsHavePendingDrafts:()=>false,document:{querySelector:()=>null,getElementById:()=>null}};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function decodeResultCase('),source.indexOf('/* --- Babylon scene')),context);
vm.runInContext(source.slice(source.indexOf('function analysisValidity()'),source.indexOf('function sensitivityResultsAvailable()')),context);
vm.runInContext(source.slice(source.indexOf('function activeShape()'),source.indexOf('function animating()')),context);
const base={node_count:1,static:{disp:[0,0,0],max_disp:0},contours:[],modes:[]},decode=(changes={},envelope={node_count:1})=>context.decodeResultCase({...base,...changes},envelope,'current');
let checks=0;
for(const metadata of [{},{load_application_version:'rib_aero_bay_mass_wrenches_v1'},{load_application_version:'rib_aero_bay_mass_wrenches_pg_v2'}]){
 const result=decode(metadata);assert(result.matches&&result.static&&result.historical);assert.match(result.message,/Historical model formulation/);
 state.resultCases=new Map([[1,result]]);state.results=result;state.activeMode=-1;
 assert(!context.analysisValidity().current);assert(context.activeShape(),'Historical fields must remain inspectable');checks++;
}
const fresh=decode({load_application_version:version});assert(fresh.matches&&!fresh.historical);state.resultCases=new Map([[1,fresh]]);assert(context.analysisValidity().current);checks++;
assert(decode({load_application_version:version},{node_count:1,load_application_version:'old'}).historical);checks++;
assert(decode({load_application_version:version,historical:true}).historical);checks++;
state.importedDeck={signature:'deck-a',solution:'101',cases:[{id:1}]};
const imported=decode({imported_signature:'deck-a'},{node_count:1,imported_signature:'deck-a'});
assert(imported.matches&&!imported.historical);state.resultCases=new Map([[1,imported]]);assert(context.analysisValidity().current);checks++;
assert(!decode({imported_signature:'deck-b'},{node_count:1,imported_signature:'deck-a'}).matches);checks++;
// Fresh sensitivity jobs without explicit compatibility metadata use the same
// formulation gate: identical parameters/topology permit historical mapping,
// but the old internal runout constant must never report a current analysis.
state.importedDeck=null;
const controls=new Map();context.document.getElementById=id=>{if(!controls.has(id))controls.set(id,{replaceChildren(){},append(){}});return controls.get(id);};
Object.assign(context,{clearSensitivityMap(){},refreshSensitivityMapCard(){},updateAnalysisValidity(){},WingSensitivityResults:{rankEffects:()=>[]},WingSensitivityMap:{fields:()=>[]}});
vm.runInContext(source.slice(source.indexOf('function acceptSensitivityResult('),source.indexOf('function sensitivityMappingAllowed()')),context);
for(const token of ['rib_aero_bay_mass_wrenches_pg_v2',version]){
 context.acceptSensitivityResult({case_id:1,load_application_version:token,rows:[]},'current');
 assert(state.sensitivityMeta.compatibility.map_allowed);assert.equal(state.sensitivityMeta.compatibility.is_current,token===version);checks++;
}
console.log('Generated load-formulation history and independent imported-deck compatibility: '+checks+' checks passed');
