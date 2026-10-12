'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),api=require('../web/sensitivity_table_data.js');
const rows=[{id:'properties.t_spar_web',pids:[17000001,17000002,18000001,18000002],value:.003,unit:'m',field_key:'shell.thickness',derivative_unit:'m / m',derivative:-8,status:'ok'}];
const scope={groups:[{pid:17000001,name:'FRONT_SPAR_WEB_P17000001'},{pid:17000002,name:'FRONT_SPAR_WEB_P17000002'},{pid:18000001,name:'REAR_SPAR_WEB_P18000001'},{pid:18000002,name:'REAR_SPAR_WEB_P18000002'}]};
const result={status:'complete',baseline:{value:2,unit:'m'},rows,request:{variables:rows.map(r=>r.id)},scope,load_application_version:'rib_aero_bay_mass_wrenches_pg_runout5mm2_localcomponents_v4'},field='shell.thickness|m / m';
let snapshot=api.compact({result}),grid=api.componentMatrix(snapshot,'sparwebs',field);
assert.equal(grid.localCount,4);assert.equal(grid.returnedCount,0);assert.equal(grid.selectedCount,0);assert.deepEqual(grid.indices,[1,2]);assert.deepEqual(grid.parts,['front_web','rear_web']);
for(const cell of grid.cells.values()){assert.equal(cell.rows.length,0);assert.equal(cell.missing.status,'not_selected');assert.match(cell.missing.reason,/Add component variables/);}
assert.deepEqual(grid.shared,rows);assert.equal(api.colorScales(snapshot,{mode:'panels',skin:'sparwebs',field}).get('m / m').count,1);
assert.equal(api.selectRows(snapshot,{mode:'panels',skin:'sparwebs',field}).length,1);assert.equal(api.csv(snapshot,{mode:'panels',skin:'sparwebs',field}).split('\r\n').length,3);
// Reopened runs formerly lost group names: generated formulation + verified
// numeric cards permit reconstruction, never an arbitrary imported deck.
snapshot=api.compact({result:{...result,scope:{groups:scope.groups.map(({pid})=>({pid}))}}});assert.equal(api.componentMatrix(snapshot,'sparwebs',field).localCount,4);
for(const extra of [{load_application_version:'imported_v1'},{imported_signature:'source'},{load_application_version:'rib_aero_bay_mass_wrenches_pg_runout5mm2_v3'}])assert.equal(api.componentMatrix(api.compact({result:{...result,...extra}}),'sparwebs',field).localCount,0);
assert.equal(api.componentMatrix(api.compact({result:{...result,scope:{groups:scope.groups.map(g=>({...g,name:'IMPORTED_QUAD_P'+g.pid}))}}}),'sparwebs',field).localCount,0);
const local={id:'properties.components#front_web:1#thickness',component_key:'front_web:1',pids:[17000001],unit:'m',field_key:'shell.thickness'};
snapshot=api.compact({result:{...result,load_application_version:'new_generated_version',scope:{...scope,available_components:[local]},request:{variables:[...result.request.variables,local.id]}}});
assert.equal(api.componentMatrix(snapshot,'sparwebs',field).cells.get('front_web:1').missing.status,'missing');assert.deepEqual(api.compact(snapshot),snapshot);
const failed={...local,value:.003,derivative:null,derivative_unit:'m / m',status:'failed',warning:'Test failure'};
snapshot=api.compact({result:{...result,rows:[...rows,failed]}});grid=api.componentMatrix(snapshot,'sparwebs',field);assert.equal(grid.returnedCount,1);assert.equal(grid.cells.get('front_web:1').rows[0].status,'failed');assert.equal(api.value(snapshot.result,failed).value,null);
console.log('Component availability: recorded default-only grids, metadata persistence, imported/legacy guards, and honest missing/failed values passed');
if(process.argv[2]){
 const fixture=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),nr=fixture.rib_count,locals=fixture.catalog.variables.filter(v=>v.component_key);
 assert.equal(new Set(locals.map(v=>api.component(v).part)).size,11);
 for(const kind of ['shared_only','all_local',...(fixture.reloaded?['reloaded']:[])]){const s=api.compact({result:fixture[kind]}),returned=kind==='all_local';
  for(const [group,nparts,ribs]of [['sparwebs',2,false],['sparcaps',4,false],['ribwebs',1,true],['ribstiffeners',1,true],['leskins',2,false],['leribs',1,true]]){
   const families=api.groupFamilies(s,group);assert.equal(families.length,group==='ribstiffeners'?4:1);
   for(const f of families){const m=api.componentMatrix(s,group,f.key),expected=nparts*(ribs?nr:nr-1);assert.equal(m.localCount,expected,kind+' '+group);assert.equal(m.returnedCount,returned?expected:0);assert.equal(m.parts.length,nparts);assert.equal(m.indices.length,ribs?nr:nr-1);
    for(const cell of m.cells.values())assert.equal(cell.rows.length,returned?1:0);
   }
  }
 }
 console.log('Native catalogue integration: all 11 physical families and every rib/bay map correctly, with all locals selected or with only shared defaults selected');
}
