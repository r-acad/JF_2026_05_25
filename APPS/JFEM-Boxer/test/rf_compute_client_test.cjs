'use strict';
// Events can already be queued when Worker.terminate() is called. Exercise the
// actual client with controllable Worker deliveries rather than timing luck.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/rf_compute_client.js'),'utf8');
function setup({bindError=false,postError=false}={}){
 const workers=[];class Worker{constructor(){workers.push(this);}terminate(){this.terminated=true;}postMessage(message){this.request=message;if(postError){postError=false;throw Error('structured clone failed');}}}
 const box={Worker,WingStressReportData:{criteria(){},rememberCriteria(){},bindContext(report){if(bindError)throw Error('invalid report context');return report;}}};vm.createContext(box);vm.runInContext(source,box);
 return{workers,client:box.WingRFCompute.create(),reply(worker,report={marker:'current'}){worker.onmessage({data:{id:worker.request.id,report}});}};
}
const input=()=>({elements:{},cases:{}}),settle=promise=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('RF request did not settle')),500);promise.then(value=>{clearTimeout(timer);resolve(value);},error=>{clearTimeout(timer);reject(error);});});
let passed=0;async function check(name,fn){await fn();passed++;console.log('PASS '+name);}
(async()=>{
 for(const event of ['message','error'])await check('Queued cancelled-worker '+event+' cannot consume a newer pending request',async()=>{
  const s=setup(),first=s.client.evaluate(input()).catch(error=>error.name),second=s.client.evaluate(input());
  if(event==='message')s.reply(s.workers[0],{marker:'cancelled'});else s.workers[0].onerror({message:'queued old error'});
  s.reply(s.workers[1]);assert.equal((await settle(second)).marker,'current');assert.equal(await first,'AbortError');assert(s.workers[0].terminated);s.client.destroy();
 });
 await check('Late duplicate replies remain ignored after another generation starts',async()=>{
  const s=setup(),first=s.client.evaluate(input());s.reply(s.workers[0],{marker:'first'});assert.equal((await first).marker,'first');const second=s.client.evaluate(input());s.reply(s.workers[0],{marker:'duplicate'});s.reply(s.workers[1]);assert.equal((await settle(second)).marker,'current');s.client.destroy();
 });
 await check('A mismatched reply ID cannot settle the current request',async()=>{
  const s=setup(),pending=s.client.evaluate(input());s.workers[0].onmessage({data:{id:999,report:{marker:'wrong'}}});s.reply(s.workers[0]);assert.equal((await settle(pending)).marker,'current');s.client.destroy();
 });
 await check('Current-worker errors reject their own request and permit recovery',async()=>{
  const s=setup(),first=s.client.evaluate(input());s.workers[0].onerror({message:'current error'});await assert.rejects(settle(first),/current error/);const second=s.client.evaluate(input());s.reply(s.workers[1]);assert.equal((await settle(second)).marker,'current');s.client.destroy();
 });
 await check('Synchronous message-clone failure cleans up its worker and pending state',async()=>{
  const s=setup({postError:true});await assert.rejects(settle(s.client.evaluate(input())),/structured clone failed/);assert(s.workers[0].terminated);const second=s.client.evaluate(input());s.reply(s.workers[1]);assert.equal((await settle(second)).marker,'current');s.client.destroy();
 });
 await check('Report-context exceptions reject instead of leaving the request unresolved',async()=>{
  const s=setup({bindError:true}),pending=s.client.evaluate(input());s.reply(s.workers[0]);await assert.rejects(settle(pending),/invalid report context/);s.client.destroy();
 });
 console.log(JSON.stringify({passed,failed:0}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
