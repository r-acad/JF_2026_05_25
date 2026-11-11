'use strict';
// Consume actual Julia fixed-load section updates, with one unchanged recovered-force set.
const fs=require('node:fs'),assert=require('node:assert/strict'),E=require('../web/euler_column_data.js');
const updates=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),records={};
for(const station of updates.baseline.column.stations)for(const term of station.force_terms)
 records[String(term.eid)]={forces:term.kind==='beam_axial'?{axial:-30000}:{fx:-300000,fy:-300000,fxy:0}};
const cases={included:[{result:{elementResults:records},caseId:1,caseKey:'1',label:'Fixed LIMIT loads',solution:'101'}],complete:true,excluded:[],missing:[]};
const rows=Object.fromEntries(Object.entries(updates).map(([name,update])=>[name,E.assessColumn(update.column,cases)]));
for(const[name,row]of Object.entries(rows)){
 assert.equal(row.complete,true,name+': full section/force coverage');assert(row.reserveFactor>0,name+': finite Euler RF');
 assert.equal(row.euler.length,rows.baseline.euler.length);
 assert.equal(row.euler.compressionDemand,rows.baseline.euler.compressionDemand);
 if(name!=='baseline')assert(row.reserveFactor>rows.baseline.reserveFactor,name+': the actual updated section must increase RF');
}
assert(rows.baseline.reserveFactor<1,'The baseline column fails');
assert(rows.stringer_height.reserveFactor>1,'Changing the linked PBARL height resolves this failure');
assert(rows.stringer_web.reserveFactor>1,'Changing the linked PBARL web thickness resolves this failure');
assert(rows.skin_thickness.reserveFactor<1,'A skin-only edit can leave the coupled Euler failure unresolved');
console.log(JSON.stringify(Object.fromEntries(Object.entries(rows).map(([name,row])=>[name,{RF:row.reserveFactor,criticalLoad:row.euler.criticalLoad,compression:row.euler.compressionDemand,weakestEI:row.euler.weakestEI}]))));
