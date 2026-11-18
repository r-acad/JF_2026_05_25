'use strict';
const assert = require('node:assert/strict');
const boundaries = require('../web/rf_panel_boundaries.js');
const element = (kind, nodes, properties = {}) => ({nodes, group: {kind, properties}});
const nodes = Float32Array.from([0,0,0, 1,0,0, 2,0,0, 3,0,0, 0,1,0, 1,1,0, 2,1,0, 3,1,0]);
const elements = new Map([
  [10, element('quad', [0,1,5,4], {thickness_m: .02})],
  [11, element('quad', [2,3,7,6], {thickness_m: .02})],
  [12, element('quad', [1,2,6,5], {thickness_m: .02})],
  [13, element('bar', [1,5])],
  [14, element('quad', [1,5,6,2])]
]);
const panel = {id: 1, key: 'upper:bay1:stringer1', shell_eids: [10,11], stringer_flange_eids: [12], stringer_eids: [13,14]};
const collect = extra => boundaries.collect({panels: [panel], elements, ...extra});
const edgeKey = edge => [edge.a, edge.b].sort((a,b) => a-b).join(':');
const [group] = collect();
assert.deepEqual(group.elementIds, [10,11,12]);
assert.deepEqual(new Set(group.segments.map(edgeKey)), new Set(['0:1','1:2','2:3','3:7','6:7','5:6','4:5','0:4']));
assert.equal(group.segments.length, 8, 'Attached flange closes the skin footprint without outlining its two internal edges or the blade.');
for(const id of [10,11,12])elements.get(id).group.pid=id;
const [explodedProperties] = collect({splitProperties:true});
assert.equal(explodedProperties.segments.length,12,'Separately exploded properties retain each fragment boundary.');
assert.equal(collect({allowed: new Set()}).length, 0);
const [barOnly] = collect({allowed: new Set([13])});
assert.equal(barOnly.stringerOnly, true);
assert.equal(barOnly.segments.length, 8, 'A visible failing bar retains the associated compression-group frame.');
const [partial] = collect({allowed: new Set([10])});
assert.equal(partial.segments.length, 4);
assert.deepEqual(partial.elementIds, [10]);
assert.equal(collect({visible: () => false}).length, 0);

const triangleElements = new Map([[21,element('tria',[0,1,5])], [22,element('tria',[0,5,4])]]);
const [plain] = boundaries.collect({elements: triangleElements, plainPanels: [{key:'plain-spar-skin',member_element_ids:[21,22]}]});
assert.equal(plain.kind, 'plain_skin');
assert.deepEqual(new Set(plain.segments.map(edgeKey)), new Set(['0:1','1:5','4:5','0:4']));
assert(!plain.segments.some(edge => edgeKey(edge) === '0:5'), 'A triangulation diagonal is internal to the plain plate.');
const owned = boundaries.collect({elements: triangleElements,panels:[{id:2,key:'owned',shell_eids:[21,22]}],plainPanels:[{key:'same-plate',member_element_ids:[21,22]}]});
assert.equal(owned.length, 1, 'Plain-skin fallback cannot duplicate an authored group.');

const skin = {segments: group.segments.filter(edge => edge.eid === 10)};
const mid = boundaries.positions(skin, {elements,nodes});
assert.equal(mid.length, skin.segments.length * 6);
assert([...mid].every((value,index) => index%3 !== 2 || value === 0));
const thick = boundaries.positions(skin, {elements,nodes,thickness:true});
assert.equal(thick.length, 2 * mid.length);
assert([...thick].every((value,index) => index%3 !== 2 || Math.abs(Math.abs(value)-.01) < 1e-8));
const shifted = boundaries.positions(skin,{elements,nodes,explosion:{active:true,point:(_,point)=>point.map((value,axis)=>value+[2,3,4][axis])}});
for(let index=0;index<mid.length;index++)assert(Math.abs(shifted[index]-mid[index]-[2,3,4][index%3])<1e-6);

console.log('RF panel boundaries pass flange, blade, triangulation, mask, plain-skin, thickness and explosion checks.');
