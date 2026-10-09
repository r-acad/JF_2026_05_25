(function(){
  "use strict";
  const CHANNEL="WingFEGen.plan-view.v1",token=location.hash.slice(1),parent=window.opener,origin=location.origin;
  const status=document.getElementById("plan-window-status");
  let view=null,values={},connected=false,revision=0,lastSeen=Date.now();
  const send=(type,payload={})=>{if(parent&&!parent.closed)parent.postMessage({channel:CHANNEL,token,type,revision,...payload},origin);};
  function refreshModel(){
    const host=document.getElementById("detached-plan-view");host.hidden=!!values?._unavailable;
    status.classList.toggle("plan-window-disconnected",!!values?._unavailable);
    status.textContent=values?._unavailable||"Live from Study";
    if(values?._unavailable)document.body.insertBefore(status,host);
    else{view?.refresh();document.querySelector(".dpv-help")?.prepend(status);}
  }
  window.addEventListener("message",event=>{
    const data=event.data;
    if(event.source!==parent||event.origin!==origin||!data||data.channel!==CHANNEL||data.token!==token)return;
    lastSeen=Date.now();
    if(data.type==="initialize"){
      revision=data.revision;
      values=data.values;
      if(!view)view=WingDimensionedPlanView.install(document.getElementById("detached-plan-view"),{
        readValues:()=>values,onChange(){send("changed",{saved:view.capture()});}
      });
      view.restore(data.saved);connected=true;refreshModel();
    }else if(data.type==="values"&&view){values=data.values;refreshModel();}
    else if(data.type==="restore"&&view){revision=data.revision;view.restore(data.saved);}
    else if(data.type==="disconnected")disconnect();
  });
  function disconnect(){connected=false;status.textContent="Study window disconnected. This drawing is the last received view; reopen Plan View from your Study to reconnect.";status.classList.add("plan-window-disconnected");document.body.insertBefore(status,document.getElementById("detached-plan-view"));}
  if(!parent||!token){status.textContent="Open Plan View using the Plan View button in the main WingFEGen Study window.";return;}
  send("ready");
  const timer=setInterval(()=>{
    if(parent.closed){disconnect();clearInterval(timer);}
    else {
      // Navigation can discard queued pagehide messages; a tiny heartbeat also
      // detects a replaced opener without resending image or geometry data.
      if(connected&&Date.now()-lastSeen>8000)disconnect();
      send(connected?"ping":"ready");
    }
  },2000);
  window.addEventListener("pagehide",()=>clearInterval(timer),{once:true});
})();
