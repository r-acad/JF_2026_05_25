'use strict';
const assert=require('node:assert/strict'),E=require('../web/euler_column_data.js'),S=require('../web/stress_report_data.js');
let passed=0;
const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const near=(a,b,tol=1e-12)=>assert.ok(Math.abs(a-b)<=tol*Math.max(Math.abs(b),Number.MIN_VALUE),`${a} != ${b}`);
const rectangle=(b,h,y=0,z=0,modulus=70e9)=>({area_m2:b*h,centroid_y_m:y,centroid_z_m:z,iyy_m4:b*h**3/12,izz_m4:h*b**3/12,iyz_m4:0,young_pa:modulus,material_id:1});
const beam=(eid=1)=>({eid,kind:'beam_axial'}),skin=(eid=2,width=.1,coefficients=[1,0,0])=>({eid,kind:'shell_membrane',width_m:width,coefficients});
const station=(parts=[rectangle(.02,.1)],force_terms=[beam()])=>({id:1,parts,force_terms});
const column=(extra={})=>({panel_id:1,key:'upper:bay1:stringer1:segment1',skin:'upper',rib_bay:1,stringer:1,segment:1,pid:7000001,length_m:2,fixity_coefficient:1,stations:[station()],...extra});
const result=(forces,extra={})=>({analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:'mesh',meshIdentity:7,elementResults:Object.fromEntries(Object.entries(forces).map(([eid,forces])=>[eid,{forces}])),...extra});
const input=(columns,cases,extra={})=>({failureMode:'euler_column',eulerColumns:columns,cases,signature:'mesh',meshIdentity:7,...extra});
const build=(c=column(),forces={1:{axial:-1000}},extra={})=>S.build(input([c],new Map([[1,result(forces)]]),extra));

test('A rectangular pinned column reproduces the analytical weakest-axis Euler load',()=>{
 const section=E.section([rectangle(.02,.1)]);near(section.weakestEI,70e9*.1*.02**3/12);
 const load=E.criticalLoad(section.weakestEI,2);near(load.value,Math.PI**2*70e9*.1*.02**3/(12*4));
 const row=build().rows[0];near(row.reserveFactor,load.value/1000);assert.equal(row.euler.noCompression,false);assert.equal(row.coverage.recovered,1);
});

