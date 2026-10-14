/* Presentation-only bridge to an independent browser tab. Mesh requests never
 * include the image. Only completed image/view gestures update saved metadata. */
(function(root){
  "use strict";
  const CHANNEL="WingFEGen.plan-view.v1";
  function connect(options){
    const api=root.WingDimensionedPlanView, origin=root.location.origin;
    const token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,"0")).join("");
    let saved=api.validateState(), child=null, ready=false, revision=0;
    const copy=()=>({...saved,image:saved.image&&{...saved.image},transform:{...saved.transform},viewport:{...saved.viewport},grid:{...saved.grid},snap:{...saved.snap},measurements:saved.measurements.map(row=>({type:row.type,points:row.points.map(point=>({...point})),...(row.label?{label:{...row.label}}:{})}))});
    const send=(type,payload={})=>{if(child&&!child.closed&&ready)child.postMessage({channel:CHANNEL,token,type,revision,...payload},origin);};
    const receive=event=>{
      const data=event.data;
      if(event.origin!==origin||event.source!==child||!data||data.channel!==CHANNEL||data.token!==token)return;
      if(data.type==="ready") {ready=true;send("initialize",{values:options.readValues(),saved:copy()});}
      else if(data.type==="ping") send("pong");
      else if(data.type==="changed" && data.revision===revision) {
        try{saved=api.validateState(data.saved);options.onChange?.();}
        catch(error){options.onError?.(error.message);send("restore",{saved:copy()});}
      }
    };
    const disconnect=()=>send("disconnected");
    const resume=event=>{if(event.persisted)send("initialize",{values:options.readValues(),saved:copy()});};
    root.addEventListener("message",receive);
    root.addEventListener("pagehide",disconnect);
    root.addEventListener("pageshow",resume);
    return {
      open(){
        if(child&&!child.closed){child.focus();send("values",{values:options.readValues()});return true;}
        ready=false;
        const url=new URL("plan_view.html",root.location.href);url.hash=token;
        child=root.open(url.href,"_blank");
        if(!child){options.onError?.("Your browser blocked Plan View. Allow pop-ups for this site, then open Plan View again.");return false;}
        return true;
      },
      refresh(){send("values",{values:options.readValues()});},
      capture:copy,
      restore(value){saved=api.validateState(value);revision++;send("restore",{saved:copy()});},
      destroy(){root.removeEventListener("message",receive);root.removeEventListener("pagehide",disconnect);root.removeEventListener("pageshow",resume);disconnect();child=null;}
    };
  }
  root.WingPlanViewWindow={connect,CHANNEL};
})(globalThis);
