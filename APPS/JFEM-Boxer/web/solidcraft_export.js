(function(root,factory){
  const api=factory();
  if(typeof module==="object"&&module.exports)module.exports=api;
  else root.WingSolidCraftExport=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";

  function create(options={}){
    const doc=options.document||document,host=doc.getElementById("solidcraft-export");
    if(!host)return null;
    const get=id=>doc.getElementById(id),button=get("solidcraft-create"),cancel=get("solidcraft-cancel"),
      status=get("solidcraft-status"),output=get("solidcraft-output"),path=get("solidcraft-path"),copy=get("solidcraft-copy-path");
    const activity=options.activity||globalThis.WingActivity,indicator=activity?.inline?.(status);
    const fetcher=options.fetch||globalThis.fetch.bind(globalThis),pollMs=options.pollMs??500;
    let busy=false,destroyed=false,attempted=false,job=null,token=null,request=null,timer=null,resume=null,cancelRequested=false,lastMessage="";

    function unavailable(){
      if(options.isImported?.())return "Open a generated wing Study to create its solid geometry in SolidCraft.";
      if(options.isAvailable?.()===false)return "Load a wing Study and finish the active file operation to export its geometry.";
      return "";
    }
    function refresh(){
      if(destroyed)return;
      const reason=unavailable();
      button.disabled=busy||!!reason;
      cancel.hidden=!busy;cancel.disabled=cancelRequested;
      for(const input of host.querySelectorAll("input:not([readonly])"))input.disabled=busy;
      if(!busy&&reason)status.textContent=reason;
      else if(!busy&&!attempted)status.textContent="Ready to create a SolidCraft model from this Study.";
    }
    function message(text){
      status.textContent=text;
      if(token)activity?.update?.(token,{detail:text});
      if(text!==lastMessage){lastMessage=text;options.log?.(text);}
    }
    function stopWaiting(){
      if(timer!==null)clearTimeout(timer);timer=null;
      const resolve=resume;resume=null;resolve?.();
    }
    function wait(){
      return new Promise(resolve=>{
        resume=resolve;
        timer=setTimeout(()=>{timer=null;resume=null;resolve();},pollMs);
      });
    }
    async function api(url,init={}){
      request=new AbortController();
      try{
        const response=await fetcher(url,{cache:"no-store",...init,signal:request.signal});
        let data;
        try{data=await response.json();}catch{throw Error("SolidCraft returned an unreadable response.");}
        if(!response.ok||data.ok===false)throw Error(data.error||data.message||"SolidCraft request failed.");
        return data;
      }finally{request=null;}
    }
    async function requestCancel(){
      if(!busy||cancelRequested)return;
      cancelRequested=true;refresh();
      message("Cancelling after the current SolidCraft operation finishes…");
      stopWaiting();
      // A cancellation during the initial request is sent as soon as its job ID arrives.
      if(!job)return;
      try{
        const response=await fetcher("/api/solidcraft/cancel?job="+encodeURIComponent(job),{
          method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({})});
        if(!response.ok){const data=await response.json();throw Error(data.error||"Could not cancel the SolidCraft export.");}
      }catch(error){cancelRequested=false;message(error.message);refresh();}
    }
    async function start(){
      if(busy||destroyed)return false;
      const reason=unavailable();
      if(reason){status.textContent=reason;return false;}
      busy=true;attempted=true;cancelRequested=false;job=null;lastMessage="";output.hidden=true;path.value="";copy.textContent="Copy path";
      refresh();indicator?.start({restart:true});
      token=activity?.begin?.("Create in SolidCraft",{detail:"Reading current Study geometry…",blocking:false});
      let outcome="completed";
      try{
        const parameters=options.getParameters();
        const body={parameters,options:{structure:get("solidcraft-structure").checked,mirror:get("solidcraft-mirror").checked,
          deflected:get("solidcraft-deflected").checked,cli_path:get("solidcraft-cli").value.trim(),app_path:get("solidcraft-app").value.trim()}};
        message("Preparing the Study for SolidCraft…");
        let current=await api("/api/solidcraft/start",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
        job=current.id;
        if(!job)throw Error("SolidCraft did not return an export job ID.");
        if(destroyed){
          fetcher("/api/solidcraft/cancel?job="+encodeURIComponent(job),{
            method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({}),keepalive:true}).catch(()=>{});
          return false;
        }
        if(cancelRequested){cancelRequested=false;await requestCancel();}
        while(!destroyed){
          // A complete native document can be saved even if opening its window fails.
          const savedPath=String(current.result?.path||"");
          if(savedPath){path.value=savedPath;output.hidden=false;}
          if(current.state==="done"){
            const result=current.result||{};
            const count=Number(result.closed_solids??result.bodies);
            message("Created "+(Number.isFinite(count)?count.toLocaleString()+" solid bodies in ":"the model in ")+"SolidCraft."+(path.value?" The native document has been saved.":""));
            return current;
          }
          if(current.state==="failed")throw Error(current.error||current.message||"SolidCraft export failed.");
          if(current.state==="cancelled"){
            outcome="cancelled";message(current.message||"SolidCraft export cancelled.");return false;
          }
          const count=Number(current.total)>0?" · "+Number(current.completed||0)+" / "+Number(current.total)+" bodies":"";
          if(!cancelRequested)message((current.message||"Creating the SolidCraft model…")+count);
          await wait();
          if(destroyed)return false;
          current=await api("/api/solidcraft/status?job="+encodeURIComponent(job));
        }
        return false;
      }catch(error){
        if(destroyed)return false;
        outcome="error";status.textContent="SolidCraft export failed. "+error.message;
        options.log?.(status.textContent,"err");
        return false;
      }finally{
        stopWaiting();indicator?.stop();
        if(token)activity?.end?.(token,{outcome,message:status.textContent});token=null;
        busy=false;cancelRequested=false;refresh();
      }
    }
    async function copyPath(){
      path.select();
      try{await doc.defaultView.navigator.clipboard.writeText(path.value);copy.textContent="Copied";}
      catch{copy.textContent="Path selected";}
    }
    button.addEventListener("click",start);cancel.addEventListener("click",requestCancel);copy.addEventListener("click",copyPath);
    refresh();
    return{start,cancel:requestCancel,refresh,get busy(){return busy;},destroy(){
      if(destroyed)return;
      if(job&&busy)fetcher("/api/solidcraft/cancel?job="+encodeURIComponent(job),{
        method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({}),keepalive:true}).catch(()=>{});
      destroyed=true;stopWaiting();if(job)request?.abort();indicator?.destroy();
      button.removeEventListener("click",start);cancel.removeEventListener("click",requestCancel);copy.removeEventListener("click",copyPath);
      if(token)activity?.end?.(token);token=null;
    }};
  }
  return{create};
});
