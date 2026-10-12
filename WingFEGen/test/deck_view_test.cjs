'use strict';
const assert=require('node:assert/strict'),D=require('../web/deck_view.js');
let checks=0;
for(const text of ['', 'GRID,1,,0,0,0','one\ntwo\nthree\n','one\r\ntwo\r\nlast','\n\n\n','a\tb\n123456789012345']){
 for(const chunkSize of [1,2,400]){
  const index=D.chunks(text,chunkSize);assert.equal(index.chunks.map(c=>text.slice(c.start,c.end)).join(''),text);
  assert(index.chunks.every(c=>c.lines>0&&c.lines<=chunkSize));
  assert.equal(index.chunks.reduce((sum,c)=>sum+c.lines,0),text?text.split('\n').length-(text.endsWith('\n')?1:0):0);checks++;
 }
}
assert.equal(D.chunks('a\tb').maxColumns,9);assert.equal(D.chunks('12345678\tx').maxColumns,17);checks+=2;
const large=Array.from({length:100000},(_,i)=>'GRID,'+(i+1)+',,0.,1.,2.\n').join(''),parts=D.chunks(large);
assert.equal(parts.chunks.length,250);assert.equal(parts.chunks.map(c=>large.slice(c.start,c.end)).join(''),large);checks++;
console.log('Deck text chunking: '+checks+' checks passed');
