'use strict';
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const A=require('../web/imported_analysis.js'),I=require('../web/nastran_import.js'),W=require('../web/workspace.js');
const source={kind:'nastran',name:'model.bdf',text:'SOL 101\nCEND\nBEGIN BULK\nENDDATA\n',includes:[{name:'other.inc',text:'$ Original include\n'}]};
const deck={name:'model.bdf',solution:'105',signature:'source-hash',source,cases:[{id:17,result_required:false,case_control:{LOAD:4,SPC:2}},{id:18,result_required:true,case_control:{STATSUB:17}}]};
assert.equal(A.signature(deck),'source-hash');assert.deepEqual(A.cases(deck).map(c=>c.id),[18]);
deck.source.analysis=A.options({solution:'103',follower:'fixed',modes:7});
assert.equal(A.solution(deck),'103');assert.deepEqual(A.cases(deck).map(c=>c.id),[17]);assert.notEqual(A.signature(deck),'source-hash');
assert(A.matches(deck.source.analysis,deck));assert(!A.matches({solution:'101'},deck));
assert.throws(()=>A.options({solution:'999'}));assert.throws(()=>A.options([]));
const saved=I.source(source);assert.deepEqual(saved,source);saved.analysis.modes=8;assert.equal(source.analysis.modes,7);
const app=fs.readFileSync(require.resolve('../web/app.js'),'utf8');
function extract(name){const start=app.indexOf('function '+name+'('),end=app.indexOf('\nfunction ',start+1);assert(start>=0);return app.slice(start,end<0?undefined:end);}
const context={WingImportedAnalysis:A,state:{importedDeck:deck,data:{imported_deck:{}}}};vm.createContext(context);
vm.runInContext(extract('collectParams'),context);
context.state.importedDeck.token='opaque-token';const params=context.collectParams();assert.equal(params.model_kind,'nastran');assert.equal(params.imported_deck.signature,'source-hash');assert.equal(params.imported_deck.analysis.solution,'103');
context.state.importedDeck=null;assert.throws(()=>context.collectParams(),/identity is unavailable/);
(async()=>{
 const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},workspace:{activeTab:'analysis',width:400,collapsed:false},activeCase:17};
 const snapshot=await W.snapshot({},null,view,{modelSource:source});const restored=W.parse(JSON.stringify(snapshot));
 assert.deepEqual(restored.data.model_source,source);assert.equal(restored.data.model_source.text,source.text);assert.equal(restored.data.model_source.includes[0].text,source.includes[0].text);
 console.log('Imported analysis: immutable source, portable overlay, case ownership, signatures and missing-token guard passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
