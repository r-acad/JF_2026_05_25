'use strict';
const assert=require('node:assert/strict'),N=require('../web/nastran_import.js'),W=require('../web/workspace.js');
(async()=>{
 const text='$'+ 'large native deck '.repeat(2*1024*1024)+'\nENDDATA\n';
 assert(text.length>32*1024*1024);
 const source=N.source({kind:'nastran',name:'main.bdf',text,includes:Array.from({length:257},(_,i)=>({name:'parts/'+i+'.inc',text:'$ included source\n'}))});
 assert.equal(source.text,text);assert.equal(source.includes.length,257);
 const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:1,beta:1,radius:12},activeCase:1,workspace:{activeTab:'analysis',width:430,collapsed:false}};
 // Snapshot validation must not JSON-encode the native source only to parse it
 // back. The final Save Study serialization remains the caller's responsibility.
 const stringify=JSON.stringify;let encodedLargeSource=false;
 JSON.stringify=function(value,...args){if(value?.model_source)encodedLargeSource=true;return stringify.call(this,value,...args);};
 let study;try{study=await W.snapshot({},null,view,{modelSource:source});}finally{JSON.stringify=stringify;}
 assert(!encodedLargeSource);assert.equal(study.model_source.text,text);
 const parsed=W.parse(JSON.stringify(study));assert.equal(parsed.data.model_source.text,text);assert.equal(parsed.data.model_source.includes.length,257);
 assert.equal(W.parseObject(study).data,study);
 const reads=[],fake=(name,text,relative='')=>({name,size:text.length,webkitRelativePath:relative,text:async()=>{reads.push(name);return text;}});
 const main=fake('launch.bdf',"SOL 105\nINCLUDE '../parts/web.inc'\n",'model/decks/launch.bdf');
 const web=fake('web.inc',"$ geometry\nINCLUDE 'mat\nerial.inc'\n",'model/parts/web.inc'),material=fake('material.inc','MAT1,1,7.+10,,0.3\n','model/parts/material.inc');
 const unrelated=fake('solver_results.h5','\0binary results','model/output/solver_results.h5');
 const uploaded=await N.uploadSource(main,[main,web,material,unrelated]);assert.equal(uploaded.name,'decks/launch.bdf');assert.equal(uploaded.includes.length,2);assert.deepEqual(reads,['launch.bdf','web.inc','material.inc']);assert(!reads.includes('solver_results.h5'));
 await assert.rejects(N.uploadSource(main,[main,web]),/not found.*material.inc/);
 const cycle=fake('cycle.bdf',"INCLUDE 'cycle.bdf'\n");await assert.rejects(N.uploadSource(cycle,[]),/Cyclic/);
 assert.throws(()=>N.includeReferences("INCLUDE 'broken",'bad.bdf'),/Unterminated/);
 assert.throws(()=>N.relativeInclude('main.bdf','../outside.inc'),/outside/);
 assert.equal(N.relativeInclude('parts/main.bdf','../material.inc'),'material.inc');
 console.log('Large Nastran source (>32 MiB, 257 INCLUDEs), in-memory validation and portable Study round trip passed');
 console.log('Remote folder upload reads only reachable text INCLUDEs; nested/continued paths, cycle and missing-file errors passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
