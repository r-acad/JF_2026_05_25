'use strict';
// Independent postprocessing checks: absolute physical stresses/engineering
// ply strains, signed allowables, complete recovery, and mesh coverage.
const assert=require('node:assert/strict');
const A=require('../web/material_allowables.js');
const mat1={id:1,type:'MAT1',name:'Metal'},mat8={id:8,type:'MAT8',name:'UD ply'};
const stressLimit={material_id:1,mode:'stress',stress:250e6};
const strainLimits={material_id:8,mode:'strain',e1_t:.01,e1_c:.006,e2_t:.004,e2_c:.008,g12:.02};
const shell={type:'PSHELL',material_id:1,material:mat1},solid={type:'PSOLID',material:mat1};
const laminate={type:'PCOMP',plies:[{material_id:8,material:mat8},{material_id:8,material:mat8}]};
const zero=()=>({e1:0,e2:0,g12:0});
const face=(ply,mid,bottom=zero(),top=zero())=>({ply,material_id:mid,bottom,top});
const recovered=(faces,key='strain')=>({[key]:{ply_faces:faces,ply_faces_complete:true,ply_faces_coordinate_system:'ply material 1/2 axes'}});
const near=(actual,expected)=>assert(Math.abs(actual-expected)<=1e-12*Math.max(1,Math.abs(expected)),`${actual} != ${expected}`);
const unassessed=(value,pattern)=>{assert.equal(value.utilization,undefined);assert.match(value.reason,pattern);};
let passed=0;const failures=[];
function check(name,fn){try{fn();passed++;console.log('PASS '+name);}catch(error){failures.push({name,error});console.error('FAIL '+name+'\n'+error.stack);}}

