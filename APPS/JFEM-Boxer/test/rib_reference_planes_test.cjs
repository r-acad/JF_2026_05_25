'use strict';
const assert=require('node:assert/strict'),R=require('../web/rib_layout.js'),{base}=require('./rib_spar_snap_test.cjs');
const row={eta:.3,mode:'flight_direction',angle:90,pitch:1};
for(const plane of ['inherit','vertical','normal_to_chords_plane','normal_to_midplane']){
 const raw={...row,plane,plane_angle:7.5},normalized=R.normalizeMasters([raw],1);
 assert.deepEqual(normalized,[raw]);assert.deepEqual(R.normalizeMasters(JSON.parse(JSON.stringify(normalized)),1),normalized);
}
assert.deepEqual(R.normalizeMasters([row],1),[row]);
for(const plane_angle of [89,-89,NaN,Infinity,true,'10'])assert.throws(()=>R.normalizeMasters([{...row,plane_angle}],1));
assert.throws(()=>R.normalizeMasters([{...row,plane:'unknown'}],1));
for(const plane of ['vertical','normal_to_chords_plane','normal_to_midplane'])assert(R.derive({...base,'ribs.plane':plane,'ribs.chords_plane_angle':8}).valid);
assert(!R.derive({...base,'ribs.chords_plane_angle':89}).valid);
assert(!R.derive({...base,'ribs.plane':'unknown'}).valid);
const p={...base,'ribs.plane':'normal_to_chords_plane','ribs.chords_plane_angle':8,'ribs.masters':[{...row,plane:'normal_to_chords_plane',plane_angle:4}]};
const snap=R.snapRibToSparPoint(p,3,0,1);
assert.equal(snap.rows[0].plane,'normal_to_chords_plane');assert.equal(snap.rows[0].plane_angle,4);
console.log('PASS Rib reference defaults, inherited/per-master choices, inclination guards, JSON persistence and spar snapping.');
