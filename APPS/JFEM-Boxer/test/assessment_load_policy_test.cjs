'use strict';
const assert=require('node:assert/strict'),P=require('../web/assessment_load_policy.js'),S=require('../web/stress_report_data.js'),A=require('../web/material_allowables.js'),E=require('../web/euler_column_data.js'),B=require('../web/stringer_blade_data.js'),K=require('../web/skin_buckling_data.js'),C=require('../web/component_buckling_data.js'),M=require('../web/minimum_rf_data.js'),I=require('../web/rf_incremental.js'),Snapshot=require('../web/stress_report_snapshot.js'),Sizing=require('../web/rf_sizing_estimate.js');
const Field=require('../web/rf_field_data.js'),RF=require('../web/reserve_factor_table_data.js');
let passed=0;const check=(name,fn)=>{fn();passed++;console.log('PASS '+name);},near=(a,b,t=1e-11)=>assert(Math.abs(a-b)<=t*Math.max(Math.abs(b),1e-200),`${a} != ${b}`);
const policy=(strength=1.5,buckling=1)=>({assessmentPolicy:{strengthSafetyFactor:strength,bucklingPolicyFactor:buckling}});
const material={id:1,type:'MAT1',E_Pa:70e9,nu:.3},property={type:'PSHELL',thickness_m:.002,material_id:1,material},element=(pid=10,p=property)=>({nodes:[0,1,2,3],group:{pid,kind:'quad',name:'Upper skin',properties:p}});
const vm=n=>({stress:{z1:{von_mises:n},z2:{von_mises:n}},forces:{fx:-1,fy:0,fxy:0}});
const result=(records,extra={})=>({analysis:'SOL101',status:'complete',available:true,matches:true,static:{},signature:'model',meshIdentity:'mesh',elementResults:records,...extra});
const context=(extra={})=>({elements:new Map([[1,element()]]),cases:new Map([[1,result({1:vm(100e6)})]]),allowables:[{material_id:1,mode:'stress',stress:300e6}],signature:'model',meshIdentity:'mesh',generated:false,studyEpoch:1,...extra});
const cases=records=>({included:[{caseId:1,caseKey:'1:default',label:'Limit maneuver',solution:101,result:result(records)}],excluded:[],missing:[],complete:true});
const D=[[1,.3,0],[.3,1,0],[0,0,.35]],T=[[1,0,0],[0,1,0],[0,0,1]],section={area_m2:.0004,centroid_y_m:0,centroid_z_m:0,iyy_m4:.02**4/12,izz_m4:.02**4/12,iyz_m4:0,young_pa:70e9,material_id:1};
const column={key:'c',pid:10,panel_id:1,skin:'upper',rib_bay:1,stringer:1,length_m:1,stations:[{id:1,parts:[section],force_terms:[{eid:1,pid:10,kind:'beam_axial'}]}]};
const blade={key:'b',pid:10,panel_id:1,skin:'upper',rib_bay:1,stringer:1,bars:[{eid:1,pid:10,web_height_m:.03,web_thickness_m:.002,young_pa:70e9,poisson:.3,material_id:1,material_type:'MAT1',source:'PBARL',section_shape:'T'}]};
const panel={key:'p',skin:'upper',rib_bay:1,strip_index:1,length_m:1,width_m:1,property_ids:[10],elements:[{eid:1,pid:10,area_m2:1,thickness_m:.002,material_ids:[1],stress_transform:T,bending_matrix_Nm:D,normalized_vertices_uv:[[0,0],[1,0],[1,1],[0,1]]}]};

