'use strict';
const assert=require('node:assert/strict'),S=require('../web/stress_report_data.js');
const mat={id:1,type:'MAT1'},shell={type:'PSHELL',material_id:1,material:mat},solid={type:'PSOLID',material:mat};
const limit={material_id:1,mode:'stress',stress:300e6};
const stress=(a,b=a)=>({stress:{z1:{von_mises:a},z2:{von_mises:b}}});
const element=(pid=10,property=shell,kind='quad',name='SKIN')=>({group:{pid,properties:property,kind,name}});
const result=(records,extra={})=>({analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:'model',meshIdentity:4,elementResults:records,...extra});
const nonlinear=records=>result(records,{analysis:'SOL106_NONLINEAR',convergence:{converged:true,full_load:true,partial:false},loadScale:1});
const context=(cases,elements=new Map([[1,element()],[2,element()],[3,element()]]))=>({cases,elements,allowables:[limit],signature:'model',meshIdentity:4});
const samples=values=>values.map((value,i)=>({value,eid:i+1,face:'z2'}));
const near=(actual,expected)=>assert(Math.abs(actual-expected)<=1e-12*Math.max(1,Math.abs(expected)),`${actual} != ${expected}`);
let passed=0,failed=0;
function check(name,fn){try{fn();passed++;console.log('PASS '+name);}catch(error){failed++;console.error('FAIL '+name+'\n'+error.stack);}}

