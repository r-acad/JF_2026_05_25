'use strict';
const assert=require('node:assert/strict');
const {segments}=require('../web/stringer_layout.js');
assert.deepEqual(segments([]),[]);
const points=[{eta:.7,dxc:.03,stringer_angle:12},{eta:.3,dxc:-.02,stringer_angle:-4}];
const before=JSON.stringify(points),rows=segments(points);
assert.deepEqual(rows.map(r=>[r.index,r.start,r.end,r.angle,!!r.inherited]),[
 [1,0,.3,-4,false],[0,.3,.7,12,false],[0,.7,1,12,true]
]);
assert.equal(JSON.stringify(points),before,'Constructing display segments must not mutate spar definitions');
assert.deepEqual(segments([{eta:0,stringer_angle:6}]).map(r=>[r.start,r.end,r.angle,!!r.unused]),[[0,1,6,false]]);
const endpoints=segments([{eta:0,stringer_angle:3},{eta:1,stringer_angle:-2}]);
assert.equal(endpoints.length,2);
assert.equal(endpoints[0].unused,true,'Root-point angle is unused when the first incoming segment has an endpoint');
assert.deepEqual([endpoints[1].start,endpoints[1].end,endpoints[1].angle],[0,1,-2]);
assert.equal(segments([{eta:.5}])[0].angle,0,'Legacy points default to zero');
console.log('PASS rear-spar segment ordering, source identity, root/tip handling and inherited tip angle');
