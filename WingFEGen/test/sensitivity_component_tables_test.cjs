'use strict';
// Portable ownership/interpretation tests; the derivatives below are synthetic,
// not claimed as numerical solver validation.
const assert=require('node:assert/strict'),api=require('../web/sensitivity_table_data.js');
const checks=[],row=(id,derivative,pids=[],extra={})=>({id,label:id,pids,value:.002,unit:'m',derivative_unit:'m / m',derivative,status:'ok',...extra});
const rows=[
 row('properties.panels#upper:bay1:stringer1:segment1#skin#thickness',1,[5000001]),
 row('properties.panels#lower:bay1:stringer1:segment1#stringer#height',2,[7000002]),
 row('properties.components#front_web:2#thickness',-3,[17000002]),
 row('properties.spar_bays#3#rear_thickness',-4,[4000003]),
 row('properties.components#front_upper_cap:1#side',5,[8000001],{field_key:'shell.thickness',field_label:'Shell thickness'}),
 row('properties.components#rear_lower_cap:2#side',99,[11000002],{status:'failed',warning:'Example failed derivative'}),
 row('properties.ribs#3#thickness',6,[1000003]),
 row('properties.components#rib_web:4#core_thickness',7,[15000004]),
 row('properties.ribs#3#height',8,[2000003]),
 row('properties.components#rib_stiffener:4#flange_width',9,[16000004]),
 row('properties.components#leading_upper_skin:1#thickness',10,[12000001]),
 row('properties.components#leading_lower_skin:3#face_thickness',11,[13000003]),
 row('properties.components#leading_rib:4#thickness',12,[14000004]),
 row('properties.t_spar_web',-21,[3]),
 row('properties.spar_cap_side',22,[12]),
 row('materials.shells#leading_edge_skin#core_thickness',23,[21]),
 row('material.E',24,[3,12,21,2000003],{value:71,unit:'GPa',derivative_unit:'m / GPa',field_key:'material.E'}),
 row('reference.property#8000001#A',25,[8000001],{field_key:'section.area',unit:'m2',derivative_unit:'m / m2'})
];
const pending='properties.components#rear_upper_cap:2#side',scope={groups:[
 {pid:3,name:'FRONT_SPAR_WEB',kind:'quad',eids:[1,2]},
 {pid:12,name:'SPAR_CAPS',kind:'bar',eids:[3,4]},
 {pid:21,name:'LE_UPPER_SKIN',kind:'quad',eids:[5,6]},
 {pid:2000003,name:'RIB_STIFFENERS_P2000003',kind:'bar',eids:[7]},
 {pid:8000001,name:'IMPORTED_BAR_P8000001',kind:'bar',eids:[8]}],
 variables:{[pending]:{pids:[10000002],eids:[100,101],element_count:2}}};
