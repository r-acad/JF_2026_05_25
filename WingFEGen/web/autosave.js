/* Debounced definition saves. Display/camera changes do not enqueue a save. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAutosave=api;})(globalThis,function(){
 'use strict';
 function create({read,save,onState=()=>{},onError=()=>{},delay=900,retry=600,setTimer=setTimeout,clearTimer=clearTimeout}){
  let timer=null,saving=false,stopped=false,failed=null,lastError='';
  const key=s=>s.epoch+':'+s.revision;
  function emit(status,message=''){onState({status,message,saving});}
  function schedule(wait=delay){clearTimer(timer);timer=null;if(!stopped)timer=setTimer(run,wait);}
  async function run(){
   timer=null;if(stopped||saving)return;const before=read();
   if(!before.enabled){emit('off','Autosave off');return;}
   if(!before.dirty){emit('saved','Study definition saved');return;}
   if(failed===key(before))return;
   if(before.blocked){emit('waiting',before.blocked);schedule(retry);return;}
   saving=true;emit('saving','Autosaving Study…');
   try{await save(before);failed=null;}
   catch(error){failed=key(before);lastError=error.message||String(error);onError(error);}
   finally{
    saving=false;if(stopped)return;
    const now=read();
    if(!now.enabled)emit('off','Autosave off');
    else if(!now.dirty)emit('saved','Study definition saved');
    else if(failed===key(now))emit('error',lastError);
    else{emit('pending','Autosave pending');schedule();}
   }
  }
  function changed(){if(stopped)return;failed=null;if(!saving){const s=read();emit(!s.enabled?'off':s.dirty?'pending':'saved',!s.enabled?'Autosave off':s.dirty?'Autosave pending':'Study definition saved');schedule();}}
  return{changed,run,get saving(){return saving;},destroy(){stopped=true;clearTimer(timer);timer=null;}};
 }
 return{create};
});
