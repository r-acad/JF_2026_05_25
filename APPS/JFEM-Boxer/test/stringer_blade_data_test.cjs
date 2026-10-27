'use strict';
const assert=require('node:assert/strict'),B=require('../web/stringer_blade_data.js'),S=require('../web/stress_report_data.js');
let passed=0;const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const near=(a,b,tol=1e-12)=>assert.ok(Math.abs(a-b)<=tol*Math.max(Math.abs(b),Number.MIN_VALUE),`${a} != ${b}`);
const bar=(eid=1,extra={})=>({eid,pid:7000001,length_m:1,web_height_m:.04,web_thickness_m:.002,young_pa:70e9,poisson:.3,material_id:1,material_type:'MAT1',source:'PBARL',section_shape:'T',...extra});
const blade=(extra={})=>({panel_id:1,key:'upper:bay1:stringer1:segment1',skin:'upper',rib_bay:1,stringer:1,segment:1,pid:7000001,bars:[bar()],...extra});
const result=(values,extra={})=>({analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:'mesh',meshIdentity:7,elementResults:Object.fromEntries(Object.entries(values).map(([eid,value])=>[eid,typeof value==='number'?{stress:{axial:value}}:value])),...extra});
const input=(blades,cases,extra={})=>({failureMode:'stringer_blade',stringerBlades:blades,cases,signature:'mesh',meshIdentity:7,...extra});
const build=(b=blade(),values={1:-50e6},extra={})=>S.build(input([b],new Map([[1,result(values)]]),extra));

