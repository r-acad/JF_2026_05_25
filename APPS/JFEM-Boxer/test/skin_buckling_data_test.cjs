'use strict';
const assert=require('node:assert/strict'),P=require('../web/skin_buckling_data.js'),S=require('../web/stress_report_data.js');
let passed=0;const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const near=(a,b,tol=1e-10)=>assert.ok(Math.abs(a-b)<=tol*Math.max(Math.abs(b),Number.MIN_VALUE),`${a} != ${b}`);
const D=[[1,.3,0],[.3,1,0],[0,0,.35]],I=[[1,0,0],[0,1,0],[0,0,1]];
const element=(eid=1,extra={})=>({eid,pid:5000001,area_m2:1,thickness_m:.002,material_ids:[1],stress_transform:I,bending_matrix_Nm:D,...extra});
const panel=(extra={})=>({key:'upper:bay1:strip1',skin:'upper',rib_bay:1,strip_index:1,label:'Upper R1–R2 · Front spar–Stringer 1',boundary_labels:['Front spar','Stringer 1'],property_ids:[5000001],panel_ids:[1],length_m:1,width_m:1,fixity_coefficient:1,elements:[element()],...extra});
const result=(forces,extra={})=>({analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:'mesh',meshIdentity:7,elementResults:Object.fromEntries(Object.entries(forces).map(([eid,force])=>[eid,{forces:force}])),...extra});
const input=(panels,cases,extra={})=>({failureMode:'skin_buckling',skinBucklingPanels:panels,cases,signature:'mesh',meshIdentity:7,...extra});
const build=(p=panel(),forces={1:{fx:-1,fy:0,fxy:0}},extra={})=>S.build(input([p],new Map([[1,result(forces)]]),extra));
test('Square isotropic uniaxial and biaxial compression recover analytical simply supported eigenvalues',()=>{
 const a=P.solvePlate(1,1,D,[1,0,0]),b=P.solvePlate(1,1,D,[1,1,0]);near(a.reserveFactor,4*Math.PI**2);near(b.reserveFactor,2*Math.PI**2);assert.equal(a.modeM,1);assert.equal(a.modeN,1);assert.equal(a.convergenceError,0);
});
test('High aspect-ratio compression uses the actual integer half-wave count',()=>{
 const r=P.solvePlate(100,1,D,[1,0,0]);near(r.reserveFactor,4*Math.PI**2);assert.equal(r.modeM,100);assert.equal(r.modeN,1);
 const noninteger=P.solvePlate(2.4,1,D,[1,0,0]);near(noninteger.reserveFactor,Math.PI**2*((2/2.4)**2+1)**2/(2/2.4)**2);assert.equal(noninteger.modeM,2);
});
test('Rotated-isotropic coupling roundoff does not disable the exact high-aspect-ratio solution',()=>{
 const d=[[1,.3,1e-16],[.3,1,-2e-16],[1e-16,-2e-16,.35]],r=P.solvePlate(100,1,d,[1,0,3e-16]);near(r.reserveFactor,4*Math.PI**2);assert.equal(r.modeM,100);assert.equal(r.convergenceError,0);
});
test('Transverse tension stabilizes the plate and changes the governing integer mode',()=>{
 const r=P.solvePlate(1,1,D,[1,-1,0]);near(r.reserveFactor,25*Math.PI**2/3);assert.equal(r.modeM,2);assert.equal(r.modeN,1);assert.ok(r.reserveFactor>4*Math.PI**2);
});
test('The exact integer search includes interior m,n modes for strongly coupled orthotropic bending',()=>{
 const d=[[1,-.9998,0],[-.9998,1,0],[0,0,.00005]],r=P.solvePlate(1.5,1,d,[1,0,0]);assert.equal(r.converged,true);assert.equal(r.modeM,3);assert.equal(r.modeN,2);near(r.reserveFactor,.0006*(2*Math.PI)**2,1e-8);
});
test('Pure shear converges near the published square and aspect-two plate results',()=>{
 const square=P.solvePlate(1,1,D,[0,0,1]),long=P.solvePlate(2,1,D,[0,0,1]);assert.equal(square.converged,true);assert.equal(long.converged,true);near(square.reserveFactor,92.0308307211,.001);near(long.reserveFactor,64.6077016711,.001);assert.ok(square.history.length>=3);assert.ok(square.convergenceError<.005);
});
test('Shear reversal is invariant for isotropic plates but not arbitrarily for anisotropic coupling',()=>{
 near(P.solvePlate(1.3,1,D,[.4,.1,.9]).reserveFactor,P.solvePlate(1.3,1,D,[.4,.1,-.9]).reserveFactor);
 const d=[[2,.4,.15],[.4,1,.08],[.15,.08,.5]],positive=P.solvePlate(1.7,1,d,[.7,-.2,.8]),negative=P.solvePlate(1.7,1,d,[.7,-.2,-.8]);assert.equal(positive.converged,true);assert.equal(negative.converged,true);assert.ok(Math.abs(positive.reserveFactor-negative.reserveFactor)>1e-3);
});
test('Simultaneous normal and shear terms form one coupled eigenproblem',()=>{
 const r=P.solvePlate(1,1,D,[1,.4,.6]),normal=P.solvePlate(1,1,D,[1,.4,0]),shear=P.solvePlate(1,1,D,[0,0,.6]);assert.equal(r.converged,true);assert.ok(r.reserveFactor<normal.reserveFactor);assert.ok(r.reserveFactor<shear.reserveFactor);
});
test('Plate capacity scales linearly with bending stiffness and inversely with every membrane load',()=>{
 const a=P.solvePlate(1,1,D,[1,.4,.6]),b=P.solvePlate(1,1,D.map(r=>r.map(x=>2*x)),[1,.4,.6]),c=P.solvePlate(1,1,D,[2,.8,1.2]);near(b.reserveFactor,2*a.reserveFactor);near(c.reserveFactor,a.reserveFactor/2);
});
test('Exact analytical integration includes D16/D26 terms and both shear parity sectors',()=>{
 const d=[[2,.4,.15],[.4,1,.08],[.15,.08,.5]],m=P.buildMatrices(1,1,d,2,2),i=0,j=3;
 near(m.gxy[i*4+j],-128/9);near(m.bending[i*4+j],-640*Math.PI**2/9*(.15+.08));assert.equal(m.gxy[0*4+1],0);assert.equal(m.gxy[0*4+2],0);
 near(m.bending[0],(2+2*(.4+2*.5)+1)*Math.PI**4);
});
test('Largest algebraic eigenvalue is found despite a much larger negative eigenvalue',()=>{
 near(P.largestEigenvalue([2,0,0,-10000],2),2);near(P.largestEigenvalue([2,1,1,2],2),3);near(P.largestEigenvalue([-2,0,0,-1],2),-1);assert.equal(P.largestEigenvalue([0,0,0,0],2),0);
 const q=Math.SQRT1_2,A=[-4999,5001,5001,-4999];near(P.largestEigenvalue(A,2),2,1e-9);assert.equal(P.largestEigenvalue([NaN],1),null);
});
test('Invalid dimensions and nonpositive or nonsymmetric plate matrices remain unassessed',()=>{
 for(const args of [[0,1,D],[1,NaN,D],[1,1,[[1,2,0],[2,1,0],[0,0,1]]],[1,1,[[1,0,1],[0,1,0],[0,0,1]]],[1,1,[[0,0,0],[0,0,0],[0,0,0]]]])assert.ok(P.solvePlate(...args,[1,0,0]).reason);
});
test('A truncated unconverged basis never yields a usable reserve factor, including cache replay',()=>{
 const a=P.solvePlate(1,1,D,[0,0,1],{maxDimension:9}),b=P.solvePlate(1,1,D,[0,0,1],{maxDimension:9});assert.equal(a.converged,false);assert.equal(a.reserveFactor,null);assert.match(a.reason,/not converged/);assert.equal(b.reserveFactor,null);
});
test('Only a non-destabilizing mean membrane tensor receives RF 99',()=>{
 for(const n of [[0,0,0],[-1,-2,0],[-10,-10,1]]){const r=P.solvePlate(1,1,D,n);assert.equal(r.reserveFactor,99);assert.equal(r.noDestabilizingLoad,true);}
 const shear=P.solvePlate(1,1,D,[-1,-1,2]);assert.equal(shear.converged,true);assert.notEqual(shear.noDestabilizingLoad,true);assert.notEqual(shear.reserveFactor,99);
 const tiny=P.solvePlate(1,1,D,[1e-20,-1,0]);assert.notEqual(tiny.noDestabilizingLoad,true);
});
test('Area weighting is independent of element count and uses actual membrane resultants',()=>{
 const p=panel({elements:[element(1,{area_m2:1}),element(2,{area_m2:3})]}),r=build(p,{1:{fx:-10,fy:4,fxy:2},2:{fx:-30,fy:8,fxy:6}}).rows[0];near(r.skinBuckling.averageStressX,-25/.002);near(r.skinBuckling.averageStressY,7/.002);near(r.skinBuckling.averageShear,5/.002);assert.deepEqual(r.skinBuckling.membraneResultants,[-25,7,5]);
});
test('Varying thickness uses mean N, not mean thickness multiplied by mean stress',()=>{
 const p=panel({elements:[element(1,{thickness_m:.001}),element(2,{thickness_m:.003})]}),r=build(p,{1:{fx:-10,fy:0,fxy:0},2:{fx:-60,fy:0,fxy:0}}).rows[0];near(r.skinBuckling.averageStressX,-15000);near(r.skinBuckling.membraneResultants[0],-35);near(r.reserveFactor,4*Math.PI**2/35);assert.notEqual(-15000*.002,-35);
});
test('Full stress transforms preserve signed shear and rotate recovered material-frame resultants',()=>{
 const T=[[0,1,0],[1,0,0],[0,0,-1]],prepared=P.preparePanel(panel({elements:[element(1,{stress_transform:T})]})),r=P.panelDemand(prepared,{1:{forces:{fx:-2,fy:-8,fxy:3}}});assert.deepEqual(r.membrane,[-8,-2,-3]);assert.deepEqual(r.compressionResultants,[8,2,3]);
});
test('Stiffness is area averaged, including anisotropic off-diagonal terms',()=>{
 const d=[[2,.4,.15],[.4,1,.08],[.15,.08,.5]],p=P.preparePanel(panel({elements:[element(1,{area_m2:1,bending_matrix_Nm:d}),element(2,{area_m2:3,bending_matrix_Nm:d.map(r=>r.map(x=>2*x))})]}));for(let i=0;i<9;i++)near(p.D[i],1.75*d.flat()[i]);
});
test('Skin fixity multiplies plate stiffness only and does not reuse Euler fixity',()=>{
 const a=build(),b=build(panel(),{1:{fx:-1,fy:0,fxy:0}},{skinFixityCoefficient:4,eulerFixityCoefficient:99});near(b.rows[0].reserveFactor,4*a.rows[0].reserveFactor);assert.equal(b.rows[0].skinBuckling.fixityCoefficient,4);
 for(const c of [0,-1,NaN,Infinity])assert.equal(build(panel(),{1:{fx:1,fy:0,fxy:0}},{skinFixityCoefficient:c}).rows[0].reserveFactor,null);
});
test('The worst eligible physical SOL101/SOL106 case governs without averaging different cases',()=>{
 const a=result({1:{fx:-1,fy:0,fxy:0}}),b=result({1:{fx:-2,fy:0,fxy:0}},{analysis:'SOL106_NONLINEAR',loadScale:1,convergence:{converged:true,full_load:true,partial:false}}),r=S.build(input([panel()],new Map([[1,a],[2,b]]))).rows[0];near(r.reserveFactor,2*Math.PI**2);assert.match(r.envelopeCaseLabel,/Load case 2/);assert.equal(r.coverage.total,2);
 const selected=S.build(input([panel()],new Map([[1,a],[2,b]]),{caseId:1})).rows[0];near(selected.reserveFactor,4*Math.PI**2);
});
test('No-destabilizing sentinels do not govern a different case with a physical RF above 99',()=>{
 const cases=new Map([[1,result({1:{fx:1,fy:1,fxy:0}})],[2,result({1:{fx:-.1,fy:0,fxy:0}})]]),r=S.build(input([panel()],cases)).rows[0];near(r.reserveFactor,40*Math.PI**2);assert.equal(r.skinBuckling.noDestabilizingLoad,false);
});
test('Missing resultants or unsupported topology never receive a passing RF',()=>{
 for(const forces of [{},{1:{fx:-1,fy:0}},{1:{fx:NaN,fy:0,fxy:0}}])assert.equal(build(panel(),forces).rows[0].reserveFactor,null);
 assert.equal(build(panel({reason:'Run-out compartment is not four-sided.'})).rows[0].reserveFactor,null);
 const r=build(panel({elements:[element(1),element(2)]}),{1:{fx:1,fy:1,fxy:0}}).rows[0];assert.equal(r.coverage.recovered,1);assert.equal(r.coverage.total,2);assert.equal(r.reserveFactor,null);
});
test('Complete mean stresses remain visible when an extreme plate basis cannot converge',()=>{
 const r=build(panel({length_m:1000}),{1:{fx:-2,fy:-1,fxy:4}}).rows[0];assert.equal(r.reserveFactor,null);assert.equal(r.complete,false);assert.equal(r.coverage.recovered,r.coverage.total);assert.equal(r.skinBuckling.averageStressX,-1000);assert.equal(r.skinBuckling.averageStressY,-500);assert.equal(r.skinBuckling.averageShear,2000);assert.ok(r.reasons.some(x=>/not converged/.test(x.reason)));
});
test('No peak stress or unknown-unit force fallback is accepted',()=>{
 const p=P.preparePanel(panel());assert.equal(P.panelDemand(p,{1:{stress:{z1:{normal_x:-1e10},z2:{normal_x:-1e10}}}}).complete,false);assert.equal(P.panelDemand(p,{1:{forces:{fx:-1,fy:0,fxy:0},force_units:{fx:'lbf/in'}}}).complete,false);
});
test('Missing, failed, stale and partial nonlinear cases prevent complete assessment',()=>{
 for(const extra of [{modelDirty:true},{running:true},{pendingDrafts:true},{signature:'changed'},{expectedCases:[{id:1,solution:'101'},{id:2,solution:'101'}]}])assert.equal(build(panel(),{1:{fx:1,fy:1,fxy:0}},extra).rows[0].reserveFactor,null);
 const nonlinear=result({1:{fx:-1,fy:0,fxy:0}},{analysis:'SOL106',convergence:{converged:true,full_load:false}});assert.equal(S.build(input([panel()],new Map([[1,nonlinear]]))).rows[0].reserveFactor,null);
});
test('Modal and buckling preload variants remain outside this static assessment',()=>{
 const preload=result({1:{fx:-1e20,fy:0,fxy:0}},{analysis:'SOL105_BUCKLING',variants:new Map([['sol101',result({1:{fx:-1e20,fy:0,fxy:0}})]])}),r=S.build(input([panel()],new Map([[1,result({1:{fx:-1,fy:0,fxy:0}})],[2,preload]])));near(r.rows[0].reserveFactor,4*Math.PI**2);assert.equal(r.excludedCases.length,1);
});
test('Physical compartments retain distinct rows and all actual properties even with shared PIDs',()=>{
 const a=panel(),b=panel({key:'upper:bay1:strip2',strip_index:2,property_ids:[5000001,5000002],boundary_labels:['Stringer 1','Stringer 2']}),r=S.build(input([a,b],new Map([[1,result({1:{fx:-1,fy:0,fxy:0}})]])));assert.equal(r.rows.length,2);assert.notEqual(r.rows[0].rowKey,r.rows[1].rowKey);assert.deepEqual(r.rows[1].propertyIds,[5000001,5000002]);assert.equal(r.rows[1].locations[0].stripIndex,2);assert.equal(r.rows[1].locations[0].part,'skin_panel');
});
test('Unassessed runout compartments retain a visible heading when boundary labels are unavailable',()=>{
 const p=panel({boundary_labels:[],label:'Front spar–S1 runout',reason:'Run-out compartment is not four-sided.'}),r=build(p).rows[0];assert.equal(r.reserveFactor,null);assert.equal(r.locations[0].rowLabel,'Front spar–S1 runout');
 assert.equal(P.panelLocations(panel({boundary_labels:['S1'],label:''}))[0].rowLabel,'Skin strip 1');
 assert.match(S.csv(build(p)),/transverse-shear deformation/);assert.match(S.csv(build(p)),/sandwich-face wrinkling/);assert.match(S.csv(build(p)),/core instability/);
});
test('Duplicate elements, missing matrices and malformed geometry fail explicitly',()=>{
 for(const p of [panel({elements:[]}),panel({elements:[element(),element()]}),panel({elements:[element(1,{thickness_m:0})]}),panel({elements:[element(1,{stress_transform:[]})]}),panel({elements:[element(1,{bending_matrix_Nm:[]})]})])assert.ok(P.preparePanel(p).reason);
});
test('Plate mode ignores unrelated percentile trimming and empty models explain applicability',()=>{
 const a=build(),b=build(panel(),{1:{fx:-1,fy:0,fxy:0}},{method:'trimmed_mean',percentile:NaN});assert.equal(a.rows[0].reserveFactor,b.rows[0].reserveFactor);assert.equal(b.method,'area_mean');const empty=S.build(input([],new Map()));assert.equal(empty.complete,false);assert.match(empty.note,/No actual skin-panel geometry/);
});
test('All exports include signed MPa membrane stresses, dimensions, fixity and convergence',()=>{
 const r=build(),t=S.table(r,'reserve');assert.match(t.title,/Skin-panel buckling/);assert.match(t.headers.join(' '),/Mean spanwise stress \(MPa\)/);for(const text of [S.csv(r),S.markdown(r),S.html(r)]){assert.match(text,/fixity coefficient/);assert.match(text,/Average length/);assert.match(text,/refinement/);assert.match(text,/membrane/);}assert.match(S.html(r),/color:#963e00/);
});
test('Geometry/eigen caches are bounded and repeated calls preserve the same answer',()=>{
 const before=P.cacheInfo(),a=P.solvePlate(1.3,1,D,[.4,.1,.9]),b=P.solvePlate(1.3,1,D,[.4,.1,.9]);assert.deepEqual(a,b);const after=P.cacheInfo();assert.ok(after.matrixBytes<=after.matrixByteLimit);assert.ok(after.resultEntries<=after.resultLimit);assert.ok(after.matrixEntries<=128);assert.ok(after.resultEntries>=before.resultEntries);
});
console.log(passed+' skin-panel buckling data tests passed.');
