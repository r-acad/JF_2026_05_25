'use strict';
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync(require.resolve('../web/app.js'),'utf8');
const start=source.indexOf('function appliedResultLoads('),end=source.indexOf('\nfunction ',start+1);
const context={WingGeometryExport:require('../web/geometry_export.js'),state:{nodeIds:Int32Array.of(10,20,30)}};
context.activeLoads=()=>context.loads;vm.createContext(context);vm.runInContext(source.slice(start,end),context);
context.loads={method:'imported',force_stations:[{node_index:0,target_kind:'imported_grid',force:[10,20,100]}],moment_stations:[{node_index:0,target_kind:'imported_grid',moment:[6,8,10]}]};
// At GRID10: follower [0,0,80] + fixed [10,20,20]. GRID20 has cancelling
// undeformed follower/fixed forces, so the source intentionally has no glyph.
context.state.results={matches:true,available:true,static:{},loadScale:.25,followerLoading:{enabled:true,forces:[
 {grid_id:10,force_basic:[20,0,0],reference_force_basic:[0,0,20]},
 {grid_id:20,force_basic:[10,0,0],reference_force_basic:[0,0,10]}]}};
const before=JSON.stringify(context.loads);let result=context.appliedResultLoads();
assert.deepEqual(Array.from(result.stations[0].force),[22.5,5,5]);
assert.deepEqual(Array.from(result.stations[1].force),[0,0,0]);
assert.deepEqual(Array.from(result.stations[1].moment),[1.5,2,2.5]);
assert.deepEqual(Array.from(result.stations[2].force),[10,0,-10]);
assert.equal(result.stations[2].node_index,1);
assert.equal(JSON.stringify(context.loads),before);
context.state.results.matches=false;result=context.appliedResultLoads();
assert.deepEqual(Array.from(result.stations[0].force),[10,20,100]);assert.equal(result.stations.length,2);
context.state.results.matches=true;context.state.results.followerLoading=null;
assert.deepEqual(Array.from(context.appliedResultLoads().stations[0].force),[2.5,5,25]);
console.log('Imported follower display: mixed dead/follower contributions, accepted load scale, fixed moments, cancelling source forces, source immutability and stale results passed.');
