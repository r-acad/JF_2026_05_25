/* Focused lifecycle regression: deterministic activity clock and decoder failures. */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
const settle=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
function harness(){
 let now=0,next=0;const timers=new Map(),frames=new Map(),elements=new Map(),listeners=new Map();
 const element=id=>{if(!elements.has(id)){const classes=new Set();elements.set(id,{hidden:false,textContent:"",dataset:{},attributes:{},
  classList:{toggle(name,on){on?classes.add(name):classes.delete(name);},contains:name=>classes.has(name)},
  setAttribute(name,value){this.attributes[name]=value;}});}return elements.get(id);};
 const timer=(fn,ms,repeat)=>{const id=++next;timers.set(id,{fn,due:now+ms,repeat});return id;};
 const context={document:{getElementById:element},performance:{now:()=>now},
  setTimeout:(fn,ms)=>timer(fn,ms,0),clearTimeout:id=>timers.delete(id),
  setInterval:(fn,ms)=>timer(fn,ms,ms),clearInterval:id=>timers.delete(id),
  requestAnimationFrame:fn=>{const id=++next;frames.set(id,fn);return id;},cancelAnimationFrame:id=>frames.delete(id),
  addEventListener:(name,fn)=>listeners.set(name,fn)};
 context.window=context;vm.createContext(context);
 vm.runInContext(fs.readFileSync(path.join(__dirname,"../web/activity.js"),"utf8"),context);
 async function advance(ms){const until=now+ms;let count=0;while(true){
  const item=[...timers].filter(([,t])=>t.due<=until).sort((a,b)=>a[1].due-b[1].due)[0];if(!item)break;
  assert(++count<100,"bounded timer callbacks");const [id,t]=item;now=t.due;
  if(t.repeat)t.due+=t.repeat;else timers.delete(id);t.fn();await settle();
 }now=until;await settle();}
 function frame(){const callbacks=[...frames.values()];frames.clear();callbacks.forEach(fn=>fn(now));}
 return{activity:context.WingActivity,timers,frames,element,advance,frame,listeners};
}

async function activityChecks(){
 const h=harness(),a=h.activity;
 assert.equal(a.count,1);assert.equal(h.timers.size,1);assert.equal(h.element("activity-status").hidden,false);
 a.end(a.startup);a.startup=null;
 assert.equal(a.count,0);assert.equal(h.timers.size,0);assert.equal(h.element("activity-status").hidden,true);
 const first=a.begin("First",{detail:"Initial"}),second=a.begin("Second",{blocking:true});
 assert.equal(a.count,2);assert.equal(h.timers.size,1,"overlapping jobs share one clock");
 assert.equal(h.element("activity-label").textContent,"Second");
 assert(h.element("activity-status").classList.contains("activity-blocking"));
 a.update(first,{detail:"Updated"});await h.advance(1250);
 assert.equal(h.element("activity-time").textContent,"0:01");a.end(second);
 assert.equal(h.element("activity-label").textContent,"First");assert.equal(h.element("activity-detail").textContent,"Updated");
 assert.equal(h.element("activity-status").classList.contains("activity-blocking"),false);
 a.end(first,{error:true,message:"Expected failure"});a.end(first);
 assert.equal(a.count,0);assert.equal(h.timers.size,0);assert.equal(h.element("mesh-status").dataset.state,"invalid");
 assert.equal(a.elapsed(-1),"0:00");assert.equal(a.elapsed(61000),"1:01");

 let resolved=false;const background=a.yieldFrame().then(()=>resolved=true);
 await h.advance(59);assert.equal(resolved,false);assert.equal(h.frames.size,1);
 await h.advance(1);await background;
 assert.equal(resolved,true);assert.equal(h.frames.size,0);assert.equal(h.timers.size,0,"fallback clears the suspended animation frame");
 resolved=false;const foreground=a.yieldFrame().then(()=>resolved=true);h.frame();
 await settle();assert.equal(resolved,false,"rAF alone must not resume CPU work before the paint macrotask");
 await h.advance(0);await foreground;
 assert.equal(h.frames.size,0);assert.equal(h.timers.size,0,"foreground path removes its fallback timer");

 const failure=a.run("Failure",async()=>{throw Error("expected action error");});
 const rejected=assert.rejects(failure,/expected action error/);await h.advance(60);await rejected;
 assert.equal(a.count,0);assert.equal(h.timers.size,0);assert.equal(h.frames.size,0);
 const success=a.run("Success",async()=>42);await h.advance(60);assert.equal(await success,42);
 assert.equal(a.count,0);assert.equal(h.timers.size,0);
 await h.advance(5000);assert.equal(h.timers.size,0,"idle activity leaves no timer running");
 const scenarios=[
  [{stage:'bootstrap',stage_category:'preparation'},'preparation'],
  [{stage:'assembly',stage_category:'numerical',compilation_live:'not_separable'},'numerical'],
  [{stage:'assembly',stage_category:'numerical'},'numerical'],
  [{stage:'precompile',stage_category:'numerical'},'preparation'],
  [{stage:'solve',stage_category:'numerical',compilation_live:'excluded'},'numerical'],
  [{stage:'export',stage_category:'export',compilation_live:'excluded'},'preparation'],
  [{stage:'solve',stage_category:'numerical',compilation_live:'excluded',stage_state:'completed'},'preparation'],
  [{phase:'operators',detail:'Building sensitivity operators'},'preparation']
 ];
 for(const [progress,category]of scenarios){
  const presentation=a.phase(progress),token=a.begin(presentation.label,presentation);
  assert.equal(h.element('activity-status').dataset.category,category);a.end(token);
 }
 assert.match(a.phase({stage_category:'numerical',compilation_live:'not_separable'}).detail,/Julia compilation may occur/);
 const completed=a.phase({stage_category:'numerical',stage_state:'completed',stage_timing:{compilation_seconds:2,execution_seconds:3}});
 assert.match(completed.detail,/Measured compilation 2\.000 s; execution excluding compilation 3\.000 s/);assert(!completed.detail.includes('may occur'));
 const failed=a.begin('Expected error',{state:'error'});assert.equal(h.element('activity-status').dataset.state,'error');assert.equal(h.element('activity-status').attributes['aria-busy'],'false');a.end(failed);
 a.announce('Completed',{state:'completed',duration:1000});assert.equal(a.count,0);assert.equal(h.element('activity-status').dataset.state,'completed');
 assert.equal(h.element('activity-status').attributes['aria-busy'],'false');await h.advance(1000);assert.equal(h.element('activity-status').hidden,true);assert.equal(h.timers.size,0);
 a.announce('Failure',{state:'error'});assert.equal(h.element('activity-status').dataset.state,'error');const next=a.begin('Next preparation');assert.equal(h.element('activity-status').dataset.state,'running');a.end(next);assert.equal(h.timers.size,0);
}

