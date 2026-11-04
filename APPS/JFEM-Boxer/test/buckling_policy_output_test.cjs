'use strict';
const assert=require('node:assert/strict');
const output=require('../web/buckling_outputs.js');
assert.equal(output.policyReserveFactor(1),1);
assert.equal(output.policyReserveFactor(1.5),1.5);
assert.equal(output.policyReserveFactor(1.5,{assessmentPolicy:{strengthSafetyFactor:3,bucklingPolicyFactor:1.2}}),1.25);
assert.equal(output.policyReserveFactor(0),null);
assert.equal(output.policyReserveFactor(-1),null);
assert.equal(output.policyReserveFactor(NaN),null);
assert.throws(()=>output.policyReserveFactor(1,{assessmentPolicy:{bucklingPolicyFactor:0}}),/greater than zero/);
assert.equal(output.policyReserveFactor(1200),1200); // preserve uncapped value; only render caps at 999
console.log('8 global buckling policy checks passed.');
