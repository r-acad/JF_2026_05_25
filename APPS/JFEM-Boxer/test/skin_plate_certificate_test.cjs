'use strict';
const assert=require('node:assert/strict'),P=require('../web/skin_buckling_data.js'),S=require('../web/stress_report_data.js'),T=require('../web/reserve_factor_table_data.js');
const D=[[1,.33,0],[.33,1,0],[0,0,.335]],I=[[1,0,0],[0,1,0],[0,0,1]],near=(x,y)=>assert(Math.abs(x-y)<=1e-10*Math.abs(y));
const hard=[-1,-.0717,.26844];
const panel={key:'upper:bay1:skinstrip1:segment1',skin:'upper',rib_bay:1,strip_index:1,label:'Front spar–S1',property_ids:[5000001],length_m:4.3,width_m:1,fixity_coefficient:1,elements:[{eid:1,pid:5000001,area_m2:4.3,thickness_m:.002,material_ids:[1],stress_transform:I,bending_matrix_Nm:D}]};
function item(N,id){return{caseKey:String(id),caseId:id,label:'Case '+id,solution:'SOL101',result:{elementResults:{1:{forces:{fx:-N[0],fy:-N[1],fxy:-N[2]}}}}};}
function assess(items,extra={}){return P.assessPanel(panel,{included:items,excluded:[],missing:[],complete:true,...extra},{plateOptions:{truncatedFallback:false}});}
let checks=0;const test=(name,fn)=>{fn();checks++;console.log('PASS '+name);};
test('Energy bound lies below exact and coupled Ritz roots, retains engineering shear and signed loading',()=>{
 for(const d of [D,[[2,.4,.15],[.4,1,.08],[.15,.08,.5]]])for(const N of [[1,0,0],[0,1,0],[1,1,.3],[0,0,1],[-1,-.002,.0525]]){
  const bound=P.plateLowerBound(1.7,1,d,N);assert(bound>0);const r=P.criticalForBasis(1.7,1,d,N,9,11);if(r.reserveFactor!==null)assert(bound<r.reserveFactor);
  near(P.plateLowerBound(1.7,1,d,N.map(x=>2*x)),bound/2);near(P.plateLowerBound(1.7,1,d,N,3),3*bound);
 }
 const N=[1,-2,.5],r=P.plateLowerBound(1.7,1,D,N);near(P.plateLowerBound(1,1.7,D,[-2,1,.5]),r);near(P.plateLowerBound(1.7,1,D,[1,-2,-.5]),r);
});
test('Invalid, unprovable and numerically unresolved certificates stay absent',()=>{
 for(const args of [[0,1,D,[1,0,0]],[1,1,D,[NaN,1,0]],[1,1,D,[0,0,0]],[1,1,D,[1,0,0],0],[1,1,[[1,2,0],[2,1,0],[0,0,1]],[1,0,0]],[1,1,[[1,.7,.7],[.7,1,.7],[.7,.7,1]],[1,0,0]]])assert.equal(P.plateLowerBound(...args),null);
});
test('Tension-stabilized unresolved case cannot invalidate a proved governing envelope',()=>{
 const r=assess([item([1,0,0],1),item(hard,2)]),c=r.caseResults[1];assert(r.complete);assert(r.reserveFactor>0);assert.equal(c.converged,false);assert.equal(c.reserveFactor,null);assert(c.lowerBound>r.reserveFactor);assert.equal(c.certifiedNonGoverning,true);assert.match(c.boundReason,/Poincare/);assert.equal(r.envelopeCaseLabel,'Case 1');assert(r.reasons.every(x=>x.certifiedNonGoverning));
 const notes=T.plateDiagnosticNotes(r).join(' ');assert.match(notes,/lower bound RF/);assert.match(notes,/not a calculated case eigenvalue/);assert.match(notes,/certified non-governing/);
});
test('Single unresolved case remains unassessed with a disclosed lower bound',()=>{
 const r=assess([item(hard,2)]);assert(!r.complete);assert.equal(r.reserveFactor,null);assert.equal(r.caseResults[0].certifiedNonGoverning,false);assert(r.caseResults[0].lowerBound>0);assert.match(T.plateDiagnosticNotes(r).join(' '),/lower bound RF/);
 const all=assess([item(hard,2),item([-1,-1,0],3)]);assert(!all.complete);assert.equal(all.reserveFactor,null);
});
test('A lower bound below the candidate RF cannot establish completeness',()=>{
 const r=assess([item([1e-7,0,0],1),item(hard,2)]);assert(!r.complete);assert.equal(r.reserveFactor,null);assert.equal(r.caseResults[1].certifiedNonGoverning,false);
});
test('Case and element coverage are required independently of the certificate',()=>{
 const missing=assess([item([1,0,0],1),item(hard,2)],{complete:false});assert(!missing.complete);assert.equal(missing.reserveFactor,null);
 const absent=item(hard,2);absent.result.elementResults={};const r=assess([item([1,0,0],1),absent]);assert(!r.complete);assert.equal(r.caseResults[1].lowerBound,null);assert.equal(r.caseResults[1].certifiedNonGoverning,false);
});
test('Stress and reserve-table exports disclose certification and unresolved eigenvalues',()=>{
 const row=assess([item([1,0,0],1),item(hard,2)]),report={failureMode:'skin_buckling',rows:[row],includedCases:[],excludedCases:[],missingCases:[],method:'area_mean',percentile:100,stressUnit:'MPa',stressFactor:1e-6,complete:true,coverage:row.coverage,note:P.NOTE};
 for(const text of [S.csv(report),S.markdown(report),S.html(report)]){assert.match(text,/Poincare/);assert.match(text,/lower bound/);assert.match(text,/unresolved/);}
 const model=T.build({report,group:'all',view:'flat'}),table=T.table(model);assert(table.headers.includes('Certified non-governing cases'));assert(table.rows[0].join(' ').includes('RF ≥'));
});
console.log(checks+' skin-plate certificate checks passed.');
