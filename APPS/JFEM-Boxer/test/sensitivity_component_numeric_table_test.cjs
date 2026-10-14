'use strict';
// Integration check against a completed numerical run; no synthetic derivatives.
// Usage: node sensitivity_component_numeric_table_test.cjs fixture.json output-dir
// Fixture: {catalog, result, rib_count}. Keep user/campaign data outside the repo.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const api=require('../web/sensitivity_table_data.js');
assert(process.argv[2]&&process.argv[3],'Pass numerical fixture JSON and an evidence directory');
const fixture=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {result,catalog,rib_count:ribs}=fixture,out=path.resolve(process.argv[3]);
const locals=catalog.variables.filter(v=>v.component_key),expected=new Map(locals.map(v=>[v.id,v]));
assert.equal(result.status,'complete');
assert.equal(result.method,'analytic_discrete_adjoint');
assert.equal(result.solver_counts.forward_solves,1);
assert.equal(result.solver_counts.adjoint_solves,1);
assert.equal(result.solver_counts.perturbed_forward_solves,0);
assert.equal(result.solver_counts.finite_difference_samples,0);
assert.equal(new Set(locals.map(v=>api.component(v).part)).size,11);
assert.deepEqual(new Set(result.request.variables),new Set(expected.keys()));
assert.deepEqual(new Set(result.rows.map(v=>v.id)),new Set(expected.keys()));
assert.equal(result.rows.length,expected.size);
const snapshot=api.compact({result}),seen=new Set(),checks=[];
fs.mkdirSync(out,{recursive:true});
for(const [group,parts,atRibs]of [['sparwebs',2,false],['sparcaps',4,false],['ribwebs',1,true],['ribstiffeners',1,true],['leskins',2,false],['leribs',1,true]]){
 const families=api.groupFamilies(snapshot,group);
 assert.equal(families.length,group==='ribstiffeners'?4:1,group+' physical dimension families');
 for(const family of families){
  const grid=api.componentMatrix(snapshot,group,family.key),count=parts*(atRibs?ribs:ribs-1);
  assert.equal(grid.localCount,count,group+' property count');
  assert.equal(grid.returnedCount,count,group+' returned count');
  assert.equal(grid.selectedCount,count,group+' selected count');
  assert.equal(grid.shared.length,0,group+' has independent derivatives only');
  const values=[];
  for(const [key,cell]of grid.cells){
   assert.equal(cell.rows.length,1,key+' one property derivative');
   const row=cell.rows[0],variable=expected.get(row.id);
   assert(variable,key+' belongs to catalogue');
   assert.equal(variable.component_key,key);
   assert.equal(row.status,'ok');
   assert(Number.isFinite(row.derivative));
   assert.deepEqual(row.pids,variable.pids);
   assert.equal(row.pids.length,1);
   assert.equal(row.value,variable.value);
   assert(!seen.has(row.id),'no duplicated derivative in table grids');
   seen.add(row.id);values.push(row.derivative);
  }
  const options={mode:'panels',skin:group,field:family.key,quantity:'derivative'};
  const scale=api.colorScales(snapshot,options).get(family.unit);
  assert.equal(scale.count,count);
  assert.equal(scale.min,Math.min(...values));assert.equal(scale.max,Math.max(...values));
  const csv=api.csv(snapshot,options);
  assert.equal(csv.trim().split('\r\n').length,count+1);
  for(const cell of grid.cells.values())assert(csv.includes(cell.rows[0].id));
  fs.writeFileSync(path.join(out,group+'-'+family.key.split('|')[0]+'.csv'),csv);
  checks.push({group,field:family.key,count,min:scale.min,max:scale.max});
 }
}
assert.equal(seen.size,locals.length,'all numerical local rows appear once');
const front=result.rows.filter(row=>/^properties\.components#front_web:/.test(row.id));
assert(front.length>=2);
assert(front.some(row=>Math.abs(row.derivative-front[0].derivative)>Math.max(1e-12,Math.abs(front[0].derivative)*1e-6)),
 'bay derivatives must not be copies of one shared scalar');
fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,source:path.resolve(process.argv[2]),rows:seen.size,checks},null,2));
console.log('Actual adjoint tables: '+seen.size+' derivatives map once to their rib/bay properties; '+checks.length+' grids and CSV/color ranges pass.');
