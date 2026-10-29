'use strict';
const assert=require('node:assert/strict'),D=require('../web/stress_report_data.js'),I=require('../web/rf_incremental.js');
const property=t=>({type:'PSHELL',material_id:1,material:{id:1,type:'MAT1',E_Pa:70e9,nu:.3},thickness_m:t});
const element=(pid,t)=>({nodes:[0,1,2,3],group:{name:'UPPER_SKIN_P'+pid,kind:'quad',pid,properties:property(t)}});
const record=stress=>({stress_units:'Pa',stress:{z1:{von_mises:stress},z2:{von_mises:stress}}});
const base={generated:false,studyEpoch:1,meshIdentity:'fixed',signature:'base',failureMode:'von_mises',caseId:'all',method:'maximum',percentile:95,allowables:[{material_id:1,mode:'stress',stress:100}],elements:new Map([[1,element(1,.001)],[2,element(2,.001)]]),cases:new Map([[1,{analysis:'SOL101',matches:true,available:true,status:'complete',static:{},signature:'base',meshIdentity:'fixed',elementResults:{1:record(10),2:record(20)}}]]),eulerColumns:[],stringerBlades:[],skinBucklingPanels:[],componentBuckling:{web_panels:[],columns:[],blades:[]}};
const current={...base,estimated:true,signature:'edited',elements:new Map([[1,element(1,.002)],[2,base.elements.get(2)]]),cases:new Map([[1,{...base.cases.get(1),signature:'edited',elementResults:{1:record(5),2:base.cases.get(1).elementResults[2]}}]])};
for(const mode of ['von_mises','minimum_rf']){
 const oldInput={...base,failureMode:mode},input={...current,failureMode:mode},old=D.build(oldInput),fresh=I.build(input,old,oldInput),oracle=D.build(input);
 assert.deepEqual(fresh.rows.map(r=>[r.pid,r.reserveFactor,r.complete]),oracle.rows.map(r=>[r.pid,r.reserveFactor,r.complete]));assert.deepEqual(fresh.incremental.properties,[1]);assert.equal(fresh.incremental.modes.von_mises,1);assert(fresh.incremental.reusedRows>=1);assert(D.currentContext(fresh,input));assert.equal(old.rows.find(r=>r.pid===1).reserveFactor,10);assert.equal(fresh.rows.find(r=>r.pid===1).reserveFactor,20);
}
const fallback=I.build({...current,meshIdentity:'different'},D.build(base),base);assert.equal(fallback.incremental,undefined);
// A construction/material edit must also remove stale exclusion metadata.
const unsupported={...base,failureMode:'principal_strain',elements:new Map([[1,{group:{pid:1,kind:'quad',properties:{type:'PCOMP',plies:[{material_id:8,material:{type:'MAT8'}},{material_id:9,material:{type:'MAT8'}}]}}}]])};
const changed={...unsupported,estimated:true,elements:base.elements},old=D.build(unsupported),updated=I.build(changed,old,unsupported),oracle=D.build(changed);
assert.equal(old.excludedProperties.length,1);assert.deepEqual(updated.excludedProperties,oracle.excludedProperties);assert.deepEqual(updated.coverage,oracle.coverage);
console.log('PASS Incremental stress/minimum envelopes match a full rebuild, preserve unchanged rows and do not mutate the solved baseline.');