async function decoderChecks(){
 const source=fs.readFileSync(path.join(__dirname,"../web/app.js"),"utf8");
 const start=source.indexOf("async function decodePayload("),end=source.indexOf("\nasync function buildModelResponsive",start);
 assert(start>=0&&end>start);const code=source.slice(start,end);
 for(const mode of["message-error","worker-error","success","post-throw"]){
  let terminated=0,created=0,transferred=false;
  class Worker{constructor(){created++;}postMessage(buffer,transfer){
   transferred=transfer.length===1&&transfer[0]===buffer;
   if(mode==="post-throw")throw Error("post failed");
   queueMicrotask(()=>mode==="worker-error"?this.onerror({message:"parse failed"}):
    this.onmessage({data:mode==="message-error"?{error:"decode failed"}:{data:{ok:true}}}));
  }terminate(){terminated++;}}
  const context={Worker,paintActivity:async()=>{},MessagePack:{decode:()=>{throw Error("worker path decoded synchronously");}}};
  vm.createContext(context);vm.runInContext(code,context);
  const pending=context.decodePayload(new ArrayBuffer(1024*1024));
  if(mode==="success")assert.equal((await pending).ok,true);else await assert.rejects(pending,/failed/);
  assert.equal(created,1);assert.equal(terminated,1,mode+" worker cleanup");assert.equal(transferred,true);
 }
 let syncCalls=0;const context={paintActivity:async()=>{},MessagePack:{decode:bytes=>{syncCalls++;return{length:bytes.byteLength};}}};
 vm.createContext(context);vm.runInContext(code,context);
 assert.equal((await context.decodePayload(new ArrayBuffer(8))).length,8);
 assert.equal((await context.decodePayload(new ArrayBuffer(1024*1024))).length,1024*1024);
 assert.equal(syncCalls,2,"small payloads and browsers without workers retain decoding support");
}
(async()=>{await activityChecks();await decoderChecks();console.log("Activity lifecycle passed: shared/idle timers, background/foreground yields, action cleanup, four worker cleanup paths and synchronous fallback.");})().catch(error=>{console.error(error);process.exitCode=1;});
