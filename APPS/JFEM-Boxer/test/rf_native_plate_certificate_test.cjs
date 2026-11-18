'use strict';
const assert=require('node:assert/strict'),V=require('../web/rf_native_report_view.js'),S=require('../web/stress_report_data.js');
const key='lower:bay7:skinstrip7:segment1',scope='skin_buckling:'+key;
const panel={key,skin:'lower',rib_bay:7,strip_index:7,label:'S6–Rear spar',length_m:1,width_m:.2,property_ids:[6000033],elements:[{eid:1,pid:6000033,area_m2:.2,thickness_m:.0015}]};
function fixture(){
 const cases=new Map([1,2].map(id=>[id,{analysis:'SOL101',matches:true,available:true,status:'complete',static:{},label:'Case '+id,elementResults:{}}]));
 const input={failureMode:'skin_buckling',generated:true,elements:new Map([[1,{nodes:[0,1,2,3],group:{kind:'quad',name:'Lower skin',pid:6000033,properties:{type:'PSHELL',thickness_m:.0015,material_id:1,material:{id:1,type:'MAT1'}}}}]]),cases,skinBucklingPanels:[panel],expectedCases:[{id:1,solution:101},{id:2,solution:101}],assessmentPolicy:{strengthSafetyFactor:1.5,bucklingPolicyFactor:1}};
 const row=(id,extra)=>({response_id:scope+':'+id+':default',physical_criterion_id:scope,failure_mode:'skin_buckling',case_id:id,case_key:id+':default',membership_pids:[6000033],membership_eids:[1],details:{},...extra});
 const unresolved=row(1,{status:'unavailable',raw_RF:null,utilization:null,no_demand:false,converged:false,approximation:false,membrane_recovery_complete:true,lower_bound_RF:5,reason:'No positive retained plate root',method:'Frozen physical Fourier basis'});
 const governing=row(2,{status:'ok',raw_RF:.27,utilization:1/.27,no_demand:false,converged:true,approximation:false,membrane_recovery_complete:true,method:'Converged Ritz plate'});
 return{input,rows:[unresolved,governing]};
}
const build=f=>V.build(f.input,{responses:f.rows}).report;
let checks=0;const test=(name,fn)=>{fn();checks++;console.log('PASS '+name);};
test('A native all-mode certificate preserves the converged envelope without inventing an unresolved eigenvalue',()=>{
 const f=fixture(),report=build(f),r=report.rows[0],c=r.caseResults[0];assert(r.complete);assert.equal(r.reserveFactor,.27);assert.equal(r.envelopeCaseLabel,'Case 2 · SOL101');assert.equal(c.reserveFactor,null);assert.equal(c.converged,false);assert.equal(c.noDestabilizingLoad,false);assert(c.certifiedNonGoverning);assert.equal(c.recovered,c.total);assert.match(c.boundReason,/remains unresolved/);assert.match(S.markdown(report),/Poincare/);
});
test('A lone unresolved native case retains its explicit gap',()=>{const f=fixture();f.input.cases.delete(2);f.input.expectedCases.pop();f.rows.pop();const r=build(f).rows[0];assert(!r.complete);assert.equal(r.reserveFactor,null);assert(!r.caseResults[0].certifiedNonGoverning);});
test('An insufficient or roundoff-close bound cannot certify the missing case',()=>{for(const bound of [.1,.27,.27*(1+1e-9),null,NaN]){const f=fixture();f.rows[0].lower_bound_RF=bound;const r=build(f).rows[0];assert(!r.complete);assert.equal(r.reserveFactor,null);assert(!r.caseResults[0].certifiedNonGoverning);}});
test('Missing physical recovery cannot be rescued by a large bound',()=>{const f=fixture();f.rows[0].membrane_recovery_complete=false;const r=build(f).rows[0];assert(!r.complete);assert(!r.caseResults[0].certifiedNonGoverning);assert.equal(r.caseResults[0].recovered,0);});
test('An approximate governing root is insufficient for this envelope proof',()=>{const f=fixture();Object.assign(f.rows[1],{converged:false,approximation:true});const r=build(f).rows[0];assert(!r.complete);assert(!r.caseResults[0].certifiedNonGoverning);});
test('Missing or unselected cases and different physical scopes cannot provide a certificate',()=>{
 for(const change of[f=>{f.rows.pop();},f=>{f.rows[1].physical_criterion_id='skin_buckling:another-panel';},f=>{f.input.cases.delete(2);f.input.expectedCases.pop();}]){const f=fixture();change(f);const r=build(f).rows[0];assert(!r.complete);assert(!r.caseResults[0].certifiedNonGoverning);}
});
console.log(JSON.stringify({passed:checks,failed:0}));
