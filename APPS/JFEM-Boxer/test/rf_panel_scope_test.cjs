'use strict';
const assert=require('node:assert/strict'),scope=require('../web/rf_panel_scope.js'),stress=require('../web/stress_report_data.js'),field=require('../web/rf_field_data.js');
function fixture(){
 const shell=pid=>({kind:'quad',name:'LOWER_SKIN_P'+pid,pid,properties:{type:'PSHELL',material:{type:'MAT1',id:1}}}),bar=(pid,name)=>({kind:'bar',name,pid,properties:{type:'PBARL',material:{type:'MAT1',id:1}}}),points=(a,b)=>[[a,0,0],[b,0,0],[b,1,0],[a,1,0]];
 const elements=new Map([[1,{group:shell(101),points:points(0,1)}],[2,{group:shell(101),points:points(1,3)}],[3,{group:shell(102),points:points(3,4)}],[11,{group:bar(201,'STRINGERS_P201'),points:[[1,0,0],[1,1,0]]}],[12,{group:bar(202,'STRINGERS_P202'),points:[[3,0,0],[3,1,0]]}],[21,{group:bar(301,'SPAR_CAPS'),points:[[0,0,0],[0,1,0]]}],[22,{group:bar(302,'SPAR_CAPS'),points:[[4,0,0],[4,1,0]]}]]);
 const panels=[{id:1,key:'lower:bay1:stringer1:segment1',skin:'lower',rib_bay:1,stringer:1,segment:1,label:'Lower R1–R2 · stringer1',shell_pid:101,stringer_pid:201,shell_eids:[1,2],stringer_eids:[11]},{id:2,key:'lower:bay1:stringer2:segment1',skin:'lower',rib_bay:1,stringer:2,segment:1,label:'Lower R1–R2 · stringer2',shell_pid:102,stringer_pid:202,shell_eids:[3],stringer_eids:[12]}];
 const eulerColumns=panels.map((p,i)=>({key:p.key,skin:'lower',rib_bay:1,stringer:i+1,segment:1,applicable:true,member_element_ids:i?[2,3,12]:[1,2,11],stations:[{origin_m:[i?3:1,.5,0],axis:[0,1,0],section_y:i?[-1,0,0]:[1,0,0],left_width_m:.5,right_width_m:1,force_terms:[]}]}));
 const skinBucklingPanels=[{key:'front',label:'Front spar–S1',skin:'lower',rib_bay:1,boundary_labels:['Front spar','S1'],member_element_ids:[1],frame:{origin_m:[.5,.5,0]}},{key:'middle',label:'S1–S2',skin:'lower',rib_bay:1,boundary_labels:['S1','S2'],member_element_ids:[2],frame:{origin_m:[2,.5,0]}},{key:'rear',label:'S2–Rear spar',skin:'lower',rib_bay:1,boundary_labels:['S2','Rear spar'],member_element_ids:[3],frame:{origin_m:[3.5,.5,0]}}];
 const stringerBlades=panels.map(p=>({key:p.key,applicable:true})),componentBuckling={columns:[{kind:'spar_cap',part:'front_lower_cap',rib_bay:1,key:'frontcap',member_element_ids:[21]},{kind:'spar_cap',part:'rear_lower_cap',rib_bay:1,key:'rearcap',member_element_ids:[22]}]};
 return{elements,panels,eulerColumns,skinBucklingPanels,stringerBlades,componentBuckling,generated:true};
}
function assessed(input){
 const index=scope.index(input),row=(key,rf,label=key)=>({panelKey:key,label,reserveFactor:rf,complete:true,envelopeCaseLabel:'Case1',envelopeCaseKey:'1:default',caseResults:[{caseKey:'1:default',label:'Case1',reserveFactor:rf}]}),
  criteria={euler_column:{rows:input.panels.map((p,i)=>row(p.key,i?2:.8))},stringer_blade:{rows:input.panels.map(p=>row(p.key,1.5))},skin_buckling:{rows:input.skinBucklingPanels.map(p=>row(p.key,1.8))},spar_cap_buckling:{rows:input.componentBuckling.columns.map(p=>row(p.key,2))}};
 const materialRegions=index.materialRegions.map(r=>({...row(r.key,2),pid:r.pid,failureMode:'von_mises',materialRegionKey:r.key,memberElementIds:r.member_element_ids})),report={failureMode:'minimum_rf',nativeBackend:true,rows:[{pid:101,reserveFactor:.01,complete:true,combined:{assessments:[{failureMode:'euler_column',reserveFactor:.01,scopeKey:'UNRELATED'}]}}],materialRegions,includedCases:[{caseKey:'1:default',caseId:1,solution:101,label:'Case1'}]};
 stress.rememberCriteria(report,criteria);return{index,criteria,report};
}
let tests=0;function test(name,run){run();tests++;console.log('PASS '+name);}
test('Every cover face is partitioned once into one-stringer half skins or spar-side plain skin',()=>{
 const input=fixture(),a=scope.index(input);assert.equal(a.parts.length,4);assert.strictEqual(scope.index(input),a);
 const total=new Map();for(const part of a.parts)for(const[id,value]of Object.entries(part.skinFractions))total.set(+id,(total.get(+id)||0)+value);
 for(const eid of[1,2,3])assert(Math.abs(total.get(eid)-1)<1e-12);
 assert.equal(a.byKey.get(input.panels[0].key).skinFractions[2],.5);assert.equal(a.byKey.get(input.panels[1].key).skinFractions[2],.5);
 assert.deepEqual(a.byKey.get('plain:front').editablePropertyIds,[101,301]);assert.deepEqual(a.byKey.get(input.panels[1].key).editablePropertyIds,[101,102,202]);
 for(const part of a.parts.filter(p=>p.kind==='compression_panel'))assert.equal(part.stringerElementIds.length,1);
 for(const part of a.parts)for(const f of part.fragments)for(const v of f.vertices){assert(Math.abs(v.weights.reduce((s,x)=>s+x,0)-1)<1e-12);const points=input.elements.get(f.eid).points;for(let k=0;k<3;k++)assert(Math.abs(v.point[k]-v.weights.reduce((s,w,i)=>s+w*points[i][k],0))<1e-12);}
});
test('Actual point or explicit scope resolves the two physical halves of the same EID',()=>{
 const input=fixture();assert.equal(scope.resolve(input,{eid:1,point:[.25,.5,0]}).kind,'plain_skin');assert.equal(scope.resolve(input,{eid:1,point:[.75,.5,0]}).panelKey,input.panels[0].key);
 assert.equal(scope.resolve(input,{eid:2,point:[1.5,.5,0]}).panelKey,input.panels[0].key);assert.equal(scope.resolve(input,{eid:2,point:[2.5,.5,0]}).panelKey,input.panels[1].key);
 assert.equal(scope.resolve(input,{eid:1,scopeKey:input.panels[1].key}).panelKey,input.panels[1].key);assert.equal(scope.resolve(input,{eid:12}).panelKey,input.panels[1].key);
});
test('Panel checks ignore global PID minima and neighboring Euler/blade checks',()=>{
 const input=fixture(),{index,report}=assessed(input),own=scope.summary(input,report,index.byKey.get(input.panels[0].key)),plain=scope.summary(input,report,index.byKey.get('plain:front'));
 assert.equal(own.value,.8);assert.equal(own.checks.filter(c=>c.modeKey==='euler_column').length,1);assert.equal(own.checks.find(c=>c.modeKey==='euler_column').scopeKey,input.panels[0].key);
 assert.equal(plain.value,1.8);assert(!plain.checks.some(c=>['euler_column','stringer_blade'].includes(c.modeKey)));assert(plain.checks.some(c=>c.modeKey==='spar_cap_buckling'));assert.equal(plain.checks.filter(c=>c.modeKey==='von_mises').length,2);
});
test('Field and editor share physical RF values; covered whole EIDs cannot leak a neighbor color',()=>{
 const input=fixture(),{report}=assessed(input),contour=field.project(input,report);assert.equal(contour.detailsByPart.get('plain:front').reserveFactor,1.8);assert.equal(contour.detailsByPart.get(input.panels[0].key).reserveFactor,.8);
 assert(contour.failingPartKeys.has(input.panels[0].key));assert(!contour.failingPartKeys.has('plain:front'));assert(!contour.byId.has(1));assert(contour.scopedShellElementIds.has(1));assert.equal(contour.byId.get(11),.8);assert.equal(contour.byId.get(21),1.8);
 const category=field.project(input,report,{kind:'critical_failure'});assert.equal(category.detailsByPart.get(input.panels[0].key).modeKey,'euler_column');assert.deepEqual([...category.failingPartKeys],[input.panels[0].key]);
});
test('A plain half can pass while the other half and the adjacent same-PID part stay red',()=>{
 const input=fixture(),{report}=assessed(input),plain=report.materialRegions.find(r=>r.materialRegionKey==='plain:front'&&r.pid===101);plain.reserveFactor=.6;
 assert(field.project(input,report).failingPartKeys.has('plain:front'));plain.reserveFactor=2;
 const update=field.project(input,report);assert(!update.failingPartKeys.has('plain:front'));assert(update.failingPartKeys.has(input.panels[0].key));assert.equal(update.detailsByPart.get('plain:front').value,1.8);
});
test('Missing local strength is unavailable, never replaced by a full-property value',()=>{
 const input=fixture(),{index,report}=assessed(input);report.materialRegions=report.materialRegions.filter(r=>r.materialRegionKey!=='plain:front');const summary=scope.summary(input,report,index.byKey.get('plain:front'));assert.equal(summary.available,false);assert(summary.incomplete.some(r=>/strength/.test(r)));assert.equal(summary.value,null);
});
test('Local strength from another element subset cannot be reused by key alone',()=>{
 const input=fixture(),{index,report}=assessed(input),row=report.materialRegions.find(r=>r.materialRegionKey==='plain:front'&&r.pid===101);row.memberElementIds=[2];
 const assessment=scope.summary(input,report,index.byKey.get('plain:front'));assert(!assessment.available);assert.match(assessment.reason,/different physical element membership/);
});
test('Explicit BASIC coordinates take precedence over permuted viewport coordinates',()=>{
 const input=fixture(),original=scope.index(input),raw=[],view=[],elements=new Map();
 for(const[eid,element]of input.elements){const nodes=[];for(const p of element.points){nodes.push(raw.length/3);raw.push(...p);view.push(p[1],p[2],p[0]);}elements.set(eid,{group:element.group,nodes});}
 const context={...input,elements,scopeNodePositions:Float32Array.from(raw),nodePositions:Float32Array.from(view)};
 const restored=scope.index(context);for(const part of original.parts)assert.deepEqual(restored.byKey.get(part.key).skinFractions,part.skinFractions);
});
test('Disconnected run-out bars with a shared PID have independent physical strength domains',()=>{
 const input=fixture();for(const[eid,y]of[[31,2],[32,3]])input.elements.set(eid,{group:{kind:'bar',name:'STRINGER_RUNOUTS',pid:13,properties:{type:'PBAR',material:{type:'MAT1',id:1}}},points:[[0,y,0],[1,y,0]]});
 const indexed=scope.index(input);assert.deepEqual(indexed.byKey.get('runout:31').elementIds,[31]);assert.deepEqual(indexed.byKey.get('runout:32').elementIds,[32]);assert.equal(indexed.materialRegions.filter(r=>r.pid===13).length,2);
});
test('No-demand 99 never governs over a calculated physical RF above 99',()=>{
 const input=fixture(),{index,report,criteria}=assessed(input);for(const source of Object.values(criteria))for(const row of source.rows)row.noDemand=true;
 for(const row of report.materialRegions)row.noDemand=true;const own=criteria.euler_column.rows[0];own.noDemand=false;own.reserveFactor=150;
 const assessment=scope.summary(input,report,index.byKey.get(input.panels[0].key));assert(assessment.available);assert.equal(assessment.value,150);assert.equal(assessment.noDemand,false);
});
console.log(JSON.stringify({passed:true,tests}));module.exports={fixture,assessed};
