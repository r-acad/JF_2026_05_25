'use strict';
const assert=require('node:assert/strict'),N=require('../web/numeric_inputs.js');
const examples=new Map([
 [1e-12,'1e-12'],[5e-4,'500e-6'],[.07085,'70.85e-3'],[.07695,'76.95e-3'],
 [73.1e9,'73.1e9'],[.0001,'100e-6'],[.36842,'368.42e-3'],[.001,'0.001'],
 [1.234567,'1.235'],[12.34567,'12.346'],[123.4567,'123.46'],[1234.567,'1234.6'],
 [12345.67,'12346'],[-.07085,'-70.85e-3'],[0,'0'],[-0,'0']
]);
for(const [value,text] of examples){
 assert.equal(N.format(value),text);
 assert.equal(N.format(Number(text)),text,'stable repeated commits');
 const mantissa=text.split('e')[0];
 assert((mantissa.split('.')[1]||'').length<=3);
 assert(mantissa.replace(/[^0-9]/g,'').replace(/^0+/,'').length<=5);
}
for(const value of [Number.MIN_VALUE,1e-309,1e-15,1e-9,Number.MAX_VALUE,-Number.MAX_VALUE]){
 const round=Number(N.format(value));assert(Number.isFinite(round));assert.notEqual(round,0);assert.equal(Math.sign(round),Math.sign(value));
}
for(const value of [1e-12,5e-4,.07085,.07695,73.1e9])assert.equal(Number(N.format(value)),value);
assert.equal(N.format(5000173,{integer:true}),'5000173','entity identifiers stay exact');
assert.equal(N.normalizeText(''),'', 'blank inherited cells stay blank');
assert.equal(N.normalizeText('bad'),'bad', 'invalid drafts remain available for editor validation');
assert.equal(N.normalizeText('1e-'), '1e-', 'partial exponent is not committed as zero');
// Unit conversion follows normalization in the editor's stated units.
assert.equal(Number(N.normalizeText('70.850'))*1e-3,.07085);
assert.equal(Number(N.normalizeText('73.100'))*1e9,73.1e9);
assert.equal(Number(N.normalizeText('76.950'))*1e-3,.07695);
console.log('PASS numeric entry precision: engineering notation, 3 decimal places/5 significant figures, finite extremes, exact identifiers and physical-unit roundtrip.');