check('Maximum reports the face peak and never substitutes a signed normal stress',()=>{
 const a=S.stressSample(shell,{stress:{z1:{normal_x:-1e10,von_mises:10},z2:{normal_x:1e12,von_mises:20}}});assert.equal(a.demand,20);assert.equal(a.face,'z2');
 const b=S.stressSample(solid,{stress:{centroid:{von_mises:11},integration_points:[{von_mises:8},{von_mises:25}]}});assert.equal(b.demand,25);
});
check('Shell recovery is complete on both faces and malformed stresses remain unavailable',()=>{
 assert.match(S.stressSample(shell,{stress:{z1:{von_mises:1}}}).reason,/Both shell-face/);
 for(const value of [-1,NaN,Infinity,null,'3'])assert(S.stressSample(solid,{stress:{centroid:{von_mises:5},points:[{von_mises:value}]}}).reason);
 assert.match(S.stressSample({type:'PBAR',material:mat},{stress:{axial:500,smax:1000}}).reason,/not recovered/);
});
check('Aggregation uses one governing recovered stress per element, not one sample per face',()=>{
 const c=result({1:stress(10,30),2:stress(20,10),3:stress(50,20)}),report=S.build({...context(new Map([[1,c]])),method:'mean'}),row=report.rows[0];
 near(row.envelopeStress,100/3);assert.equal(row.maxStress,50);assert.equal(row.maxEid,3);assert.equal(row.maxFace,'z1');assert.equal(row.envelopeEid,null);
});
check('Each load case is aggregated separately before the worst case is selected',()=>{
 const c1=result({1:stress(0),2:stress(0),3:stress(90)}),c2=result({1:stress(40),2:stress(40),3:stress(40)});
 const report=S.build({...context(new Map([[1,c1],[2,c2]])),method:'mean',caseLabels:new Map([[1,'Peaked'],[2,'Uniform']])}),row=report.rows[0];
 assert.equal(row.maxStress,90);assert.match(row.maxCaseLabel,/Peaked/);assert.equal(row.envelopeStress,40);assert.match(row.envelopeCaseLabel,/Uniform/);assert.equal(row.coverage.recovered,6);assert.equal(row.coverage.total,6);
});
check('A percentile means averaging samples below its interpolated cutoff, including ties',()=>{
 const p=S.aggregate(samples([10,20,30,1000]),'trimmed_mean',75);near(p.cutoff,272.5);assert.equal(p.envelope,20);assert.equal(p.maximum,1000);assert.equal(p.retained,3);assert.equal(p.discarded,1);
 const tied=S.aggregate(samples([10,20,20,20,1000]),'trimmed_mean',75);assert.equal(tied.cutoff,20);assert.equal(tied.retained,4);near(tied.envelope,17.5);
 const symmetric=S.aggregate(samples([284985.36719754105,284985.36719754146,320715.86429084453,320715.8642908447]),'trimmed_mean',95);assert.equal(symmetric.retained,4);near(symmetric.envelope,302850.61574419297);
 const all=S.aggregate(samples([10,20,30,1000]),'trimmed_mean',100);near(all.envelope,265);assert.equal(all.discarded,0);
});
check('A one-element region remains a one-element region at every supported percentile',()=>{
 for(const p of [.1,50,95,100]){const a=S.aggregate(samples([123]),'trimmed_mean',p);assert.equal(a.envelope,123);assert.equal(a.maximum,123);assert.equal(a.retained,1);}
 for(const p of [0,-1,NaN,Infinity,101,'95'])assert.throws(()=>S.aggregate(samples([123]),'trimmed_mean',p));
 assert.throws(()=>S.aggregate(samples([1]),'percentile',95));assert.throws(()=>S.aggregate(samples([-1]),'mean'));
});
check('Means avoid overflowing the sum of otherwise finite positive stresses',()=>{
 near(S.aggregate(samples([1e308,1e308,1e308]),'mean').envelope,1e308);assert.equal(S.aggregate([]).envelope,null);
 for(const n of [3,7,100])assert.equal(S.aggregate(samples(Array(n).fill(Number.MAX_VALUE)),'mean').envelope,Number.MAX_VALUE);
});
check('The independent raw maximum remains visible when top peaks are excluded',()=>{
 const report=S.build({...context(new Map([[1,result({1:stress(1e6),2:stress(3e6),3:stress(100e6)})]])),method:'trimmed_mean',percentile:50});
 const row=report.rows[0];assert.equal(row.maxStress,100e6);assert.equal(row.envelopeStress,2e6);assert.equal(row.caseResults[0].discarded,1);assert.equal(row.reserveFactor,150);
});
check('A material limit is divided by the governing stress, with MPa shown only for generated SI data',()=>{
 const base=context(new Map([[1,result({1:stress(150e6)})]]),new Map([[1,element()]])),report=S.build(base),row=report.rows[0];assert.equal(row.reserveFactor,2);assert.equal(report.stressUnit,'MPa');assert.equal(report.stressFactor,1e-6);assert.equal(S.table(report).rows[0][2],'150');
 const imported=S.build({...base,sourceUnits:true});assert.equal(imported.stressUnit,'source stress units');assert.equal(imported.stressFactor,1);assert.equal(imported.rows[0].reserveFactor,2);
});
check('Zero demand has zero stress and no invented finite reserve factor',()=>{
 const report=S.build(context(new Map([[1,result({1:stress(0)})]]),new Map([[1,element()]]))),row=report.rows[0];assert.equal(row.envelopeStress,0);assert.equal(row.reserveFactor,null);assert.match(row.reserveFactorReason,/Zero stress/);assert.equal(row.complete,true);
});
check('Partial element coverage preserves measured peaks but cannot produce a reserve factor',()=>{
 const report=S.build(context(new Map([[1,result({1:stress(5e6),2:stress(10e6)})]]))),row=report.rows[0];assert.equal(row.maxStress,10e6);assert.equal(row.status,'partial');assert.equal(row.reserveFactor,null);assert.deepEqual(row.coverage,{recovered:2,total:3});assert.equal(row.reasons[0].count,1);assert.equal(report.complete,false);
});
check('Missing requested load cases invalidate coverage without erasing available stresses',()=>{
 const report=S.build({...context(new Map([[1,result({1:stress(10e6)})]]),new Map([[1,element()]])),expectedCases:[{id:1,label:'First'},{id:2,label:'Missing'},{id:3,enabled:false}]});assert.equal(report.rows[0].maxStress,10e6);assert.equal(report.missingCases.length,1);assert.equal(report.rows[0].reserveFactor,null);assert.deepEqual(report.rows[0].coverage,{recovered:1,total:2});
});
check('A missing requested nonlinear solution cannot be hidden by its completed linear comparison',()=>{
 const report=S.build({...context(new Map([[1,result({1:stress(10e6)})]]),new Map([[1,element()]])),expectedCases:[{id:1,solution:'106',name:'Nonlinear case'}]});assert.equal(report.missingCases.length,1);assert.match(report.missingCases[0].reason,/No SOL106/);assert.equal(report.rows[0].reserveFactor,null);
 assert.equal(S.analysisNumber({analysis:'SOL20101'}),null);assert.equal(S.analysisNumber({analysis:'SOL101_STATIC'}),101);assert.equal(S.analysisNumber({solution:106}),106);
});
check('Selecting one case removes unrelated missing cases from that explicitly scoped report',()=>{
 const report=S.build({...context(new Map([[1,result({1:stress(10e6)})],[2,result({1:stress(20e6)})]]),new Map([[1,element()]])),caseId:2,expectedCases:[{id:1},{id:2},{id:3}]});assert.equal(report.rows[0].maxStress,20e6);assert.equal(report.includedCases.length,1);assert.equal(report.complete,true);assert.equal(report.missingCases.length,0);
});
check('SOL106 and its full-load linear comparison are distinct physical cases without duplicate wrappers',()=>{
 const linear=result({1:stress(50e6)},{loadScale:1}),nonlinearCase=nonlinear({1:stress(100e6)}),parent={...nonlinearCase,variants:new Map([['sol101',linear],['sol106',nonlinearCase]])};
 const report=S.build(context(new Map([[4,parent]]),new Map([[1,element()]])));assert.equal(report.includedCases.length,2);assert.match(report.includedCases[0].label,/linear comparison/);assert.equal(report.rows[0].maxStress,100e6);assert.equal(report.rows[0].reserveFactor,3);
});
check('Partial SOL106 states and scaled SOL101 comparisons never yield a passing report',()=>{
 const partial=nonlinear({1:stress(1e6)});partial.convergence.full_load=false;partial.convergence.partial=true;const parent={...partial,variants:new Map([['sol101',result({1:stress(2e6)},{loadScale:.4})],['sol106',partial]])};
 const report=S.build(context(new Map([[1,parent]]),new Map([[1,element()]])));assert.equal(report.includedCases.length,0);assert.equal(report.excludedCases.length,2);assert.equal(report.rows[0].reserveFactor,null);assert.equal(report.rows[0].status,'unavailable');
 const missingHistory=nonlinear({});delete missingHistory.convergence;assert.match(S.caseReason(missingHistory),/convergence record/);
});
check('SOL103 modes and SOL105 parents including preload are explicitly outside the report',()=>{
 const buckling=result({1:stress(1e9)},{analysis:'SOL105_BUCKLING',modeKind:'buckling',variants:new Map([['sol101',result({1:stress(1e9)})]])}),modal=result({1:stress(1e20)},{analysis:'SOL103_MODES',modeKind:'frequency'});
 const report=S.build(context(new Map([[1,result({1:stress(20e6)})],[2,buckling],[3,modal]]),new Map([[1,element()]])));assert.equal(report.includedCases.length,1);assert.equal(report.excludedCases.length,2);assert.equal(report.rows[0].maxStress,20e6);assert.equal(report.rows[0].reserveFactor,15);
});
check('Stale, mismatched, running, failed and unverified results are reported as excluded',()=>{
 for(const patch of [{matches:false},{historical:true},{signature:'old'},{meshIdentity:99},{available:false},{status:'failed'},{status:'partial'},{static:null},{validationIssues:['Wrong mesh']}]){const report=S.build(context(new Map([[1,result({1:stress(1e6)},patch)]]),new Map([[1,element()]])));assert.equal(report.includedCases.length,0);assert.equal(report.rows[0].maxStress,null);assert.equal(report.rows[0].reserveFactor,null);}
 for(const flag of ['modelDirty','pendingDrafts','running']){const report=S.build({...context(new Map([[1,result({1:stress(1e6)})]]),new Map([[1,element()]])),[flag]:true});assert.equal(report.includedCases.length,0);assert.equal(report.rows[0].reserveFactor,null);}
});
check('An archive with unknown original analysis does not infer SOL101 from its static shape',()=>{
 const archive=result({1:stress(1e6)},{analysis:'STATIC (stored)',source:'disk_results'}),report=S.build(context(new Map([[1,archive]]),new Map([[1,element()]])));assert.equal(report.includedCases.length,0);assert.match(report.excludedCases[0].reason,/explicitly identified|archive/i);
});
check('Laminate or mixed material regions do not receive an invented isotropic allowable',()=>{
 const laminate={type:'PCOMP',plies:[{material_id:8,material:{id:8,type:'MAT8'}}]},mixed={...shell,material_id:2,material:{id:2,type:'MAT1'}};
 assert.match(S.propertyAllowable([laminate],[limit]).reason,/Laminate/);assert.match(S.propertyAllowable([shell,mixed],[limit]).reason,/different materials/);assert.match(S.stressSample(laminate,stress(1)).reason,/Laminate/);
 const report=S.build(context(new Map([[1,result({1:stress(10e6),2:stress(20e6)})]]),new Map([[1,element(10,shell)],[2,element(10,mixed)]])));assert.equal(report.rows[0].maxStress,20e6);assert.equal(report.rows[0].reserveFactor,null);assert.match(report.rows[0].reserveFactorReason,/different materials/);
});
check('A PSHELL with different membrane and bending material IDs has no invented common reserve factor',()=>{
 const property={...shell,material_ids:[1,2],material_roles:{MID:1,MID2:2}},report=S.build(context(new Map([[1,result({1:stress(12e6)})]]),new Map([[1,element(10,property)]])));assert.equal(report.rows[0].maxStress,12e6);assert.equal(report.rows[0].reserveFactor,null);assert.deepEqual(report.rows[0].materialIds,[1,2]);assert.match(report.rows[0].reserveFactorReason,/membrane, bending/);
});
check('Absent, duplicate, invalid and incompatible allowables preserve stress but leave reserve factor unassessed',()=>{
 for(const limits of [[],[limit,limit],[{...limit,stress:0}],[{...limit,stress:-1}],[{...limit,stress:Infinity}],[{...limit,stress:'300e6'}],[{...limit,mode:'strain'}]]){const report=S.build({...context(new Map([[1,result({1:stress(10e6)})]]),new Map([[1,element()]])),allowables:limits});assert.equal(report.rows[0].maxStress,10e6);assert.equal(report.rows[0].reserveFactor,null);assert.match(report.rows[0].reserveFactorReason,/positive von Mises/);}
});
check('Property ownership combines split display groups and excludes loads and connections',()=>{
 const elements=new Map([[1,element(20,shell,'quad','UPPER')],[2,element(20,shell,'tria','LOWER')],[3,element(10,solid,'solid','VOLUME')],[4,element(80,shell,'quad','aero')],[5,element(90,null,'rbe3')]]),report=S.build(context(new Map([[1,result({1:stress(1e6),2:stress(2e6),3:{stress:{von_mises:3e6}}})]]),elements));assert.deepEqual(report.rows.map(row=>row.pid),[10,20]);assert.equal(report.rows[1].elementCount,2);assert.deepEqual(report.rows[1].names,['UPPER','LOWER']);assert.equal(report.coverage.total,3);
});
check('Report exports carry method and coverage, escape unsafe labels and limit significant digits',()=>{
 const report=S.build({...context(new Map([[1,result({1:stress(1.23456789e6)})]]),new Map([[1,element()]])),caseLabels:new Map([[1,'=bad | <script>alert(1)</script>']])});
 const csv=S.csv(report),md=S.markdown(report),html=S.html(report);assert(csv.includes('1.2346'));assert(csv.includes("'=bad"));assert(md.includes('\\|'));assert(!html.includes('<script>alert'));assert(html.includes('&lt;script&gt;'));assert(csv.includes('Envelope method: Maximum'));assert(md.includes('Coverage'));assert(html.includes('Missing recovery'));
 assert(S.csv(report,'reserve').includes('Reserve factor'));assert(S.markdown(report,'reserve').includes('Allowable (MPa)'));
});
check('Color ranges follow actual finite table values and do not color unavailable cells',()=>{
 const report=S.build(context(new Map([[1,result({1:stress(1e6),2:stress(5e6)})]]),new Map([[1,element(1)],[2,element(2)]]))),scale=S.colorScales(report);assert.equal(scale.min,1e6);assert.equal(scale.max,5e6);assert.equal(scale.count,2);assert.equal(scale.color(null),null);assert.equal(scale.color(2e6).length,3);const reserve=S.colorScales(report,'reserve');assert.equal(reserve.min,60);assert.equal(reserve.max,300);
});
check('Inputs are read-only and results do not retain full result records',()=>{
 const input=context(new Map([[1,result({1:stress(10e6)})]]),new Map([[1,element()]])),before=JSON.stringify([...input.cases]);const report=S.build(input);assert.equal(JSON.stringify([...input.cases]),before);assert.equal(report.includedCases[0].result,undefined);assert.doesNotThrow(()=>JSON.stringify(report));
});
console.log(JSON.stringify({passed,failed}));if(failed)process.exitCode=1;