test('Long supported/free isotropic plate reproduces an independently calculated critical stress',()=>{
 const q=B.criticalStress(bar());near(q.value,.425*Math.PI*Math.PI*70e9*.002*.002/(12*(1-.3*.3)*.04*.04));near(q.value/1e6,67.2208633,2e-10);
 const r=build().rows[0];near(r.reserveFactor,q.value/50e6);assert.equal(r.blade.coefficient,.425);assert.equal(r.blade.noCompression,false);assert.equal(r.coverage.recovered,1);
});
test('Thickness, clear height and modulus have the expected plate scaling',()=>{
 const c=B.criticalStress(bar()).value;near(B.criticalStress(bar(1,{web_thickness_m:.004})).value,4*c);near(B.criticalStress(bar(1,{web_height_m:.08})).value,c/4);near(B.criticalStress(bar(1,{young_pa:140e9})).value,2*c);
});
test('A rectangular blade uses its complete supported-edge to free-tip height',()=>{
 const specimen=bar(1,{section_shape:'BAR',dimensions_m:[.002,.04],web_height_m:.04}),r=build(blade({bars:[specimen]})).rows[0];
 near(r.reserveFactor,.425*Math.PI*Math.PI*70e9/(12*(1-.3*.3))*(.002/.04)**2/50e6);assert.equal(r.complete,true);
});
test('Poisson ratio is used explicitly, including physically valid auxetic material',()=>{
 const c=B.criticalStress(bar(1,{poisson:0})).value;near(B.criticalStress(bar()).value,c/.91);near(B.criticalStress(bar(1,{poisson:-.3})).value,c/.91);
});
test('Missing and nonphysical section or material values do not receive invented capacity',()=>{
 for(const change of [{young_pa:0},{young_pa:-1},{young_pa:Infinity},{young_pa:null},{poisson:NaN},{poisson:-1},{poisson:.5},{web_height_m:0},{web_thickness_m:-1},{material_type:'MAT8'},{reason:'Unsupported rod section.'}])assert.ok(B.criticalStress(bar(1,change)).reason);
 assert.ok(B.criticalStress().reason);
});
test('Two recovered axial endpoints are averaged before taking the average over elements',()=>{
 const r=build(blade({bars:[bar(1),bar(2)]}),{1:{stress:{axial:-90e6,axial_end_a:-10e6,axial_end_b:-90e6}},2:-30e6}).rows[0];
 assert.equal(r.blade.averageStress,-40e6);assert.equal(r.blade.compressionDemand,40e6);near(r.reserveFactor,r.blade.criticalStress/40e6);
});
test('Incomplete or invalid signed endpoint recovery is unavailable even if axial fallback exists',()=>{
 for(const stress of [{axial:-10,axial_end_a:-10},{axial:-10,axial_end_b:-10},{axial:-10,axial_end_a:NaN,axial_end_b:-10},{axial:-10,axial_end_a:-10,axial_end_b:null}])assert.match(B.axialStress({stress}).reason,/Both signed bar endpoint/);
});
test('Bending extrema, von Mises and axial force do not substitute for signed axial stress',()=>{
 for(const record of [{stress:{von_mises:100,end_a:{p1:-1e9},end_b:{p1:-1e9}}},{forces:{axial:-1000}},{stress:{axial:'-100'}},{stress:{axial:null}},{stress:{axial:Infinity}},null])assert.ok(B.axialStress(record).reason);
 const r=build(blade(),{1:{stress:{axial:-5e6,von_mises:1e20,end_a:{p1:-1e30}}}}).rows[0];assert.equal(r.blade.compressionDemand,5e6);
});
test('Element weighting is arithmetic, independent of element length or section area',()=>{
 const b=blade({bars:[bar(1,{length_m:.01}),bar(2,{length_m:100,web_thickness_m:.003})]}),r=build(b,{1:-90e6,2:-10e6}).rows[0];
 assert.equal(r.blade.averageStress,-50e6);assert.equal(r.blade.criticalEid,1);near(r.reserveFactor,B.criticalStress(bar()).value/50e6);
});
test('The lowest actual local capacity governs a variable section under the averaged bay demand',()=>{
 const b=blade({bars:[bar(1),bar(2,{web_thickness_m:.001,material_id:2,pid:7000002})]}),r=build(b,{1:-80e6,2:-20e6}).rows[0];
 assert.equal(r.blade.criticalEid,2);assert.equal(r.blade.criticalPid,7000002);assert.deepEqual(r.materialIds,[1,2]);near(r.reserveFactor,B.criticalStress(bar()).value/4/50e6);
});
test('Signed stress is averaged before compression is evaluated, without absolute-value bias',()=>{
 const b=blade({bars:[bar(1),bar(2),bar(3)]}),r=build(b,{1:-60e6,2:20e6,3:10e6}).rows[0];near(r.blade.averageStress,-10e6);near(r.blade.compressionDemand,10e6);assert.equal(r.maxStress,60e6);
});
test('RF 99 means no average compression, even if an individual element is compressed',()=>{
 const b=blade({bars:[bar(1),bar(2)]}),r=build(b,{1:-10e6,2:30e6}).rows[0];assert.equal(r.reserveFactor,99);assert.equal(r.blade.noCompression,true);near(r.blade.averageStress,10e6);assert.match(r.blade.note,/Individual elements may still be compressed/);
});
test('Zero and tensile complete cases receive the documented sentinel; tiny compression is real',()=>{
 for(const stress of [0,5e6]){const r=build(blade(),{1:stress}).rows[0];assert.equal(r.reserveFactor,99);assert.equal(r.blade.compressionDemand,0);}
 const r=build(blade(),{1:-1e-40}).rows[0];assert.equal(r.blade.noCompression,false);near(r.blade.compressionDemand,1e-40);assert.ok(r.reserveFactor>1e40);
});
test('Mean arithmetic avoids overflowing finite element stresses and ignores only relative cancellation noise',()=>{
 near(B.signedMean([Number.MAX_VALUE,Number.MAX_VALUE]).value,Number.MAX_VALUE);near(B.signedMean([-Number.MAX_VALUE,-Number.MAX_VALUE]).value,-Number.MAX_VALUE);
 assert.equal(B.signedMean([1e6,-1e6-1e-9]).compression,0);assert.equal(B.signedMean([-1e-80]).compression,1e-80);assert.equal(B.signedMean([1e100,-1e100]).value,0);
 for(const values of [[],[null],[NaN],[1,Infinity]])assert.ok(B.signedMean(values).reason);
});
test('Endpoint cancellation tolerance survives averaging across the bar list',()=>{
 const r=build(blade(),{1:{stress:{axial:-1e6,axial_end_a:1e6,axial_end_b:-1e6-1e-9}}}).rows[0];assert.equal(r.reserveFactor,99);
 const tiny=build(blade(),{1:{stress:{axial_end_a:-1e-40,axial_end_b:-1e-40}}}).rows[0];assert.equal(tiny.blade.compressionDemand,1e-40);assert.equal(tiny.blade.noCompression,false);
});
test('Known recovered stress units convert to Pa for the criterion, while unknown units are unassessed',()=>{
 for(const [stress_units,axial]of [['Pa; axial and bending stresses',-50e6],['kPa',-50e3],['MPa',-50],['GPa',-.05]])assert.equal(build(blade(),{1:{stress_units,stress:{axial}}}).rows[0].blade.compressionDemand,50e6);
 const cases=new Map([[1,result({1:-50},{stress_units:'MPa'})]]);assert.equal(S.build(input([blade()],cases)).rows[0].blade.compressionDemand,50e6);
 assert.equal(build(blade(),{1:{stress_units:'source stress units',stress:{axial:-50}}}).rows[0].reserveFactor,null);
});
test('Minimum reserve factor across independent SOL101 and converged SOL106 cases governs',()=>{
 const a=result({1:-20e6}),b=result({1:-80e6},{analysis:'SOL106_NONLINEAR',loadScale:1,convergence:{converged:true,full_load:true,partial:false}}),r=S.build(input([blade()],new Map([[1,a],[2,b]]))).rows[0];
 assert.equal(r.blade.compressionDemand,80e6);assert.match(r.envelopeCaseLabel,/Load case 2/);assert.equal(r.coverage.total,2);
 assert.equal(S.build(input([blade()],new Map([[1,a],[2,b]]),{caseId:1})).rows[0].blade.compressionDemand,20e6);
});
test('Tension in another load case never cancels a compressive load-case mean',()=>{
 const r=S.build(input([blade()],new Map([[1,result({1:-20e6})],[2,result({1:100e6})]]))).rows[0];assert.equal(r.blade.compressionDemand,20e6);assert.equal(r.blade.noCompression,false);
});
test('Partial force recovery never gives RF 99 or a falsely complete average',()=>{
 const b=blade({bars:[bar(1),bar(2)]}),r=build(b,{1:50e6}).rows[0];assert.equal(r.reserveFactor,null);assert.equal(r.blade.averageStress,null);assert.equal(r.complete,false);assert.equal(r.coverage.recovered,1);assert.equal(r.coverage.total,2);
});
test('Missing cases, stale models, running and dirty states suppress reserve factors',()=>{
 for(const extra of [{modelDirty:true},{pendingDrafts:true},{running:true},{expectedCases:[{id:1,solution:'101'},{id:2,solution:'101'}]},{signature:'changed'},{meshIdentity:8}])assert.equal(build(blade(),{1:50e6},extra).rows[0].reserveFactor,null);
 for(const extra of [{matches:false},{historical:true},{status:'failed'},{available:false}])assert.equal(S.build(input([blade()],new Map([[1,result({1:50e6},extra)]]))).rows[0].reserveFactor,null);
});
test('Unconverged or partial SOL106 results are unassessed',()=>{
 for(const extra of [{convergence:null},{convergence:{converged:false,full_load:true}},{convergence:{converged:true,full_load:false}},{convergence:{converged:true,full_load:true},loadScale:.5}]){
  const r=S.build(input([blade()],new Map([[1,result({1:-50e6},{analysis:'SOL106_NONLINEAR',...extra})]]))).rows[0];assert.equal(r.reserveFactor,null);
 }
});
test('Modal results and normalized buckling modes including their preload are excluded',()=>{
 const buckling=result({1:-1e20},{analysis:'SOL105_BUCKLING',variants:new Map([['sol101',result({1:-1e20})]])}),modal=result({1:-1e20},{analysis:'SOL103_MODAL'}),r=S.build(input([blade()],new Map([[1,result({1:-20e6})],[2,buckling],[3,modal]])));
 assert.equal(r.rows[0].blade.compressionDemand,20e6);assert.equal(r.excludedCases.length,2);assert.equal(r.rows[0].complete,true);
});
test('Unsupported shell blades and malformed or duplicate bar ownership remain unassessed',()=>{
 for(const b of [blade({bars:[],reason:'Shell stringers do not have bar axial stresses.'}),blade({bars:[bar(1),bar(1)]}),blade({bars:[bar(0)]}),blade({bars:[bar(1,{reason:'Unsupported section.'})]})]){const r=build(b,{1:20e6}).rows[0];assert.equal(r.reserveFactor,null);assert.ok(r.reserveFactorReason);}
});
test('Bay and segment rows stay independent when their property ID is shared',()=>{
 const b=blade({panel_id:2,key:'upper:bay2:stringer1:segment1',rib_bay:2}),r=S.build(input([blade(),b],new Map([[1,result({1:-20e6})]])));
 assert.equal(r.rows.length,2);assert.notEqual(r.rows[0].rowKey,r.rows[1].rowKey);assert.equal(r.rows[0].pid,r.rows[1].pid);assert.equal(r.rows[1].locations[0].index,2);assert.equal(r.rows[0].locations[0].part,'stringer_blade');
 const segment=build(blade({segment:2})).rows[0];assert.match(segment.locations[0].cellLabel,/segment 2/);
});
test('The local plate mode ignores column end fixity and unrelated percentile settings',()=>{
 const a=build(),b=build(blade(),{1:-50e6},{eulerFixityCoefficient:4,method:'trimmed_mean',percentile:NaN});assert.equal(a.rows[0].reserveFactor,b.rows[0].reserveFactor);assert.equal(b.method,'mean');
});
test('No metadata produces an explicit unavailable blade report',()=>{
 const r=S.build(input([],new Map([[1,result({1:-20e6})]])));assert.equal(r.rows.length,0);assert.equal(r.complete,false);assert.match(r.note,/No generated PBARL stringer-blade geometry/);
});
test('Exports state the equation, signed equal weighting and critical/mean stress in MPa',()=>{
 const r=build(),t=S.table(r,'reserve');assert.equal(t.title,'Stringer blade instability reserve factors');assert.match(t.headers.join(' '),/Critical stress \(MPa\)/);assert.match(t.headers.join(' '),/Mean compression \(MPa\)/);assert.equal(t.rows[0][4],'50');
 for(const text of [S.csv(r,'reserve'),S.markdown(r,'reserve'),S.html(r,'reserve')]){assert.match(text,/0.425/);assert.match(text,/equal element weights/);assert.match(text,/MPa/);assert.match(text,/Critical EID/);assert.match(text,/Poisson ratio/);}
 assert.match(S.methodLabel(r),/Equal-weight mean signed bar/);
});
test('Standalone blade RF HTML retains threshold colors and high-value dark-orange text',()=>{
 const r=build(blade(),{1:-10e6});r.palette='signed';const text=S.html(r);assert.match(text,/color:#963e00/);assert.match(text,/background:#fff1df/);assert.match(text,/fixed limits 0 to 2/);
 const bad={...r,rows:[{...r.rows[0],reserveFactor:.999}]},good={...r,rows:[{...r.rows[0],reserveFactor:1.001}]};assert.match(S.html(bad),/background:rgb\(242, 150, 158\)/);assert.match(S.html(good),/background:rgb\(153, 190, 236\)/);
});
console.log(passed+' stringer blade data tests passed.');
