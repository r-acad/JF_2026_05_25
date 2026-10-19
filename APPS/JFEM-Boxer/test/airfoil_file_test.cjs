'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),A=require('../web/airfoils.js');
if(!globalThis.crypto)globalThis.crypto=crypto.webcrypto;
let checks=0;const check=(condition,message)=>{assert(condition,message);checks++;},near=(a,b,t=1e-12)=>check(Math.abs(a-b)<=t,a+' != '+b);
const coordinates=[[1,.002],[.75,.04],[.5,.06],[.25,.05],[0,0],[.25,-.03],[.5,-.04],[.75,-.02],[1,-.002]];
const data=rows=>rows.map(r=>r.join(' ')).join('\n');
const first=A.parseCoordinateFile('Hand-calculated section\n'+data(coordinates),{filename:'section.dat'}),metrics=A.profileMetrics(first);
check(first.source_kind==='file'&&first.filename==='section.dat'&&first.version===1,'File identity');
near(metrics.maxThickness.value,.1);near(metrics.maxThickness.x,.5);near(metrics.maxCamber.value,.01);near(first.zu.at(-1)-first.zl.at(-1),.004);
for(const rows of[coordinates,coordinates.slice().reverse(),coordinates.flatMap((p,i)=>i===4?[p,p]:[p])]){
 const p=A.parseCoordinateFile('# comment\n'+data(rows));for(const k of['xu','zu','xl','zl']){check(p[k].length===first[k].length,'Coordinate count');p[k].forEach((v,i)=>near(v,first[k][i]));}
}
// Dimensional coordinates with translation, a large rigid rotation, and scale
// must represent the same normalized section, not a minimum-raw-x section.
const angle=2.1,c=Math.cos(angle),s=Math.sin(angle),rotated=coordinates.map(([x,z])=>[103+27*(c*x-s*z),-41+27*(s*x+c*z)]);
const transformed=A.parseCoordinateFile('Rotated and translated\n'+data(rotated));for(const key of['xu','zu','xl','zl'])transformed[key].forEach((v,i)=>near(v,first[key][i],2e-14));
const upper=coordinates.slice(0,5).reverse(),lower=coordinates.slice(4),lednicer=A.parseCoordinateFile('Surface-count example\n5 5\n\n'+data(upper)+'\n\n'+data(lower));
check(lednicer.format==='Lednicer surface counts','Lednicer recognized');for(const key of['xu','zu','xl','zl'])lednicer[key].forEach((v,i)=>near(v,first[key][i]));
const ises=A.parseCoordinateFile('ISES section\n-2.0 3.0 -2.5 3.5\n'+data(coordinates));check(ises.format==='ISES single-element','ISES domain line');
const fortran=A.parseCoordinateFile('D exponents\n'+data(coordinates).replace(/0\.002/g,'2.0D-3'));near(fortran.zu.at(-1),.002);
for(const text of['999 999\n'+data(coordinates),'section\n'+data(coordinates)+'\n0.5 NaN','NaN 0\n'+data(coordinates),'binary\0data','only a name','bad\n'+data(coordinates.map(([x,z],i)=>[x,i===3?-.2:z])),'counts\n5 8\n'+data(upper)+'\n'+data(lower),'bad\n'+data(coordinates.map(([x,z],i)=>[i===2?.9:x,z]))]){assert.throws(()=>A.parseCoordinateFile(text));checks++;}
assert.throws(()=>A.parseCoordinateFile('x'.repeat(A.MAX_FILE_BYTES+1)),/2 MB/);checks++;
(async()=>{
 const raw=Buffer.from('\ufeffUploaded title\n'+data(coordinates),'utf8');
 const p=await A.readCoordinateFile({name:'my-section.dat',size:raw.length,arrayBuffer:async()=>raw.buffer.slice(raw.byteOffset,raw.byteOffset+raw.byteLength)});
 check(A.fileProfileReady(p),'Complete portable provenance');check(p.raw_sha256===crypto.createHash('sha256').update(raw).digest('hex'),'Hash exact original bytes including UTF8 BOM');check(Number.isFinite(Date.parse(p.imported_at)),'UTC import time');check(p.name==='Uploaded title','Source title retained');check(JSON.parse(JSON.stringify(p)).xu.length===5,'Offline JSON round trip');
 await assert.rejects(()=>A.readCoordinateFile({name:'huge.dat',size:A.MAX_FILE_BYTES+1,arrayBuffer:async()=>{throw Error('must not read oversized file');}}),/2 MB/);checks++;
 console.log(JSON.stringify({passed:true,checks,scope:'Independent section metrics, ordering, rigid normalization, formats, malformed input and exact raw-file provenance'}));
})().catch(e=>{console.error(e);process.exitCode=1;});
