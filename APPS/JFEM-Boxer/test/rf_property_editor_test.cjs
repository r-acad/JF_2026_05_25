'use strict';
const assert=require('node:assert/strict'),api=require('../web/rf_property_editor.js');
function context(){
 const parameters={'material.name':'Aluminium','materials.library':[{id:2,name:'Steel'},{id:3,name:'Core'}],'materials.shells':[],'materials.bars':[],
  'properties.panels':[],'properties.components':[],'properties.ribs':[],'properties.spar_bays':[],
  'properties.t_skin_upper':.002,'properties.t_skin_lower':.003,'properties.t_spar_web':.003,'properties.t_rib_web':.002,'properties.spar_cap_side':.02,
  'properties.stringer_flange_width':.03,'properties.stringer_height':.032,'properties.stringer_flange_thickness':.002,'properties.stringer_web_thickness':.002,
  'properties.rib_stiffeners_enabled':true,'properties.rib_stiffener_flange_width':.03,'properties.rib_stiffener_height':.032,'properties.rib_stiffener_flange_thickness':.002,'properties.rib_stiffener_web_thickness':.002,
  'leading_edge.enabled':true,'leading_edge.t_skin':.0015,'leading_edge.t_rib':.002,'leading_edge.start_rib':1,'leading_edge.end_rib':4,'leading_edge.disabled_bays':'','stringers.model':'beam'};
 const panels=[{id:1,key:'lower:1:1:1',skin:'lower',rib_bay:1,stringer:1,segment:1,shell_pid:6000001,stringer_pid:7000001,label:'Lower R1–R2, stringer1'},
  {id:2,key:'upper:1:1:1',skin:'upper',rib_bay:1,stringer:1,segment:1,shell_pid:5000002,stringer_pid:7000002,label:'Upper R1–R2, stringer1'}];
 const groups=[6000001,7000001,5000002,7000002,19000001,20000001,...Array.from({length:18},(_,i)=>(i+1)*1000000+2),13,1].map(pid=>({pid}));
 return{parameters,panels,groups,ribs:[{},{},{},{}],layout_token:'current-layout'};
}
const clone=value=>JSON.parse(JSON.stringify(value));let checks=0;
function test(name,fn){fn();checks++;console.log('PASS '+name);}
test('Exact panel skin and stringer IDs resolve to their own local section',()=>{
 const c=context(),skin=api.resolve(c,6000001),stringer=api.resolve(c,7000001);assert.equal(skin.kind,'skins');assert.equal(skin.key,c.panels[0].key);assert.equal(skin.values.thickness,.003);assert.equal(stringer.kind,'stringers');assert.equal(stringer.values.height,.032);assert.equal(skin.parameter,'properties.panels');
});
test('Every generated component family resolves to its physical rib/bay key',()=>{
 const c=context(),expected={8:'front_upper_cap',9:'front_lower_cap',10:'rear_upper_cap',11:'rear_lower_cap',12:'leading_upper_skin',13:'leading_lower_skin',14:'leading_rib',15:'rib_web',16:'rib_stiffener',17:'front_web',18:'rear_web'};
 for(const[family,part]of Object.entries(expected)){const d=api.resolve(c,Number(family)*1000000+2);assert.equal(d.editable,true,part);assert.equal(d.key,part+':2');assert.equal(d.parameter,'properties.components');}
});
test('Imported, unavailable, shared and nonexistent regions remain explicitly uneditable',()=>{
 const c=context();assert.match(api.resolve({...c,readOnly:true},6000001).reason,/Imported/);assert.match(api.resolve({...c,data:{imported_deck:{}}},6000001).reason,/Imported/);assert.match(api.resolve(c,99999999).reason,/absent/);assert.equal(api.resolve(c,13).editable,false);assert.equal(api.resolve(c,1).editable,false);assert.equal(api.resolve({...c,updating:true},6000001).editable,false);
});
test('Below-minimum values remain invalid without mutating canonical parameters',()=>{
 const c=context(),before=clone(c),d=api.resolve(c,6000001),r=api.validate(d,{thickness:'2.9'});assert.equal(r.valid,false);assert.deepEqual(r.belowMinimumFields,['thickness']);assert.throws(()=>api.prepare(c,6000001,{thickness:'2.9'}),/minimum gauge/);assert.deepEqual(c,before);assert.equal(api.validate(d,{thickness:'3'}).valid,true);
});
test('Valid skin edits persist SI overrides, preserve other properties and can return to inheritance',()=>{
 const c=context();c.parameters['properties.panels']=[{key:c.panels[0].key,layout_token:c.layout_token,stringer:{height:.04}}];const patch=api.prepare(c,6000001,{thickness:'4',material:'2'});assert.equal(patch.rows[0].skin.thickness,.004);assert.equal(patch.rows[0].skin.material,2);assert.equal(patch.rows[0].stringer.height,.04);c.parameters[patch.parameter]=patch.rows;assert.equal(api.resolve(c,6000001).values.thickness,.004);const reset=api.prepare(c,6000001,{thickness:'',material:''});assert.equal(reset.rows[0].skin,undefined);assert.equal(reset.rows[0].stringer.height,.04);
});
test('Final coupled T dimensions validate atomically instead of rejecting intermediate shape',()=>{
 const c=context();c.parameters['properties.panels']=[{key:c.panels[0].key,layout_token:c.layout_token,stringer:{flange_width:.05,web_thickness:.04}}];const patch=api.prepare(c,7000001,{flange_width:'35',web_thickness:'3'});assert.equal(patch.rows[0].stringer.flange_width,.035);assert.equal(patch.rows[0].stringer.web_thickness,.003);assert.throws(()=>api.prepare(c,7000001,{height:'1'}),/minimum|Flange thickness/);
});
test('Construction changes ignore dormant invalid drafts, while checking active sandwich floors',()=>{
 const c=context();c.parameters['materials.shells']=[{component:'lower_skin',kind:'sandwich',face_thickness:.001,core_thickness:.004,face_material:1,core_material:3}];const d=api.resolve(c,6000001);assert.equal(d.values.kind,'sandwich');assert.equal(api.validate(d,{face_thickness:'.8'}).valid,false);assert.deepEqual(api.validate(d,{face_thickness:'.8'}).belowMinimumFields.sort(),['core_thickness','face_thickness']);const patch=api.prepare(c,6000001,{thickness:'-1',face_thickness:'1.2',core_thickness:'4'});assert.equal(patch.rows[0].skin.thickness,undefined);assert.equal(patch.rows[0].skin.face_thickness,.0012);assert.throws(()=>api.prepare(c,6000001,{kind:'monolithic',thickness:'5'}),/minimum gauge/);
});
test('Sandwich totals use the global total floor even when no per-layer family floors exist',()=>{
 const c=context(),d=api.resolve(c,6000001);const r=api.validate(d,{kind:'sandwich',face_thickness:'.2',core_thickness:'1',face_material:'1',core_material:'3'});assert.equal(r.valid,false);assert.deepEqual(r.belowMinimumFields,['face_thickness','core_thickness']);assert.equal(api.prepare(c,6000001,{kind:'sandwich',face_thickness:'.5',core_thickness:'2',face_material:'1',core_material:'3'}).rows[0].skin.core_thickness,.002);
});
test('Shell blade zero flange is accepted only when its editable family minimum permits zero',()=>{
 const c=context();c.parameters['stringers.model']='shell';c.panels[0].stringer_web_pid=19000001;c.panels[0].stringer_flange_pid=20000001;assert.equal(api.resolve(c,19000001).kind,'stringers');assert.equal(api.resolve(c,20000001).key,c.panels[0].key);assert.throws(()=>api.prepare(c,19000001,{flange_width:'0'}),/minimum gauge/);c.parameters['properties.stringer_flange_width']=0;const patch=api.prepare(c,19000001,{flange_width:'0',flange_thickness:'-1'});assert.equal(patch.rows[0].stringer.flange_width,0);assert.equal(patch.rows[0].stringer.flange_thickness,undefined);
});
test('Component edits honor active local precedence and disabled-stiffener drafts',()=>{
 const c=context();c.parameters['properties.spar_bays']=[{bay:2,front_thickness:.001}];c.parameters['properties.components']=[{key:'front_web:2',thickness:.004}];assert.equal(api.resolve(c,17000002).values.thickness,.004);assert.throws(()=>api.prepare(c,17000002,{thickness:''}),/minimum gauge/);assert.equal(api.prepare(c,17000002,{thickness:'5'}).rows[0].thickness,.005);const off=api.prepare(c,16000002,{enabled:'false',web_thickness:'-1'});assert.equal(off.rows.find(r=>r.key==='rib_stiffener:2').enabled,false);assert.equal(off.rows.find(r=>r.key==='rib_stiffener:2').web_thickness,undefined);
});
test('Legacy sandwich totals recompute an inherited core and reject implicit under-gauge reductions',()=>{
 const c=context();c.parameters['materials.shells']=[{component:'spar_web',kind:'sandwich',face_thickness:.001,core_thickness:.004,face_material:1,core_material:3}];c.parameters['properties.spar_bays']=[{bay:2,front_thickness:.006}];const d=api.resolve(c,17000002),r=api.validate(d,{face_thickness:'2'});assert.equal(r.values.core_thickness,.002);assert.deepEqual(r.belowMinimumFields,['core_thickness']);assert.throws(()=>api.prepare(c,17000002,{face_thickness:'2'}),/minimum gauge/);const patch=api.prepare(c,17000002,{face_thickness:'2',core_thickness:'4'});assert.equal(patch.rows[0].core_thickness,.004);
});
test('Leading-edge disabled bays and stale panel override tokens cannot be edited',()=>{
 const c=context();c.parameters['leading_edge.disabled_bays']='2';assert.equal(api.resolve(c,12000002).editable,false);c.parameters['properties.panels']=[{key:c.panels[0].key,layout_token:'old',skin:{thickness:.004}}];assert.throws(()=>api.prepare(c,6000001,{thickness:'5'}),/earlier/);
});
test('Malformed values, unknown fields and unsupported material IDs fail explicitly',()=>{
 const c=context(),d=api.resolve(c,6000001);for(const raw of['not a number','Infinity','0','-2'])assert.equal(api.validate(d,{thickness:raw}).valid,false);assert.throws(()=>api.prepare(c,6000001,{material:'999'}),/Study library/);assert.throws(()=>api.prepare(c,6000001,{made_up:'2'}),/Unknown/);assert.throws(()=>api.prepare(c,6000001,{}),/Change/);
});
test('Editor summarizes every failing mode and load case, not only the governing check',()=>{
 const report={estimated:true,rows:[{pid:6000001,complete:true,reserveFactor:.4,envelopeCaseLabel:'Case 2',combined:{governingModeLabel:'Skin buckling',governingScope:'R1–R2',assessments:[
  {modeLabel:'Skin buckling',scope:'R1–R2',complete:true,reserveFactor:.4,caseLabel:'Case 2',caseResults:[{label:'Case 1',reserveFactor:.8},{label:'Case 2',reserveFactor:.4},{label:'Case 3',reserveFactor:1.1}]},
  {modeLabel:'Von Mises',scope:'Full property',complete:true,reserveFactor:.9,caseLabel:'Case 1'},
  {modeLabel:'Euler',complete:true,reserveFactor:99,noDemand:true}]} }]};
 const r=api.assessmentSummary(report,6000001);assert(r.available&&r.estimated);assert.equal(r.mode,'Skin buckling');assert.deepEqual(r.failures.map(a=>a.value),[.4,.8,.9]);assert.equal(r.failures[1].caseLabel,'Case 1');assert.equal(api.assessmentSummary(report,1).available,false);
 report.rows[0].complete=false;report.rows[0].reserveFactor=null;report.rows[0].reserveFactorReason='Missing recovery';report.rows[0].combined.assessments.push({complete:false,modeLabel:'Web',reason:'Missing load case'});
 const partial=api.assessmentSummary(report,6000001);assert.equal(partial.available,false);assert.equal(partial.failures.length,3);assert.match(partial.incomplete[0],/Missing load case/);
});
console.log(JSON.stringify({passed:true,checks}));
module.exports={context};
