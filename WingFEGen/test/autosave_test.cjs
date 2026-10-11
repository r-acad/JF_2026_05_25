'use strict';
// Deterministic scheduling and revision races, with no filesystem or solver.
const assert=require('node:assert/strict'),A=require('../web/autosave.js'),W=require('../web/workspace.js');
async function fixture(){
 const state={enabled:true,dirty:true,revision:1,epoch:1,blocked:''},timers=new Map(),events=[],writes=[],errors=[];let id=0,writer=async stamp=>{writes.push(stamp);state.dirty=false;};
 const controller=A.create({read:()=>({...state}),save:stamp=>writer(stamp),onState:event=>events.push(event),onError:error=>errors.push(error.message),setTimer:fn=>{timers.set(++id,fn);return id;},clearTimer:key=>timers.delete(key)});
 const tick=async()=>{const entries=[...timers.values()];timers.clear();for(const fn of entries)await fn();};
 return{state,timers,events,writes,errors,controller,tick,writer:fn=>writer=fn};
}
(async()=>{
 let f=await fixture();for(let i=0;i<20;i++){f.state.revision++;f.controller.changed();}assert.equal(f.timers.size,1);await f.tick();assert.equal(f.writes.length,1);assert.equal(f.writes[0].revision,21);assert.equal(f.events.at(-1).status,'saved');
 // Clean state/view-only work does not write again.
 await f.controller.run();assert.equal(f.writes.length,1);
 f.state.dirty=true;f.state.enabled=false;f.controller.changed();await f.tick();assert.equal(f.writes.length,1);assert.equal(f.events.at(-1).status,'off');
 f.controller.destroy();
 f=await fixture();f.state.blocked='Unfinished property draft';f.controller.changed();await f.tick();assert.equal(f.writes.length,0);assert.equal(f.events.at(-1).status,'waiting');assert.equal(f.timers.size,1);f.state.blocked='';await f.tick();assert.equal(f.writes.length,1);f.controller.destroy();
 f=await fixture();let release;f.writer(async stamp=>{f.writes.push(stamp);await new Promise(resolve=>release=resolve);f.state.dirty=stamp.revision!==f.state.revision;});
 const first=f.controller.run();assert(f.controller.saving);f.state.revision=2;f.controller.changed();await f.controller.run();assert.equal(f.writes.length,1);release();await first;assert(f.state.dirty);assert.equal(f.events.at(-1).status,'pending');
 f.writer(async stamp=>{f.writes.push(stamp);f.state.dirty=false;});await f.tick();assert.equal(f.writes.length,2);assert.equal(f.writes[1].revision,2);f.controller.destroy();
 f=await fixture();f.writer(async()=>{throw Error('Disk is unavailable');});await f.controller.run();assert(f.state.dirty);assert.equal(f.errors.length,1);assert.equal(f.events.at(-1).status,'error');assert(!f.events.at(-1).saving);assert.equal(f.timers.size,0);await f.controller.run();assert.equal(f.errors.length,1);
 f.state.epoch++;f.writer(async stamp=>{f.writes.push(stamp);f.state.dirty=false;});f.controller.changed();await f.tick();assert.equal(f.writes[0].epoch,2);f.controller.destroy();
 f=await fixture();f.controller.changed();f.controller.destroy();assert.equal(f.timers.size,0);await f.controller.run();assert.equal(f.writes.length,0);
 const view={controls:{'auto-save':true},layers:{},activeCase:1,camera:{target:[0,0,0],alpha:0,beta:1,radius:12},workspace:{activeTab:'sensitivity',width:360,collapsed:false}};
 assert.doesNotThrow(()=>W.validateView(view));assert.throws(()=>W.validateView({...view,controls:{'auto-save':'true'}}),/checkbox setting/);
 console.log('Autosave: debounce, clean/off, draft wait, overlapping edits, failure/retry, lifecycle and saved boolean checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
