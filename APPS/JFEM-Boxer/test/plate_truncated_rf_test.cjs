'use strict';
const assert=require('node:assert/strict'),P=require('../web/skin_buckling_data.js'),C=require('../web/component_buckling_data.js'),M=require('../web/minimum_rf_data.js'),S=require('../web/stress_report_data.js'),T=require('../web/reserve_factor_table_data.js');
const D=[[1,.33,0],[.33,1,0],[0,0,.335]],I=[[1,0,0],[0,1,0],[0,0,1]],hard=[-1,-.0717,.26844],near=(a,b,t=1e-8)=>assert(Math.abs(a-b)<=t*Math.abs(b),a+' != '+b);
let passed=0;const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const panel={key:'upper:bay1:skinstrip1:segment1',skin:'upper',rib_bay:1,strip_index:1,label:'Front spar–S1',property_ids:[5000001],length_m:4.3,width_m:1,fixity_coefficient:1,elements:[{eid:1,pid:5000001,area_m2:4.3,thickness_m:.002,material_ids:[1],stress_transform:I,bending_matrix_Nm:D}]};
const item=(N,id)=>({caseKey:String(id),caseId:id,label:'Case '+id,solution:'SOL101',result:{elementResults:{1:{forces:{fx:-N[0],fy:-N[1],fxy:-N[2]}}}}});
const cases=items=>({included:items,excluded:[],missing:[],complete:true});
test('Largest algebraic eigenvectors retain tensile signs and satisfy the original symmetric equation',()=>{
 for(let n=2;n<=24;n++){const A=Float64Array.from({length:n*n},(_,k)=>Math.sin(k*3));for(let i=0;i<n;i++)for(let j=0;j<i;j++)A[j*n+i]=A[i*n+j];const e=P.largestEigenvalue(A,n,true);let residual=0,norm=0;for(let i=0;i<n;i++){let r=-e.value*e.vector[i];for(let j=0;j<n;j++)r+=A[i*n+j]*e.vector[j];residual=Math.hypot(residual,r);norm+=e.vector[i]**2;}assert(residual<1e-9);near(norm,1);}
 const e=P.largestEigenvalue(new Float64Array([-100,0,0,.002]),2,true);near(e.value,.002,1e-7);assert(Math.abs(e.vector[1])>.999999);
});
test('Failed convergence gives exactly 100 selected physical sine terms and an honest approximation',()=>{
 const r=P.solvePlate(4.3,1,D,hard);assert(!r.converged);assert(r.approximation);assert.equal(r.basisSize,100);assert.equal(r.selectedModes.length,100);assert.equal(new Set(r.selectedModes.map(m=>m.join(','))).size,100);assert.equal(r.sourceBasisSize,986);assert(r.reserveFactor>r.history.at(-1).reserveFactor);assert.match(r.reason,/overestimate/);assert.equal(T.formatRF(r.reserveFactor),'999');
 const doubled=P.solvePlate(4.3,1,D,hard.map(v=>2*v));near(doubled.reserveFactor,r.reserveFactor/2);assert(doubled.approximation&&!doubled.converged);
 const strict=P.solvePlate(4.3,1,D,hard,{truncatedFallback:false});assert.equal(strict.reserveFactor,null);assert(!strict.approximation);
});
test('Anisotropic truncation solves physical mode matrices rather than mixed Cholesky coordinates',()=>{
 const d=[[2,.4,.3],[.4,1,.12],[.3,.12,.5]],N=[1,.2,.6],source=P.buildMatrices(1.6,1,d,13,13),G=Float64Array.from(source.gx,(_,i)=>N[0]*source.gx[i]+N[1]*source.gy[i]+N[2]*source.gxy[i]),r=P.truncateRitzMatrices(source.bending,G,source.modes),lookup=new Map(source.modes.map((m,i)=>[[m.m,m.n].join(','),i])),ids=r.selectedModes.map(m=>lookup.get(m.join(','))),extract=A=>Float64Array.from({length:ids.length**2},(_,k)=>A[ids[Math.floor(k/ids.length)]*source.n+ids[k%ids.length]]);
 const B=extract(source.bending),g=extract(G),L=P.cholesky(B,ids.length),value=1/P.largestEigenvalue(P.transformGeometric(L,g,ids.length),ids.length);near(r.reserveFactor,value,1e-11);assert(r.approximation&&!r.converged);assert.equal(r.basisSize,100);
});
test('Spatial web fallback preserves the signed, nonuniform membrane field',()=>{
 const cells=Array.from({length:8},(_,i)=>({bounds:[0,1,i/8,(i+1)/8],N:[2*(i+.5)/8-1,0,0]})),r=C.solveSpatialPlate(1,1,D,cells,{tolerance:1e-15});
 assert(r.approximation&&!r.converged);assert.equal(r.basisSize,100);assert(r.reserveFactor>0);const reflected=C.solveSpatialPlate(1,1,D,cells.map(c=>({...c,N:c.N.map(v=>-v)})),{tolerance:1e-15});near(r.reserveFactor,reflected.reserveFactor,2e-8);
});
test('No positive truncated root, invalid geometry and missing recovery never receive invented RFs',()=>{
 const r=P.solvePlate(4,1,D,[-1,-1,1+1e-12]);assert.equal(r.reserveFactor,null);assert(!r.approximation);assert(!r.noDestabilizingLoad);
 assert(P.solvePlate(0,1,D,hard).reason);const absent=item(hard,1);absent.result.elementResults={};const row=P.assessPanel(panel,cases([absent]),{});assert(!row.complete);assert.equal(row.reserveFactor,null);assert(!row.caseResults[0].approximation);
});
test('A selected unconverged case can be assessed without mislabeling the case or its envelope as converged',()=>{
 const r=P.assessPanel(panel,cases([item(hard,1)]),{});assert(r.complete&&r.approximation&&r.governingApproximation);assert(r.caseResults[0].approximation&&!r.caseResults[0].converged);assert(r.reserveFactor>999);
 const mixed=P.assessPanel(panel,cases([item([1,0,0],2),item(hard,1)]),{});assert(mixed.complete&&mixed.approximation&&!mixed.governingApproximation);assert.equal(mixed.envelopeCaseKey,'2');assert.equal(mixed.caseResults[1].certifiedNonGoverning,false);
 const high=P.assessPanel(panel,cases([item(hard,1),item(hard.map(v=>2*v),2)]),{});assert.equal(high.envelopeCaseKey,'2');assert(high.caseResults.every(c=>T.formatRF(c.reserveFactor)==='999'));near(high.reserveFactor,high.caseResults[0].reserveFactor/2);
});
test('Combined checks preserve all failing load cases, no-demand sentinels and approximation provenance',()=>{
 const members={complete:true,elementIds:[1],propertyIds:[5000001]},row=P.assessPanel(panel,cases([item(hard,1)]),{}),candidate=M.candidate(row,'skin_buckling',members);assert(candidate.complete&&candidate.approximation);assert.equal(candidate.caseResults[0].basisSize,100);assert(candidate.caseResults[0].complete&&candidate.caseResults[0].approximation);assert(!candidate.caseResults[0].converged);
 const vm=M.caseAssessments({allowableStress:300,caseResults:[{caseKey:'1',label:'First',recovered:2,total:2,envelope:600},{caseKey:'2',label:'Second',recovered:2,total:2,envelope:400},{caseKey:'3',label:'Empty',recovered:2,total:2,envelope:0},{caseKey:'4',label:'Missing',recovered:1,total:2,envelope:100}]},'von_mises',members);near(vm[0].reserveFactor,.5);near(vm[1].reserveFactor,.75);assert.equal(vm[2].reserveFactor,99);assert(vm[2].noDemand);assert.equal(vm[3].reserveFactor,null);assert(!vm[3].complete);
});
test('RF formatting caps displays only and all three exports disclose approximation and source basis',()=>{
 for(const n of [999,1000,1e9])assert.equal(T.formatRF(n),'999');assert.equal(S.formatRF(1200),'999');assert.equal(T.formatRF(null),'Unavailable');assert.equal(T.format(1200),'1200');assert.equal(T.formatRF(.999),'.999'.replace(/^\./,'0.'));
 const row=P.assessPanel(panel,cases([item(hard,1)]),{}),report={failureMode:'skin_buckling',rows:[row],includedCases:[],excludedCases:[],missingCases:[],method:'area_mean',percentile:100,stressUnit:'MPa',stressFactor:1e-6,complete:true,coverage:row.coverage,note:P.NOTE},model=T.build({report,group:'all',view:'flat'}),raw=row.reserveFactor;
 assert.equal(T.presentationValue(row),'999');assert.equal(model.rows[0].value,raw);for(const api of [T,S])for(const method of ['csv','markdown','html']){const text=api[method](api===T?model:report);assert.match(text,/100.*terms/);assert.match(text,/unconverged/i);assert.match(text,/overestimate/);assert.match(text,/999/);}assert.equal(row.reserveFactor,raw);
 const notes=T.plateDiagnosticNotes(row).join(' ');assert(!/case RF unavailable/.test(notes));assert.match(notes,/Truncated basis 100 selected sine terms from 986 terms/);
});
console.log(passed+' truncated plate and RF display checks passed.');
