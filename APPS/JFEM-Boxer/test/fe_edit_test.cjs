'use strict';
const assert = require('node:assert/strict');
const edit = require('../web/fe_edit.js');
const first = edit.plane({point: [1, 2, 3], normal: [10, 0, 0], side_length: 5, tolerance: 1e-8});
assert.deepEqual(first, {point: [1, 2, 3], normal: [1, 0, 0], side_length: 5, tolerance: 1e-8});
assert.deepEqual(edit.selection('slab', first, 2).second_plane.point, [3, 2, 3]);
assert.deepEqual(edit.selection('negative', first), {kind: 'negative', plane: first});
assert.deepEqual(edit.translation([0, 3, 4], 'direction', -2), [0, -1.2, -1.6]);
assert.deepEqual(edit.translation(['1e-6', 0, 0], 'vector'), [1e-6, 0, 0]);
assert.deepEqual(edit.candidateGroups([{nodes: [9, 2, 9], retained_node: 2, max_distance: 1e-9}]), [{nodes: [9, 2], retained_node: 2, max_distance: 1e-9}]);
assert.deepEqual(edit.pickedVector({nodes:[{id:10,xyz:[1,2,3]},{id:20,xyz:[4,7,11]}]}),{nodes:[{id:10,xyz:[1,2,3]},{id:20,xyz:[4,7,11]}],delta:[3,5,8]});
assert.deepEqual(edit.pickedPart({element_ids:[10,11,10],part:{id:'part-E10',label:'Part 1'}}),{element_ids:[10,11],part:{id:'part-E10',label:'Part 1'},requires_cut:false});
assert.deepEqual(edit.candidateGroups([{nodes:[7,70],retained_node:7,affected_nodes:[70],anchor_nodes:[7,8]}])[0].anchor_nodes,[7,8]);
for (const work of [
  () => edit.finite('', 'X'), () => edit.finite('NaN', 'X'),
  () => edit.unitVector([0, 0, 0], 'Normal'), () => edit.unitVector([1.5e308, 1.5e308, 1.5e308], 'Normal'),
  () => edit.plane({...first, side_length: 0}), () => edit.plane({...first, tolerance: -1}),
  () => edit.plane({...first, point: [0, 1]}), () => edit.selection('slab', first, 0),
  () => edit.selection('invented', first), () => edit.translation([0, 0, 0], 'vector'),
  () => edit.translation([1, 0, 0], 'direction', 0), () => edit.candidateGroups([{nodes: [1, -2]}]),
  () => edit.candidateGroups([{nodes: [1, 1]}]),
  () => edit.pickedNodes({nodes:[{id:0,xyz:[1,2,3]}]}), () => edit.pickedNodes({nodes:[{id:1,xyz:[1,2,NaN]}]}),
  () => edit.pickedVector({nodes:[{id:1,xyz:[1,2,3]}]}), () => edit.pickedVector({nodes:[{id:1,xyz:[1,2,3]},{id:2,xyz:[1,2,3]}]}),
  () => edit.pickedPart({element_ids:[]}), () => edit.pickedPart({element_ids:[1,NaN]})
]) assert.throws(work);
console.log('FE editing input contracts: normalized planes, signed translation, parallel slices, scientific notation and invalid-input rejection passed.');