test('Complete runout geometry never implies an invented Euler end restraint',()=>{
 const reason='This stringer runs out before a rib; a defined runout-end restraint is required.';
 const c=column({status:'unassessed',reason,membership_complete:true,end_restraints_complete:false,member_element_ids:[1]});
 for(const axial of [-1000,1000]){
  const row=build(c,{1:{axial}}).rows[0];
  assert.equal(row.complete,false);assert.equal(row.reserveFactor,null);
  assert.equal(row.coverage.recovered,0);assert.match(row.reserveFactorReason,/runout-end restraint/);
 }
});
test('An integrated T and tributary skin use current geometry and include offset parallel-axis stiffness',()=>{
 // Symmetric about y=0: weakest in-plane EI is the exact sum of each
 // rectangular strip's E*t*b^3/12; the offset flange affects out-of-plane EI.
 const parts=[rectangle(.003,.05,0,.027),rectangle(.04,.004,0,.004),rectangle(.08,.002,-.06,0),rectangle(.08,.002,.06,0)];
 const q=E.section(parts),A=parts.reduce((sum,p)=>sum+p.area_m2,0),zc=(.003*.05*.027+.04*.004*.004)/A;
 near(q.centroidY,0);near(q.centroidZ,zc);near(q.area,A);
 const iyy=.003*.05**3/12+.003*.05*(.027-zc)**2+.04*.004**3/12+.04*.004*(.004-zc)**2+2*(.08*.002**3/12+.08*.002*zc**2);
 const izz=.05*.003**3/12+.004*.04**3/12+2*(.002*.08**3/12+.08*.002*.06**2);
 near(q.weakestEI,70e9*Math.min(iyy,izz));assert.ok(q.centroidZ>0);
});
test('Different isotropic moduli use the stiffness centroid rather than an unweighted centroid',()=>{
 const a=rectangle(.01,.02,-.05,0,70e9),b=rectangle(.01,.02,.05,0,140e9),s=E.section([a,b]);
 near(s.centroidY,.05/3);near(s.centroidZ,0);near(s.EIyy,3*70e9*.01*.02**3/12);
});
test('Common section translation does not change Euler stiffness',()=>{
 const parts=[rectangle(.003,.05,0,.025),rectangle(.1,.002,0,0)],a=E.section(parts),b=E.section(parts.map(p=>({...p,centroid_y_m:p.centroid_y_m+37,centroid_z_m:p.centroid_z_m-19})));
 near(a.weakestEI,b.weakestEI,2e-12);near(b.centroidY,37);
});
test('Rotating a section leaves its weakest principal stiffness invariant',()=>{
 const p=rectangle(.02,.1),t=.71,c=Math.cos(t),s=Math.sin(t),rotated={...p,iyy_m4:c*c*p.iyy_m4+s*s*p.izz_m4,izz_m4:s*s*p.iyy_m4+c*c*p.izz_m4,iyz_m4:c*s*(p.iyy_m4-p.izz_m4)};
 near(E.section([rotated]).weakestEI,E.section([p]).weakestEI);
});
test('A very thin rectangular blade retains its resolved small principal inertia',()=>{
 const s=E.section([rectangle(1e-8,.2)]);near(s.weakestEI,70e9*.2*(1e-8)**3/12);
});
test('A coupled laminate section eliminates extension by its full Schur complement',()=>{
 const p={area_m2:.1,material_ids:[1,8],axial_matrix:[[100,10,0],[10,4,0],[0,0,9]]},s=E.section([p]);
 near(s.weakestEI,3);near(s.centroidY,.1);near(s.centroidZ,0);assert.deepEqual(s.materialIds,[1,8]);
 const opposite={...p,axial_matrix:[[100,-10,0],[-10,4,0],[0,0,9]]},both=E.section([p,opposite]);
 // Opposed B coupling cancels in the assembled section: its effective
 // stiffness is 8, not the sum 3+3 of independently condensed strips.
 near(both.weakestEI,8);near(both.centroidY,0);
});
test('Coupled section matrices are invariant under translations and section-axis rotations',()=>{
 const K=[[100,10,5],[10,4,1],[5,1,9]],part={area_m2:.1,axial_matrix:K},initial=E.section([part]);
 const transpose=A=>A[0].map((_,i)=>A.map(r=>r[i])),multiply=(A,B)=>A.map(r=>B[0].map((_,j)=>r.reduce((sum,x,k)=>sum+x*B[k][j],0)));
 // Expressing old epsilon0 = new epsilon0 + dy*gradient_y + dz*gradient_z
 // is a pure choice of section reference, not a material or shape change.
 const T=[[1,.7,-.4],[0,1,0],[0,0,1]],shifted=multiply(transpose(T),multiply(K,T));
 near(E.section([{...part,axial_matrix:shifted}]).weakestEI,initial.weakestEI);
 const a=.43,c=Math.cos(a),s=Math.sin(a),R=[[1,0,0],[0,c,-s],[0,s,c]],rotated=multiply(transpose(R),multiply(K,R));
 near(E.section([{...part,axial_matrix:rotated}]).weakestEI,initial.weakestEI);
});
test('Nonsymmetric, indefinite and singular coupled stiffness matrices are rejected',()=>{
 for(const K of [[[100,10,0],[9,4,0],[0,0,9]],[[100,20,0],[20,3,0],[0,0,9]],[[100,0,0],[0,1,2],[0,2,1]],[[0,0,0],[0,1,0],[0,0,1]],[[100,0,0],[0,0,0],[0,0,0]]])assert.ok(E.section([{area_m2:.1,axial_matrix:K}]).reason);
});
test('Isotropic rectangle geometry and its full section matrix give the same stiffness',()=>{
 const p=rectangle(.02,.1,.03,.04),EA=p.young_pa*p.area_m2,y=p.centroid_y_m,z=p.centroid_z_m;
 const K=[[EA,EA*y,EA*z],[EA*y,p.young_pa*p.izz_m4+EA*y*y,p.young_pa*p.iyz_m4+EA*y*z],[EA*z,p.young_pa*p.iyz_m4+EA*y*z,p.young_pa*p.iyy_m4+EA*z*z]];
 near(E.section([{area_m2:p.area_m2,axial_matrix:K}]).weakestEI,E.section([p]).weakestEI);
});
test('Fixity scales critical load linearly and unbraced length quadratically',()=>{
 const s=E.section([rectangle(.02,.1)]).weakestEI,P=E.criticalLoad(s,2).value;
 near(E.criticalLoad(s,2,4).value,4*P);near(E.criticalLoad(s,4).value,P/4);
 near(build(column(),{1:{axial:-1000}},{eulerEndFactor:.25}).rows[0].reserveFactor,P/4000);
 for(const factor of [0,-1,Infinity,NaN,'1'])assert.ok(E.criticalLoad(s,2,factor).reason);
});
test('Invalid, singular and unsupported section definitions remain unassessed',()=>{
 for(const parts of [[],[rectangle(0,.1)],[{...rectangle(.1,.1),young_pa:null}],[{...rectangle(.1,.1),iyz_m4:1}],[{...rectangle(.1,.1),reason:'Orthotropic laminate requires another criterion.'}],[{...rectangle(.1,.1),iyy_m4:0,izz_m4:0}]])assert.ok(E.section(parts).reason);
 const row=build(column({reason:'Run-out has no supported full-rib restraint.'}),{1:{axial:0}}).rows[0];assert.equal(row.reserveFactor,null);assert.equal(row.complete,false);assert.match(row.reserveFactorReason,/Run-out/);
});
test('Beam and signed shell membrane resultants combine once at the same section',()=>{
 const row=build(column({stations:[station([rectangle(.02,.1)],[beam(),skin()])]}),{1:{axial:-1000},2:{fx:-2000,fy:10000,fxy:200}}).rows[0];
 assert.equal(row.euler.compressionDemand,1200);near(row.reserveFactor,row.euler.criticalLoad/1200);
 const tension=E.axialForce([beam(),skin()],{'1':{forces:{axial:-1000}},'2':{forces:{fx:20000,fy:0,fxy:0}}});assert.equal(tension.compression,0);assert.equal(tension.signedForce,1000);
});
test('Shell forces use rotated directional membrane resultants rather than equivalent stress',()=>{
 const f=E.forceTerm(skin(2,.2,[.5,.5,1]),{2:{forces:{fx:-100,fy:-300,fxy:20},stress:{z1:{von_mises:1e20}}}});near(f.value,-36);
 const projected=E.forceTerm(skin(2,.2,[.4,.4,.8]),{2:{forces:{fx:-100,fy:-300,fxy:20}}});near(projected.value,.8*f.value);
});
test('Multiple spanwise stations are checked separately, never summed longitudinally',()=>{
 const c=column({stations:[station(),{...station([rectangle(.02,.1)],[beam(2)]),id:2}]}),row=build(c,{1:{axial:-1000},2:{axial:-2000}}).rows[0];
 assert.equal(row.euler.compressionDemand,2000);assert.equal(row.euler.governingStation,2);near(row.reserveFactor,row.euler.criticalLoad/2000);assert.equal(row.coverage.total,2);
});
test('Weak local section can govern even when another station has larger compression',()=>{
 const c=column({stations:[station(),{...station([rectangle(.01,.1)],[beam(2)]),id:2}]}),row=build(c,{1:{axial:-2000},2:{axial:-1000}}).rows[0];
 assert.equal(row.euler.governingStation,2);assert.equal(row.euler.compressionDemand,1000);assert.equal(row.euler.maximumCompression,2000);
});
test('The minimum reserve factor is taken across all eligible static and nonlinear cases',()=>{
 const a=result({1:{axial:-1000}}),b=result({1:{axial:-2500}},{analysis:'SOL106_NONLINEAR',loadScale:1,convergence:{converged:true,full_load:true,partial:false}}),r=S.build(input([column()],new Map([[1,a],[2,b]])));
 assert.equal(r.rows[0].euler.compressionDemand,2500);assert.match(r.rows[0].envelopeCaseLabel,/Load case 2/);assert.equal(r.rows[0].coverage.total,2);
 assert.equal(S.build(input([column()],new Map([[1,a],[2,b]]),{caseId:1})).rows[0].euler.compressionDemand,1000);
});
test('RF 99 is reserved for fully recovered cases with no compressive column demand',()=>{
 const r=S.build(input([column()],new Map([[1,result({1:{axial:0}})],[2,result({1:{axial:3000}})]]))).rows[0];assert.equal(r.reserveFactor,99);assert.equal(r.euler.noCompression,true);assert.match(r.euler.note,/not a computed failure load multiplier/);
 const compressed=build(column(),{1:{axial:-1e-30}}).rows[0];assert.equal(compressed.euler.noCompression,false);assert.ok(compressed.reserveFactor>1e30);
});
test('Only relative cancellation noise is treated as non-compressive',()=>{
 const f=E.axialForce([beam(1),beam(2)],{1:{forces:{axial:1e6}},2:{forces:{axial:-1e6-1e-9}}});assert.equal(f.compression,0);
 const tiny=E.axialForce([beam(1)],{1:{forces:{axial:-1e-50}}});assert.equal(tiny.compression,1e-50);
});
test('Missing forces, failed cases, missing cases and dirty models never receive a reserve factor',()=>{
 const base=input([column()],new Map([[1,result({})]]));assert.equal(S.build(base).rows[0].reserveFactor,null);
 for(const extra of [{modelDirty:true},{pendingDrafts:true},{running:true},{expectedCases:[{id:1,solution:'101'},{id:2,solution:'101'}]}])assert.equal(build(column(),{1:{axial:1000}},extra).rows[0].reserveFactor,null);
 const partial=result({1:{axial:1000}},{analysis:'SOL106_NONLINEAR',loadScale:.5,convergence:{converged:false,full_load:false,partial:true}});assert.equal(S.build(input([column()],new Map([[1,partial]]))).rows[0].reserveFactor,null);
});
test('Buckling preload and modal shapes never enter the static column-demand envelope',()=>{
 const parent=result({1:{axial:-1e12}},{analysis:'SOL105_BUCKLING',modeKind:'buckling',variants:new Map([['sol101',result({1:{axial:-1e12}})]])});
 const r=S.build(input([column()],new Map([[1,result({1:{axial:-1000}})],[2,parent]])));assert.equal(r.rows[0].euler.compressionDemand,1000);assert.equal(r.excludedCases.length,1);
});
test('Duplicated beam force sources and incomplete membrane components are rejected',()=>{
 assert.match(E.axialForce([beam(),beam()],{1:{forces:{axial:-1000}}}).reason,/more than once/);
 assert.match(E.axialForce([skin()],{2:{forces:{fx:-1000}}}).reason,/missing signed shell/);
 assert.match(E.axialForce([beam()],{1:{stress:{axial:-1e10}}}).reason,/no recovered force/);
});
test('Physical stringer rows remain distinct even if two bays reuse a property',()=>{
 const a=column(),b=column({panel_id:2,key:'upper:bay2:stringer1:segment1',rib_bay:2});
 const r=S.build(input([a,b],new Map([[1,result({1:{axial:-1000}})]])));assert.equal(r.rows.length,2);assert.notEqual(r.rows[0].rowKey,r.rows[1].rowKey);assert.equal(r.rows[0].pid,r.rows[1].pid);assert.equal(r.rows[1].locations[0].index,2);assert.equal(r.rows[0].locations[0].part,'stringer_column');
});
test('Exports describe Euler load, fixity, length and compression with no false stress units',()=>{
 const r=build(),t=S.table(r,'reserve');assert.equal(r.failureMode,'euler_column');assert.match(t.headers.join(' '),/Critical load \(N\)/);assert.match(t.headers.join(' '),/Unbraced length \(m\)/);assert.ok(!t.headers.some(h=>/MPa/.test(h)));
 for(const text of [S.csv(r,'reserve'),S.markdown(r,'reserve'),S.html(r,'reserve')]){assert.match(text,/Euler/);assert.match(text,/end-fixity|End-fixity/);assert.match(text,/1000/);assert.match(text,/Weakest EI/);}
 assert.match(S.methodLabel(r),/Minimum reserve factor/);
});
test('HTML export honors the selected palette and fixed RF saturation with readable high-value ink',()=>{
 const r=build(),rf=require('../web/reserve_factor_table_data.js');r.palette='grayscale';
 const html=S.html(r,'reserve'),bounds=rf.scale(r.rows.map(row=>({pid:row.pid,value:row.reserveFactor})));
 assert.ok(html.includes('background:'+rf.valueColor(r.rows[0].reserveFactor,bounds,'grayscale')));assert.match(html,/color:#963e00/);assert.match(html,/background:#fff1df/);assert.match(html,/Color scale: grayscale/);
 const nearLimit={...r,palette:'signed',rows:[{...r.rows[0],reserveFactor:1}]};assert.match(S.html(nearLimit,'reserve'),/background:rgb\(245, 246, 248\)/);
});
test('Euler selection ignores stress averaging and percentile controls',()=>{
 const a=build(),b=build(column(),{1:{axial:-1000}},{method:'trimmed_mean',percentile:1});assert.equal(a.rows[0].reserveFactor,b.rows[0].reserveFactor);assert.equal(b.method,'maximum');
});
test('Live fixity override uses the canonical field and invalid values stay unassessed',()=>{
 const a=build(),b=build(column(),{1:{axial:-1000}},{eulerFixityCoefficient:4});near(b.rows[0].reserveFactor,4*a.rows[0].reserveFactor);
 const invalid=build(column(),{1:{axial:1000}},{eulerFixityCoefficient:NaN});assert.equal(invalid.rows[0].reserveFactor,null);assert.match(invalid.rows[0].reserveFactorReason,/fixity/);
});
test('No physical metadata produces an empty, explicit unavailable column report',()=>{
 const r=S.build(input([],new Map([[1,result({1:{axial:-1000}})]])));assert.deepEqual(r.rows,[]);assert.equal(r.complete,false);assert.match(r.note,/No generated stringer-column geometry/);
});
console.log(passed+' Euler column data tests passed.');