const result={case_id:3,baseline:{value:2,unit:'m'},status:'complete',rows,request:{variables:[...rows.map(r=>r.id),pending]},scope};
const s=api.compact({result,compatibility:{is_current:false,topology_match:false},panels:[{key:'upper:bay99:stringer99:segment1',skin:'upper',rib_bay:99,stringer:99,id:99}]});
assert.equal(s.result.scope,undefined);assert.equal(s.ownership.groups[0].eids,undefined);assert.equal(s.ownership.variables[pending].eids,undefined);assert.deepEqual(api.compact(s),s);
assert.deepEqual(api.availableGroups(s),Object.keys(api.GROUPS));checks.push('Eight structural groups survive detached snapshot round trips without dense topology data');
for(const r of rows.filter(r=>api.component(r))){const c=api.component(r);assert(api.groupFamilies(s,c.group).some(f=>f.key===api.family(r).key));assert.deepEqual(api.rowGroups(s,r),[c.group]);}
assert.equal(api.component(rows[3]).key,'rear_web:3');assert.equal(api.component(rows[6]).key,'rib_web:3');assert.equal(api.component(rows[8]).key,'rib_stiffener:3');
assert.equal(api.family(rows[4]).key,'section.square_side|m / m');assert.equal(api.family(rows[4]).name,'Square spar cap side');checks.push('Canonical component and legacy rib/bay IDs map correctly, including historical cap-side metadata correction');
const capField='section.square_side|m / m',caps=api.componentMatrix(s,'sparcaps',capField);
assert.deepEqual(caps.parts,['front_upper_cap','rear_upper_cap','rear_lower_cap']);assert.deepEqual(caps.indices,[1,2]);assert.equal(caps.cells.get('rear_upper_cap:2').missing.status,'missing');assert.equal(caps.cells.get('rear_lower_cap:2').rows[0].status,'failed');assert.equal(api.value(result,caps.cells.get('rear_lower_cap:2').rows[0]).value,null);
assert.deepEqual(caps.shared.map(r=>r.id),['properties.spar_cap_side']);assert.equal(caps.shared[0].derivative,22);assert(!caps.cells.has('front_lower_cap:1'));checks.push('Local physical grid uses recorded locations; selected/missing and failed values remain distinct, shared defaults are never split among bays');
const partial=api.compact({result:{...result,status:'partial'}});assert.equal(api.componentMatrix(partial,'sparcaps',capField).cells.get('rear_upper_cap:2').missing.status,'pending');
const ribGrid=api.componentMatrix(s,'ribwebs','shell.thickness|m / m');assert(ribGrid.ribs);assert.deepEqual(ribGrid.indices,[3,4]);assert.equal(ribGrid.cells.get('rib_web:4').missing.status,'not_selected');
assert.deepEqual(api.matrix(s,'upper','shell.thickness|m / m').bays,[1]);checks.push('Ribs use rib indices, other components use bays; unrelated current geometry never contaminates historical results');
assert.deepEqual(api.rowGroups(s,rows[16]),['sparwebs','sparcaps','leskins','ribstiffeners']);assert.deepEqual(api.rowGroups(s,rows[17]),[]);
assert.equal(api.selectRows(s,{mode:'all',filter:'reference.property'}).length,1);assert.equal(api.selectRows(s,{mode:'other',filter:'reference.property'}).length,1);
assert.equal(api.selectRows(s,{mode:'panels',skin:'sparcaps',field:'material.E|m / GPa'})[0].derivative,24);checks.push('Recorded PID ownership includes relevant shared materials; arbitrary imported PID numbers never masquerade as generated components');
const unreturned=api.compact({result:{rows:[],baseline:{value:1,unit:'m'},request:{variables:['material.E','materials.library#2#nu','reference.property#8000001#I1']},scope:{groups:[{pid:12,name:'SPAR_CAPS'}],variables:{'material.E':{pids:[12]},'materials.library#2#nu':{pids:[12]},'reference.property#8000001#I1':{pids:[12]}}}}});
assert.deepEqual(api.availableGroups(unreturned),[]);assert.deepEqual(api.groupFamilies(unreturned,'sparcaps'),[]);checks.push('Missing material/imported rows never acquire fabricated metre units or false derivative families');
const scale=api.colorScales(s,{mode:'panels',skin:'sparcaps',field:capField}).get('m / m');assert.deepEqual(scale,{unit:'m / m',min:5,max:22,count:2});
assert.equal(api.colorScales(s,{mode:'panels',skin:'sparwebs',field:'shell.thickness|m / m'}).get('m / m').max,-3);
assert.equal(api.value(result,rows[4],'normalized').value,.005);const csv=api.csv(s,{mode:'panels',skin:'sparcaps',field:capField});assert(csv.includes('"Spar caps","front_upper_cap","1","8000001"'));assert(csv.includes('"failed","Example failed derivative"'));assert(!csv.includes('"99"'));assert(!csv.includes('properties.t_spar_web'));
checks.push('Group/property scales use finite displayed limits only; CSV keeps exact scope, property cards, values, units and failure notes');
console.log('Sensitivity component tables: '+checks.length+' groups passed');
for(const check of checks)console.log('PASS '+check);