check('MAT1 shell uses the largest recovered von Mises value, not signed normal stress',()=>{
 const result=A.assessElement(shell,{stress:{z1:{normal_x:900e6,von_mises:150e6},z2:{normal_x:-1e9,von_mises:300e6}}},[stressLimit]);
 near(result.utilization,1.2);near(result.reserve_factor,5/6);near(result.margin,-1/6);
 assert.equal(result.demand,300e6);assert.equal(result.allowable,250e6);assert.equal(result.face,'z2');assert.equal(result.material_id,1);
});
check('Solid integration-point recovery uses the governing sample',()=>{
 const result=A.assessElement(solid,{stress:{centroid:{von_mises:100e6},integration_points:[{von_mises:125e6},{von_mises:200e6}]}},new Map([[1,stressLimit]]));
 near(result.utilization,.8);near(result.margin,.25);assert.equal(result.face,'integration_points / 1');
});
check('Beam axial and bending stresses are not substituted for unavailable equivalent stress',()=>{
 unassessed(A.assessElement({type:'PBARL',material:mat1},{stress:{axial:300e6,smax:500e6,torsion:50e6}},[stressLimit]),/von Mises.*not recovered/i);
});
check('Missing shell faces and invalid equivalent stresses do not produce a passing comparison',()=>{
 unassessed(A.assessElement(shell,{stress:{z1:{von_mises:1e6}}},[stressLimit]),/Both shell-face/);
 for(const von_mises of [-1,NaN,Infinity])unassessed(A.assessElement(solid,{stress:{centroid:{von_mises:1e6},integration_points:[{von_mises}]}},[stressLimit]),/Invalid equivalent stress/);
});
check('Longitudinal tensile and compressive ply strain use their own positive limits',()=>{
 const p={type:'PCOMP',plies:[laminate.plies[0]]};
 for(const [e1,expected,sign]of [[.005,.5,'tension'],[-.0045,.75,'compression']]){
  const result=A.assessElement(p,recovered([face(1,8,zero(),{e1,e2:0,g12:0})]),[strainLimits]);
  near(result.utilization,expected);assert.match(result.component,new RegExp(sign));assert.equal(result.face,'top');assert.equal(result.demand,e1);
 }
});
check('Transverse tensile and compressive strain use different limits',()=>{
 const p={type:'PCOMP',plies:[laminate.plies[0]]};
 for(const [e2,expected,sign]of [[.006,1.5,'tension'],[-.004,.5,'compression']]){
  const result=A.assessElement(p,recovered([face(1,8,{e1:0,e2,g12:0})]),[strainLimits]);
  near(result.utilization,expected);assert.match(result.component,new RegExp('Transverse '+sign));assert.equal(result.face,'bottom');
 }
});
check('Engineering shear gamma12 is compared directly, without a tensor-shear factor of two',()=>{
 const result=A.assessElement(laminate,recovered([face(1,8),face(2,8,zero(),{e1:.001,e2:-.001,g12:-.015})]),[strainLimits]);
 near(result.utilization,.75);assert.equal(result.demand,-.015);assert.equal(result.allowable,.02);assert.match(result.component,/engineering shear/);assert.equal(result.ply,2);
});
check('All ply faces are checked and the maximum normalized demand governs',()=>{
 const mat9={id:9,type:'MAT8'},limit9={...strainLimits,material_id:9,e2_c:.002};
 const p={type:'PCOMP',plies:[laminate.plies[0],{material_id:9,material:mat9},laminate.plies[0]]};
 const record=recovered([face(3,8,{e1:.009,e2:0,g12:0}),face(1,8,zero(),{e1:.003,e2:0,g12:.01}),face(2,9,{e1:0,e2:-.003,g12:0})]);
 const result=A.assessElement(p,record,[strainLimits,limit9]);near(result.utilization,1.5);assert.equal(result.material_id,9);assert.equal(result.ply,2);assert.equal(result.face,'bottom');near(result.margin,-1/3);
});
check('A mixed MAT1/MAT8 laminate evaluates each ply with its own basis',()=>{
 const p={type:'PCOMP',plies:[{material_id:1,material:mat1},laminate.plies[0]]};
 const record={...recovered([face(2,8,{e1:.008,e2:0,g12:0})]),...recovered([face(1,1,{von_mises:125e6},{von_mises:275e6})],'stress')};
 const result=A.assessElement(p,record,[stressLimit,strainLimits]);near(result.utilization,1.1);assert.equal(result.material_id,1);assert.equal(result.ply,1);assert.equal(result.face,'top');
});
check('Missing material, allowable, or incompatible material basis remains unassessed',()=>{
 unassessed(A.assessElement(null,{},[]),/definition unavailable/i);
 unassessed(A.assessElement(shell,{},[]),/No allowable for material 1/);
 unassessed(A.assessElement(shell,{},[{...strainLimits,material_id:1}]),/MAT1 or ply strain for MAT8/);
 unassessed(A.assessElement(laminate,{},[{material_id:8,mode:'stress',stress:1e8}]),/MAT1 or ply strain for MAT8/);
 unassessed(A.assessElement({type:'PSHELL',material:mat8},recovered([face(1,8)]),[strainLimits]),/require a laminate/);
});
check('Ply identity must match both ply index and material ID',()=>{
 unassessed(A.assessElement(laminate,recovered([face(1,8),face(2,9)]),[strainLimits]),/recovery unavailable/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8),{ply:2,bottom:zero(),top:zero()}]),[strainLimits]),/recovery unavailable/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8),face(1,8)]),[strainLimits]),/recovery unavailable/i);
});
check('A missing limit, ply, face or strain component prevents a partial passing assessment',()=>{
 const missingLimit={...strainLimits};delete missingLimit.e2_c;
 unassessed(A.assessElement(laminate,recovered([face(1,8),face(2,8)]),[missingLimit]),/incomplete strain limits/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8)]),[strainLimits]),/recovery unavailable/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8),{ply:2,material_id:8,bottom:zero()}]),[strainLimits]),/incomplete.*recovery/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8),face(2,8,zero(),{e1:0,e2:0})]),[strainLimits]),/incomplete.*recovery/i);
 unassessed(A.assessElement(laminate,recovered([face(1,8),face(2,8,zero(),{e1:NaN,e2:0,g12:0})]),[strainLimits]),/incomplete.*recovery/i);
});
check('Explicitly incomplete or wrong-coordinate recovery cannot be assessed as material-axis strain',()=>{
 const incomplete=recovered([face(1,8),face(2,8)]);incomplete.strain.ply_faces_complete=false;
 unassessed(A.assessElement(laminate,incomplete,[strainLimits]),/incomplete|unavailable/i);
 const wrongBasis=recovered([face(1,8),face(2,8)]);wrongBasis.strain.ply_faces_coordinate_system='global xyz';
 unassessed(A.assessElement(laminate,wrongBasis,[strainLimits]),/axes|coordinate|basis|unavailable/i);
 const missingBasis=recovered([face(1,8),face(2,8)]);delete missingBasis.strain.ply_faces_coordinate_system;
 unassessed(A.assessElement(laminate,missingBasis,[strainLimits]),/axes|coordinate|basis|unavailable/i);
});
check('Zero demand produces zero utilization without a fictitious finite reserve factor',()=>{
 for(const result of [A.assessElement(shell,{stress:{z1:{von_mises:0},z2:{von_mises:0}}},[stressLimit]),A.assessElement(laminate,recovered([face(1,8),face(2,8)]),[strainLimits])]){
  assert.equal(result.utilization,0);assert.equal(result.reserve_factor,null);assert.equal(result.margin,null);
 }
});
check('Allowable rows reject duplicate IDs, unsupported basis and nonpositive or nonfinite limits',()=>{
 assert.equal(A.validate([stressLimit,strainLimits]).length,2);assert.deepEqual(A.validate([]),[]);
 for(const invalid of [null,{},[stressLimit,stressLimit],[{...stressLimit,material_id:0}],[{...stressLimit,material_id:1.5}],[{...stressLimit,mode:'auto'}],...[0,-1,NaN,Infinity,'250000000',null].map(stress=>[{...stressLimit,stress}])])assert.throws(()=>A.validate(invalid));
 assert.deepEqual(A.missing({material_id:1,mode:'stress'}),['stress']);assert.deepEqual(A.missing({material_id:8,mode:'strain'}),['e1_t','e1_c','e2_t','e2_c','g12']);
});
check('Coverage includes real quad/tria/solid/bar kinds and counts unassessed reasons without coloring gaps',()=>{
 const element=(kind,pid,properties,name)=>({group:{kind,pid,properties,name}});
 const elements=new Map([[101,element('quad',10,shell)],[102,element('tria',11,laminate)],[103,element('solid',12,solid)],[104,element('bar',13,{type:'PBAR',material:mat1})],[105,element('quad',14,{type:'PSHELL',material:{id:99,type:'MAT1'}})],[106,element('tria',15,{type:'PSHELL',material:{id:99,type:'MAT1'}})],[107,element('quad',16,shell,'aero')],[108,element('rbe3',0,null)],[109,element('spring',20,null)]]);
 const records={101:{stress:{z1:{von_mises:125e6},z2:{von_mises:100e6}}},102:recovered([face(1,8),face(2,8,zero(),{e1:0,e2:.005,g12:0})]),103:{stress:{von_mises:0}},104:{stress:{axial:1e6}}};
 const result=A.build(elements,records,[stressLimit,strainLimits]);
 assert.equal(result.total,6);assert.equal(result.assessed,3);assert.equal(result.details.size,6);assert.equal(result.reasons.size,2);assert.equal(result.reasons.get('No allowable for material 99.'),2);
 assert.deepEqual([...result.contour.byId.keys()],[101,102,103]);near(result.contour.byId.get(101),.5);near(result.contour.byId.get(102),1.25);assert.equal(result.contour.byId.get(103),0);assert.equal(result.contour.min,0);near(result.contour.max,1.25);assert.equal(result.worst.eid,102);assert.equal(result.worst.pid,11);assert.match(result.contour.note,/3 \/ 6/);
});
check('No usable result leaves an empty contour and no governing element',()=>{
 const result=A.build(new Map([[1,{group:{kind:'quad',properties:shell}}]]),{},[stressLimit]);
 assert.equal(result.total,1);assert.equal(result.assessed,0);assert.equal(result.worst,null);assert.equal(result.contour.byId.size,0);assert.equal(result.contour.min,0);assert.equal(result.contour.max,0);
});
check('Material catalogue deduplicates ply and homogeneous materials in ID order',()=>{
 assert.deepEqual(A.materialsFromGroups([{properties:laminate},{properties:shell},{properties:{type:'PCOMP',plies:[{material:mat1},{material:mat8}]}},{kind:'rbe3'}]).map(m=>m.id),[1,8]);
});
console.log(`Material allowables: ${passed} checks passed; ${failures.length} failed.`);
if(failures.length)process.exitCode=1;
