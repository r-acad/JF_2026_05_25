'use strict';
const assert=require('node:assert/strict'),Snapshot=require('../web/stress_report_snapshot.js'),Data=require('../web/stress_report_data.js');
const recovery=(value=100e6)=>({1:{stress:{z1:{von_mises:value},z2:{von_mises:value/2}}}});
const record=(extra={})=>({analysis:'SOL101',static:{},available:true,status:'complete',matches:true,signature:'model-a',meshIdentity:'mesh-a',elementResults:recovery(),...extra});
function context(extra={}){return{studyEpoch:1,signature:'model-a',meshIdentity:'mesh-a',modelDirty:false,pendingDrafts:false,running:false,
 elements:new Map([[1,{id:1,group:{pid:10,name:'SKIN',kind:'quad',properties:{type:'PSHELL',material_id:1,material:{id:1,type:'MAT1'},thickness:.002}}}]]),
 cases:new Map([[1,record()]]),allowables:[{material_id:1,mode:'stress',stress:300e6}],caseLabels:new Map([[1,'Original case']]),expectedCases:[{id:1,solution:101,label:'Original case'}],
 generated:true,panels:[{key:'upper:bay1:stringer1:segment1',shell_pid:10}],componentGroups:[{pid:10,name:'SKIN'}],layoutToken:'layout-a',
 eulerFixityCoefficient:1,skinFixityCoefficient:1,componentFixities:{spar_web_buckling:1},skinBucklingPanels:[{key:'panel-a'}],...extra};}
