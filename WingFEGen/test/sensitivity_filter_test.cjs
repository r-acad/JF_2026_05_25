'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const sandbox={};vm.createContext(sandbox);vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/sensitivity.js'),'utf8'),sandbox);
const {propertyFilter,addMatchingVariables}=sandbox.WingSensitivity;
const variables=[{id:'upper.t',label:'P1 Upper skin thickness',group:'Panel skins',pids:[5000001]},
 {id:'lower.t',label:'P2 Lower skin thickness',group:'Panel skins'},
 {id:'spar.t',label:'Front spar thickness',group:'Spar webs'},
 {id:'stringer.h',label:'P1 Upper stringer height',group:'Panel stringers'},
 {id:'stringer.w',label:'P1 Upper stringer width',group:'Panel stringers'}];
let checks=0;function check(action){action();checks++;}
const ids=filter=>variables.filter(filter.test).map(row=>row.id);
check(()=>assert.deepEqual(ids(propertyFilter('UPPER')),['upper.t','stringer.h','stringer.w']));
check(()=>assert.deepEqual(ids(propertyFilter('upper.*thickness','text')),[]));
check(()=>assert.deepEqual(ids(propertyFilter('upper.*thickness|spar','regex')),['upper.t','spar.t']));
check(()=>assert.deepEqual(ids(propertyFilter('^stringer\\.[hw]','regex')),['stringer.h','stringer.w']));
check(()=>assert.deepEqual(ids(propertyFilter('PID 5000001')),['upper.t']));
check(()=>{const invalid=propertyFilter('[','regex');assert(!invalid.valid);assert.match(invalid.error,/Invalid regular expression/);assert.deepEqual(ids(invalid),[]);});
check(()=>assert.equal(ids(propertyFilter('','regex')).length,5));
check(()=>{const selected=['lower.t'],added=addMatchingVariables(selected,variables,propertyFilter('upper.*thickness|spar','regex'),10);assert.deepEqual(Array.from(added.values),['lower.t','upper.t','spar.t']);assert.deepEqual(selected,['lower.t']);});
check(()=>{const first=addMatchingVariables([],variables,propertyFilter('thickness'),10),second=addMatchingVariables(first.values,variables,propertyFilter('stringer.*height','regex'),10);assert.deepEqual(Array.from(second.values),['upper.t','lower.t','spar.t','stringer.h']);});
check(()=>{const answer=addMatchingVariables(['lower.t'],variables,propertyFilter(''),3);assert.deepEqual(Array.from(answer.values),['lower.t','upper.t','spar.t']);assert.equal(answer.omitted,2);});
check(()=>{const answer=addMatchingVariables(['upper.t'],variables,propertyFilter('[' ,'regex'),10);assert.deepEqual(Array.from(answer.values),['upper.t']);});
check(()=>{const filter=propertyFilter('upper','regex');assert.equal(filter.test(variables[0]),true);assert.equal(filter.test(variables[0]),true);});
console.log('Sensitivity filters: '+checks+' checks passed');
