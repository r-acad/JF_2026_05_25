(function(){
 'use strict';const api=WingRFSensitivity,token=location.hash.slice(1),parent=window.opener,status=document.getElementById('connection-status');
 const download=(text,name,mime)=>{const blob=new Blob([text],{type:mime}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
 const table=api.table(document,document.getElementById('rf-matrix'),{download});let connected=false;
 function ask(){if(parent&&!parent.closed)parent.postMessage({channel:api.CHANNEL,token,type:'ready'},location.origin);else status.textContent='The originating Boxer window is closed. Exported results remain available in the main app.';}
 window.addEventListener('message',event=>{
  if(event.origin!==location.origin||event.source!==parent||event.data?.channel!==api.CHANNEL||event.data.token!==token||!['snapshot','validity','clear'].includes(event.data.type))return;
  connected=true;
  if(event.data.type==='clear'){
   table.clear();
   document.getElementById('stale-status').hidden=true;
   status.textContent=event.data.message||'Waiting for results from the current analysis.';
   return;
  }
  if(event.data.type==='snapshot')table.update(event.data.result);
  document.getElementById('stale-status').hidden=!event.data.stale;
  status.textContent=event.data.source_closed?'The originating Study was closed or replaced.':'Native equilibrium derivatives · read-only view of the recorded run.';
 });
 ask();setTimeout(()=>{if(!connected){ask();if(parent&&!parent.closed)status.textContent='Waiting for the recorded RF derivatives from Boxer…';}},1500);
})();