const rf=selection=>Data.build(selection.context).rows[0]?.reserveFactor;
let passed=0;
function check(name,fn){fn();passed++;console.log('PASS '+name);}
check('No completed result means no fabricated retained assessment',()=>{
 const controller=Snapshot.create(),raw=context({cases:new Map(),modelDirty:true}),selected=controller.select(raw);
 assert.equal(selected.context,raw);assert.equal(selected.stale,false);assert.equal(selected.source,null);assert.equal(Data.build(selected.context).includedCases.length,0);
});
check('Current selection keeps strict live geometry identity and captures source provenance',()=>{
 const controller=Snapshot.create(),raw=context(),selected=controller.select(raw),report=Data.build(selected.context);
 assert.equal(selected.context,raw);assert.equal(selected.stale,false);assert(Data.currentContext(report,raw));assert.equal(rf(selected),3);
 assert.equal(selected.source.signature,'model-a');assert.equal(selected.source.layoutToken,'layout-a');assert.equal(selected.source.studyEpoch,1);
 assert(!Number.isNaN(Date.parse(selected.source.capturedAt)));assert.equal(controller.select(raw).source,selected.source);
});
check('Property edits retain old dimensions, allowables, fixities and case scope together',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.modelDirty=true;
 raw.elements.get(1).group.properties.thickness=.004;raw.allowables[0].stress=600e6;raw.componentFixities.spar_web_buckling=2;
 raw.caseLabels.set(1,'Edited case');raw.expectedCases[0].label='Edited case';raw.eulerFixityCoefficient=3;
 const selected=controller.select(raw);assert(selected.stale);assert.equal(rf(selected),3);
 assert.equal(selected.context.elements.get(1).group.properties.thickness,.002);assert.equal(selected.context.allowables[0].stress,300e6);
 assert.equal(selected.context.componentFixities.spar_web_buckling,1);assert.equal(selected.context.eulerFixityCoefficient,1);
 assert.equal(selected.context.caseLabels.get(1),'Original case');assert.equal(selected.context.expectedCases[0].label,'Original case');
 assert.match(selected.message,/^Model and results are not in sync\./);assert.match(selected.message,/You can continue editing properties\./);assert.match(selected.message,/Previous analysis retained\./);assert.match(selected.message,/do not describe the edited model/);
});
check('Regeneration cannot erase the cloned element registry or mutate saved case eligibility',()=>{
 const controller=Snapshot.create(),raw=context(),original=raw.cases.get(1),stress=original.elementResults;controller.select(raw);
 raw.elements.clear();original.matches=false;original.status='replaced';raw.signature='model-b';raw.meshIdentity='mesh-b';raw.panels=[];
 const selected=controller.select(raw);assert(selected.stale);assert.equal(selected.context.elements.size,1);assert.equal(selected.context.cases.get(1).matches,true);
 assert.equal(selected.context.cases.get(1).status,'complete');assert.equal(selected.context.cases.get(1).elementResults,stress,'Published heavy stress arrays remain shared');assert.equal(rf(selected),3);
 assert.equal(selected.source.panels.length,1);assert.equal(selected.source.panels[0].shell_pid,10);
});
check('Nested SOL106 variants, convergence and validation metadata are independently retained',()=>{
 const nonlinear=record({analysis:'SOL106',loadScale:1,convergence:{converged:true,full_load:true,partial:false},validationIssues:[]});
 const parent={...nonlinear,variants:new Map([['sol101',record()],['sol106',nonlinear]])},raw=context({cases:new Map([[1,parent]]),expectedCases:[{id:1,solution:106}]}),controller=Snapshot.create();
 controller.select(raw);raw.pendingDrafts=true;nonlinear.convergence.full_load=false;nonlinear.validationIssues.push('New invalid state');parent.variants.clear();
 const selected=controller.select(raw),saved=selected.context.cases.get(1).variants.get('sol106');assert.equal(saved.convergence.full_load,true);assert.deepEqual(saved.validationIssues,[]);
 assert.equal(Data.caseList(selected.context).included.length,2);assert.equal(rf(selected),3);assert.match(selected.message,/unfinished property edit/);
});
check('Running retains old tables, but a failed current case remains an honest coverage gap',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.running=true;raw.cases.get(1).status='running';
 let selected=controller.select(raw);assert(selected.stale);assert.match(selected.message,/analysis is running/);assert.equal(Data.caseList(raw).included.length,0);assert.equal(rf(selected),3);
 raw.running=false;raw.cases.get(1).status='failed';selected=controller.select(raw);assert.equal(selected.stale,false);assert.equal(selected.context,raw);assert.equal(rf(selected),null);assert.equal(Data.build(selected.context).excludedCases.length,1);
});
check('Removing every same-model case cannot silently revive older results',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.cases.clear();const selected=controller.select(raw);
 assert.equal(selected.stale,false);assert.equal(selected.context,raw);assert.equal(selected.source,null);assert.equal(rf(selected),null);assert.equal(Data.build(selected.context).missingCases.length,1);
});
check('A new matching completed result replaces the baseline after regeneration',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);const next=context({signature:'model-b',meshIdentity:'mesh-b',cases:new Map([[1,record({signature:'model-b',meshIdentity:'mesh-b',elementResults:recovery(150e6)})]])});
 let selected=controller.select(next);assert.equal(selected.stale,false);assert.equal(rf(selected),2);assert.equal(selected.source.signature,'model-b');
 next.modelDirty=true;selected=controller.select(next);assert(selected.stale);assert.equal(rf(selected),2);
});
check('Partial element recovery remains partial when retained, without reviving older passing ratios',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.cases.set(1,record({elementResults:{}}));
 const updated=controller.select(raw);assert.equal(updated.stale,false);assert.equal(rf(updated),null);raw.modelDirty=true;
 const selected=controller.select(raw);assert(selected.stale);assert.equal(rf(selected),null);assert.equal(Data.build(selected.context).complete,false);
});
check('A completed subset of requested cases retains honest missing-case coverage',()=>{
 const controller=Snapshot.create(),raw=context({expectedCases:[{id:1,solution:101},{id:2,solution:101}]});controller.select(raw);raw.modelDirty=true;
 const selected=controller.select(raw),report=Data.build(selected.context);assert(selected.stale);assert.equal(report.missingCases.length,1);assert.equal(report.rows[0].reserveFactor,null);
 const one=Data.build({...selected.context,caseId:1});assert.equal(one.rows[0].reserveFactor,3);assert(one.complete);
});
check('A changed study epoch never reuses a preceding Study snapshot even for matching signatures',()=>{
 const controller=Snapshot.create();controller.select(context());const raw=context({studyEpoch:2,cases:new Map(),modelDirty:true}),selected=controller.select(raw);
 assert.equal(selected.stale,false);assert.equal(selected.source,null);assert.equal(selected.context,raw);assert.equal(Data.build(raw).includedCases.length,0);
});
check('Explicit reset releases retained source ownership',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);controller.reset();raw.modelDirty=true;
 const selected=controller.select(raw);assert.equal(selected.stale,false);assert.equal(selected.source,null);
});
check('Restoring an unchanged solved definition returns to current calculations',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.modelDirty=true;assert(controller.select(raw).stale);raw.modelDirty=false;
 assert.equal(controller.select(raw).stale,false);assert.equal(controller.select(raw).context,raw);
});
check('Postprocessing-only changes recalculate a current model but freeze once physical edits start',()=>{
 const controller=Snapshot.create(),raw=context();const first=controller.select(raw);raw.allowables=[{...raw.allowables[0],stress:450e6}];
 let selected=controller.select(raw);assert.equal(selected.stale,false);assert.equal(rf(selected),4.5);assert.notEqual(selected.source,first.source);
 raw.modelDirty=true;raw.allowables[0].stress=900e6;selected=controller.select(raw);assert.equal(rf(selected),4.5);
});
check('An in-place eligible case replacement is detected even with a stable cases Map',()=>{
 const controller=Snapshot.create(),raw=context();controller.select(raw);raw.cases.get(1).elementResults=recovery(200e6);
 assert.equal(rf(controller.select(raw)),1.5);raw.modelDirty=true;assert.equal(rf(controller.select(raw)),1.5);
});
check('Unsupported and partial nonlinear cases cannot create a baseline',()=>{
 for(const extra of [{analysis:'SOL105'},{analysis:'SOL103'},{matches:false},{historical:true},{analysis:'SOL106',loadScale:.5,convergence:{converged:true,full_load:false,partial:true}}]){
  const controller=Snapshot.create(),raw=context({cases:new Map([[1,record(extra)]])});assert.equal(controller.select(raw).source,null);raw.modelDirty=true;assert.equal(controller.select(raw).stale,false);
 }
});
console.log(JSON.stringify({passed}));