check('Defaults distinguish strength1.5 from buckling1; input forms validate finite positive factors',()=>{
 assert.deepEqual(P.read(),{strengthSafetyFactor:1.5,bucklingPolicyFactor:1});assert.deepEqual(P.read({'assessment.strength_safety_factor':2,'assessment.buckling_policy_factor':1.2}),{strengthSafetyFactor:2,bucklingPolicyFactor:1.2});assert.equal(P.divide(null,1.2),null);assert.equal(P.divide(undefined,1.2),null);
 for(const key of ['strengthSafetyFactor','bucklingPolicyFactor'])for(const bad of [0,-1,Infinity,NaN,'1.5'])assert.throws(()=>P.read({assessmentPolicy:{[key]:bad}}),/finite.*greater than zero/);
});
check('Default ultimate strength RF uses1.5 once and leaves recovered LIMIT stress and force unchanged',()=>{
 const input=context(),before=JSON.stringify([...input.cases]),r=S.build(input),row=r.rows[0];near(row.reserveFactor,2);assert.equal(row.envelopeStress,100e6);assert.equal(row.assessmentStress,150e6);assert.equal(row.maxStress,100e6);assert.equal(JSON.stringify([...input.cases]),before);assert.match(r.note,/ULTIMATE strength demand = LIMIT demand/);
 for(const sf of [1,1.5,2.25]){const x=S.build({...input,...policy(sf,7)});near(x.rows[0].reserveFactor,3/sf);assert.equal(x.rows[0].envelopeStress,100e6);}
});
check('Principal tensile/compressive strains use strength factor and retain physical signed strain',()=>{
 const mat8={id:8,type:'MAT8'},p={type:'PCOMP',plies:[{material_id:8,material:mat8}]},limits=[{material_id:8,mode:'strain',strain_tension:.01,strain_compression:.006}];
 for(const strain of [.005,-.003]){const record={strain:{ply_faces_complete:true,ply_faces_coordinate_system:'ply material 1/2 axes',ply_faces:[{ply:1,material_id:8,bottom:{e1:0,e2:0,g12:0},top:{e1:strain,e2:0,g12:0}}]}};
  const a=A.assessElement(p,record,limits),b=A.assessElement(p,record,limits,policy(2,9));near(a.utilization,.75);near(a.reserve_factor,4/3);near(b.reserve_factor,1);assert.equal(a.demand,strain);near(a.ultimate_demand,1.5*strain);
  const report=S.build(context({elements:new Map([[1,element(10,p)]]),cases:new Map([[1,result({1:record})]]),allowables:limits,failureMode:'principal_strain'}));near(report.rows[0].reserveFactor,4/3);assert.equal(report.rows[0].principalStrain.demand,strain);
 }
});
check('Maximum, mean and percentile retain LIMIT envelopes while scaling the strength RF',()=>{
 const input=context({elements:new Map([[1,element()],[2,element()],[3,element()]]),cases:new Map([[1,result({1:vm(10),2:vm(20),3:vm(100)})]]),allowables:[{material_id:1,mode:'stress',stress:300}]});
 for(const [method,expected]of [['maximum',100],['mean',130/3],['trimmed_mean',15]]){const r=S.build({...input,method,percentile:50,...policy(2,5)}).rows[0];near(r.envelopeStress,expected);near(r.reserveFactor,300/expected/2);}
});
check('Stringer Euler and blade RFs use buckling policy only, preserving critical capacity and LIMIT demand',()=>{
 const cc=cases({1:{forces:{axial:-1000}}}),bc=cases({1:{stress:{axial:-10e6}}});
 for(const [input,build,rawCases]of [[{eulerColumns:[column]},E.build,cc],[{stringerBlades:[blade]},B.build,bc]]){
  const a=build({...input,...policy(1,1)},rawCases).rows[0],b=build({...input,...policy(6,1.25)},rawCases).rows[0];near(b.reserveFactor,a.reserveFactor/1.25);
  if(a.euler){assert.equal(b.euler.criticalLoad,a.euler.criticalLoad);assert.equal(b.euler.compressionDemand,a.euler.compressionDemand);near(b.caseResults[0].stations[0].assessmentCompressionDemand,1250);}
  else{assert.equal(b.blade.criticalStress,a.blade.criticalStress);assert.equal(b.blade.averageStress,a.blade.averageStress);near(b.caseResults[0].assessmentCompressionDemand,12.5e6);}
 }
});
check('Skin biaxial/shear buckling policy scales one signed geometric demand, never strength safety',()=>{
 const cc=cases({1:{forces:{fx:-1,fy:-.3,fxy:.2}}}),a=K.build({skinBucklingPanels:[panel],...policy(1,1)},cc).rows[0],b=K.build({skinBucklingPanels:[panel],...policy(8,1.4)},cc).rows[0];near(b.reserveFactor,a.reserveFactor/1.4);assert.deepEqual(b.skinBuckling.membraneResultants,a.skinBuckling.membraneResultants);assert.equal(b.skinBuckling.averageShear,a.skinBuckling.averageShear);
 if(a.caseResults[0].history.length)near(b.caseResults[0].history.at(-1).reserveFactor,a.caseResults[0].history.at(-1).reserveFactor/1.4);
});
check('Every spar/rib/cap/stiffener mode follows the common buckling policy',()=>{
 const metadata={web_panels:['spar_web','rib_web'].map((kind,i)=>({...panel,key:kind,kind,membership_complete:true,member_element_ids:[1],label:kind})),columns:['spar_cap','rib_stiffener'].map(kind=>({...column,key:kind,kind,property_ids:[10],membership_complete:true,member_element_ids:[1]})),blades:[{...blade,key:'stiffener',kind:'rib_stiffener_blade',property_ids:[10],membership_complete:true,member_element_ids:[1]}]},cc=cases({1:{forces:{axial:-1000,fx:-1,fy:0,fxy:0},stress:{axial:-10e6}}});
 for(const mode of Object.keys(C.MODES)){const a=C.build({componentBuckling:metadata,failureMode:mode,...policy(1,1)},cc),b=C.build({componentBuckling:metadata,failureMode:mode,...policy(5,1.5)},cc);assert(a.rows.length);near(b.rows[0].reserveFactor,a.rows[0].reserveFactor/1.5);assert.equal(b.assessmentFactor,1.5);assert.match(b.note,/strength safety factor does not enter buckling/);}
});
check('No-compression and no-destabilizing sentinels stay99 under any assessment factor',()=>{
 const cc=cases({1:{forces:{axial:1000,fx:1,fy:1,fxy:0},stress:{axial:10e6}}});
 for(const r of [E.build({eulerColumns:[column],...policy(3,4)},cc),B.build({stringerBlades:[blade],...policy(3,4)},cc),K.build({skinBucklingPanels:[panel],...policy(3,4)},cc)])assert.equal(r.rows[0].reserveFactor,99);
 const missing={...cc,included:[{...cc.included[0],result:result({})}]};assert.equal(E.build({eulerColumns:[column],...policy(3,4)},missing).rows[0].reserveFactor,null);
});
check('Combined per-case VM assessment does not undo the strength safety factor',()=>{
 const input=context({...policy(2,1),failureMode:'minimum_rf'}),r=S.build(input),row=r.rows[0],criterion=row.combined.assessments.find(a=>a.failureMode==='von_mises');near(row.reserveFactor,1.5);near(criterion.reserveFactor,1.5);near(criterion.caseResults[0].reserveFactor,1.5);assert.equal(criterion.assessmentFactor,2);assert.match(S.csv(r),/ULTIMATE strength demand/);
});
check('Policy edits invalidate report and incremental caches without altering physical result identity',()=>{
 const input=context({...policy(1,1)}),r=S.build(input),updated={...input,...policy(2,1),estimated:true};assert(S.currentContext(r,input));assert(!S.currentContext(r,updated));const x=I.build(updated,r,input);near(x.rows[0].reserveFactor,1.5);assert.equal(x.incremental,undefined);assert.equal(updated.cases,input.cases);assert.equal(updated.signature,input.signature);
});
check('Sizing projections retain current policy and recompute RFs at the held LIMIT internal loads',()=>{
 const base=context({...policy(1,1),generated:true,signature:'[["properties.t_skin_upper",0.002]]',layoutToken:'same',expectedCases:[{id:1,solution:101}],panels:[],componentGroups:[]});base.cases.get(1).signature=base.signature;const current={...base,...policy(2,1.2),signature:'[["properties.t_skin_upper",0.004]]',definitionSignature:'[["properties.t_skin_upper",0.004]]',meshIdentity:'edited',elements:new Map([[1,element(10,{...property,thickness_m:.004})]]),cases:new Map()};
 base.cases.get(1).elementResults[1]={forces:{fx:200e3,fy:0,fxy:0,mx:0,my:0,mxy:0},stress:vm(100e6).stress};const projected=Sizing.project(base,current);assert(projected.estimated,projected.reason);assert.deepEqual(projected.context.assessmentPolicy,current.assessmentPolicy);near(S.build(projected.context).rows[0].reserveFactor,3);const records=projected.context.cases.get(1).elementResults;assert.equal((records.get(1)||records.get('1')).forces.fx,200e3);
});
check('Snapshot policy is retained independently and current factor-only edits update assessment provenance',()=>{
 const input=context({...policy(1,1)}),snap=Snapshot.create(),first=snap.select(input);input.assessmentPolicy={strengthSafetyFactor:2,bucklingPolicyFactor:1.3};const selected=snap.select(input);assert(!selected.stale);assert.notEqual(first.source,selected.source);near(S.build(selected.context).rows[0].reserveFactor,1.5);input.modelDirty=true;input.assessmentPolicy.strengthSafetyFactor=4;assert.equal(snap.select(input).context.assessmentPolicy.strengthSafetyFactor,2);
});
check('Buckling RF matches the stated LIMIT examples and a custom policy factor',()=>{
 const capacity=E.criticalLoad(E.section([section]).weakestEI,1).value;
 for(const limitMultiple of [1,1.5]){const cc=cases({1:{forces:{axial:-capacity/limitMultiple}}});near(E.build({eulerColumns:[column]},cc).rows[0].reserveFactor,limitMultiple);near(E.build({eulerColumns:[column],...policy(7,1.25)},cc).rows[0].reserveFactor,limitMultiple/1.25);}
});
check('Cached spatial bounds and converged case RFs use the same policy and preserve certificates',()=>{
 const cell=(eid,v0,v1)=>({...panel.elements[0],eid,area_m2:v1-v0,normalized_vertices_uv:[[0,v0],[1,v0],[1,v1],[0,v1]]}),web={...panel,kind:'spar_web',key:'narrow',member_element_ids:[1,2],membership_complete:true,elements:[cell(1,0,.01),cell(2,.01,1)]},f=n=>({forces:{fx:n,fy:0,fxy:0}}),cc={included:[{caseId:1,caseKey:'1:default',label:'Bending',solution:101,result:result({1:f(-1),2:f(1)})},{caseId:2,caseKey:'2:default',label:'Compression',solution:101,result:result({1:f(-100),2:f(-100)})}],excluded:[],missing:[],complete:true},input={componentBuckling:{web_panels:[web]},failureMode:'spar_web_buckling',plateOptions:{truncatedFallback:false}},a=C.build(input,cc).rows[0],b=C.build({...input,...policy(5,1.25)},cc).rows[0];
 assert(a.caseResults[0].certifiedNonGoverning);assert(b.caseResults[0].certifiedNonGoverning);near(b.caseResults[0].lowerBound,a.caseResults[0].lowerBound/1.25);near(b.reserveFactor,a.reserveFactor/1.25);assert.equal(b.caseResults[0].reserveFactor,null);assert.equal(b.complete,a.complete);
});
check('Policy edits update RF fields, below-one membership and display saturation from the same assessment',()=>{
 const input=context({...policy(1,1)}),old=Field.build(input,{kind:'failure_rf',failureMode:'von_mises'}),changed={...input,...policy(4,1),report:old.report},next=Field.build(changed,{kind:'failure_rf',failureMode:'von_mises'});near(old.byId.get(1),3);near(next.byId.get(1),.75);assert.equal(old.failingElementIds.size,0);assert.deepEqual([...next.failingElementIds],[1]);assert.match(next.note,/LIMIT demand × 4/);assert(next.detailsById.get(1).notes.some(note=>/LIMIT demand × 4/.test(note)));assert.equal(RF.formatRF(5000),'999');assert.equal(RF.formatRF(.75),'0.75');
});
check('SOL106 explicitly labels proportional-demand estimates and does not relabel recovered equilibrium',()=>{
 const nonlinear=result({1:vm(100e6)},{analysis:'SOL106',loadScale:1,convergence:{converged:true,full_load:true}}),input=context({cases:new Map([[1,nonlinear]])}),r=S.build(input);near(r.rows[0].reserveFactor,2);assert(r.nonlinearDemandEstimate);assert(r.rows[0].nonlinearDemandEstimate);assert.match(r.note,/not a separately equilibrated nonlinear ULTIMATE state/);assert.match(S.csv(r),/engineering demand estimates/);assert.equal(nonlinear.analysis,'SOL106');assert.equal(nonlinear.elementResults[1].stress.z1.von_mises,100e6);
 for(const marker of [{nonlinear:true},{nonlinearDemandEstimate:true},{solution:106},{analysis:'SOL106_NONLINEAR'}])assert.match(P.note(marker,'strength'),/not a separately equilibrated nonlinear ULTIMATE state/);
});
console.log(JSON.stringify({passed,failed:0}));
