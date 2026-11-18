'use strict';
const assert=require('node:assert/strict'),D=require('../web/stress_report_data.js'),I=require('../web/rf_incremental.js');
const property=t=>({type:'PSHELL',material_id:1,material:{id:1,type:'MAT1',E_Pa:70e9,nu:.3},thickness_m:t});
const element=(pid,t)=>({nodes:[0,1,2,3],group:{name:'UPPER_SKIN_P'+pid,kind:'quad',pid,properties:property(t)}});
const record=stress=>({stress_units:'Pa',stress:{z1:{von_mises:stress},z2:{von_mises:stress}}});
const base={assessmentPolicy:{strengthSafetyFactor:1,bucklingPolicyFactor:1},generated:false,studyEpoch:1,meshIdentity:'fixed',signature:'base',failureMode:'von_mises',caseId:'all',method:'maximum',percentile:95,allowables:[{material_id:1,mode:'stress',stress:100}],elements:new Map([[1,element(1,.001)],[2,element(2,.001)]]),cases:new Map([[1,{analysis:'SOL101',matches:true,available:true,status:'complete',static:{},signature:'base',meshIdentity:'fixed',elementResults:{1:record(10),2:record(20)}}]]),eulerColumns:[],stringerBlades:[],skinBucklingPanels:[],componentBuckling:{web_panels:[],columns:[],blades:[]}};
const current={...base,estimated:true,signature:'edited',elements:new Map([[1,element(1,.002)],[2,base.elements.get(2)]]),cases:new Map([[1,{...base.cases.get(1),signature:'edited',elementResults:{1:record(5),2:base.cases.get(1).elementResults[2]}}]])};
for(const mode of ['von_mises','minimum_rf']){
 const oldInput={...base,failureMode:mode},input={...current,failureMode:mode},old=D.build(oldInput),fresh=I.build(input,old,oldInput),oracle=D.build(input);
 assert.deepEqual(fresh.rows.map(r=>[r.pid,r.reserveFactor,r.complete]),oracle.rows.map(r=>[r.pid,r.reserveFactor,r.complete]));assert.deepEqual(fresh.incremental.properties,[1]);assert.equal(fresh.incremental.modes.von_mises,1);assert(fresh.incremental.reusedRows>=1);assert(D.currentContext(fresh,input));assert.equal(old.rows.find(r=>r.pid===1).reserveFactor,10);assert.equal(fresh.rows.find(r=>r.pid===1).reserveFactor,20);
}
const fallback=I.build({...current,meshIdentity:'different'},D.build(base),base);assert.equal(fallback.incremental,undefined);
assert(I.equivalent({J:6.794532502222684e-11,ids:[4,5]},{ids:[4,5],J:6.794532502222866e-11}));
assert(!I.equivalent({J:1e-12},{J:2e-12}),'tiny physical inertias do not use a unit absolute floor');assert(!I.equivalent({pid:10000000000},{pid:10000000001}));assert(!I.equivalent([4,5],[5,4]));assert(!I.equivalent([,],[]));
assert(!I.equivalent({pid:6000033},{pid:6000033.000001}));assert(!I.equivalent({member_element_ids:[1000000]},{member_element_ids:[1000000.000001]}));
const reordered={...base,elements:new Map([...base.elements].map(([id,e])=>[id,{...e,group:{...e.group,properties:Object.fromEntries(Object.entries(e.group.properties).reverse())}}]))};assert.equal(I.changedProperties(reordered,base).size,0,'property key order is not a physical edit');
// Contract-only native planner oracle. The numerical values above remain
// browser fixtures; the actual native sparse/full suite supplies solved data.
const V=require('../web/rf_native_report_view.js'),nativeOld=D.build({...base,failureMode:'minimum_rf'});nativeOld.nativeBackend=true;
const planned=V.planner({...current,failureMode:'minimum_rf'},nativeOld,{...base,failureMode:'minimum_rf'},D.criteria(nativeOld));
assert(planned.incremental);assert.deepEqual(planned.response_ids,['material:P1:1:default']);assert.equal(planned.counts.affectedCriteria,1);assert.equal(planned.counts.cachedCriteria,1);
const sent=V.scopedInput({...current,failureMode:'minimum_rf'},planned);assert.deepEqual([...sent.elements.keys()],[1]);assert.deepEqual(Object.keys(sent.cases.get(1).elementResults),['1']);assert(sent.restrict_responses);assert.equal(V.scopedInput(current,planned,{recoveryOnly:true}).elements.size,2);
assert.equal(V.planner({...current,failureMode:'minimum_rf'},nativeOld,base,D.criteria(nativeOld)).incremental,false,'missing prior request identity must never reuse cached assessments');
// A construction/material edit must also remove stale exclusion metadata.
const unsupported={...base,failureMode:'principal_strain',elements:new Map([[1,{group:{pid:1,kind:'quad',properties:{type:'PCOMP',plies:[{material_id:8,material:{type:'MAT8'}},{material_id:9,material:{type:'MAT8'}}]}}}]])};
const changed={...unsupported,estimated:true,elements:base.elements},old=D.build(unsupported),updated=I.build(changed,old,unsupported),oracle=D.build(changed);
assert.equal(old.excludedProperties.length,1);assert.deepEqual(updated.excludedProperties,oracle.excludedProperties);assert.deepEqual(updated.coverage,oracle.coverage);
console.log('PASS Incremental stress/minimum envelopes match a full rebuild, preserve unchanged rows and do not mutate the solved baseline.');
