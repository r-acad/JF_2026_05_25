/* One same-origin RF table per Boxer window, retained across UI rebuilds. */
(function(root){
 'use strict';
 const CHANNEL='JFEM-Boxer.reserve-factor-table.v1',origin=root.location.origin;
 const token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,'0')).join('');
 const windowName='JFEM_Boxer_RF_'+token;
 let child=null,ready=false,active=null,lastSent=null,activeEditor=null,pendingProperty=null,clearReason=null;
 const live=()=>!!child&&!child.closed;
 const send=(type,payload={})=>{if(ready&&live())child.postMessage({channel:CHANNEL,token,type,...payload},origin);};
 function closeEditor(){const previous=activeEditor;activeEditor=null;previous?.close();}
 function read(client){try{return client.options.readSnapshot()||{report:null};}catch(error){return{report:null,error:error.message};}}
 function refresh(client,force=false){
  if(client.destroyed||client!==active&&!client.button)return;
  const value=read(client);if(client.button)client.button.disabled=!value.report?.rows?.length;
  if(client!==active||activeEditor?.hasDrafts()||!ready||!live())return;
  if(value.report?.rows?.length)clearReason=null;
  const deps=[value.report,value.panels,value.componentGroups,value.generated,value.caseScopeLabel,value.error,value.requestedFailureMode,value.onlyBelowOne];
  if(!force&&lastSent&&deps.every((v,i)=>v===lastSent[i]))return;
  send('snapshot',{snapshot:root.WingReserveFactorTableData.compact(value)});lastSent=deps;
 }
 function activate(client){
  if(active===client)return true;
  if(activeEditor?.hasDrafts()){
   client.options.onError?.('Apply or cancel the property edits in the reserve factor table before changing its source.');return false;
  }
  closeEditor();active=client;lastSent=null;pendingProperty=null;return true;
 }
 function editProperty(pid){
  if(!active||active.destroyed||!Number.isSafeInteger(pid)||pid<=0)return;
  const client=active;
  try{
   if(typeof client.options.onEditProperty!=='function')throw Error('Property editing is unavailable. Refresh the Study window.');
   if(activeEditor?.hasDrafts())throw Error('Apply or cancel the current property edits before editing another region.');
   closeEditor();activeEditor=client.options.onEditProperty(pid,child.document,{onDraftChange:detail=>{
    if(client!==active||client.destroyed)return;
    send('property-draft',{pid,detail});
    if(!detail.hasDrafts){if(activeEditor?.element&&!activeEditor.element.isConnected)activeEditor=null;refresh(client,true);}
   }});child.focus();
  }catch(error){send('property-edit-error',{message:error.message});}
 }
 function openPendingProperty(){if(!ready||pendingProperty===null)return;const pid=pendingProperty;pendingProperty=null;send('focus-property',{pid});editProperty(pid);}
 function receive(event){
  const message=event.data;
  if(event.origin!==origin||event.source!==child||!message||message.channel!==CHANNEL||message.token!==token)return;
  if(message.type==='ready'){
   ready=true;if(clearReason)send('clear',{reason:clearReason});
   if(active)refresh(active,true);else send('disconnected');openPendingProperty();
  }else if(message.type==='ping')send('pong');
  else if(!active||active.destroyed)return;
  else if(message.type==='edit-property')editProperty(Number(message.pid));
  else if(message.type==='only-below-one')active.options.onOnlyBelowOne?.(message.value===true);
  else if(message.type==='failure-mode'&&Object.hasOwn(root.WingReserveFactorTableData.FAILURE_MODES,message.value)){
   const client=active;
   try{Promise.resolve(client.options.onFailureMode?.(message.value)).catch(error=>{if(active===client)send('error',{message:error.message});});}
   catch(error){send('error',{message:error.message});}
  }
 }
 root.addEventListener('message',receive);
 root.addEventListener('pagehide',()=>{closeEditor();send('disconnected');});
 root.setInterval(()=>{if(child?.closed){closeEditor();child=null;ready=false;lastSent=null;pendingProperty=null;}},1000);
 function connect(options){
  const client={options,destroyed:false,button:null};
  function clearResults({reason='A new analysis is running. Current reserve factors will appear when its results are available.'}={}){
   if(client.destroyed)return;if(client.button)client.button.disabled=true;
   if(active!==client)return;
   clearReason=reason;lastSent=null;pendingProperty=null;
   // Invalidating results bypasses the draft guard, preserving property inputs.
   activeEditor?.clearAssessment?.(reason);send('clear',{reason});
  }
  function open(){
   if(client.destroyed||!activate(client))return false;
   if(live()){child.focus();refresh(client,true);return true;}
   ready=false;lastSent=null;const url=new URL('reserve_factor_table.html',root.location.href);url.hash=token;
   // The name belongs to this parent window, never to another Boxer window.
   child=root.open(url.href,windowName);
   if(!child){client.options.onError?.('The browser blocked the reserve factor table. Allow pop-ups for this site and try again.');return false;}
   return true;
  }
  function openProperty(pid){
   pid=Number(pid);if(!Number.isSafeInteger(pid)||pid<=0||client.destroyed)return false;
   if(activeEditor?.hasDrafts()){send('property-edit-error',{message:'Apply or cancel the current property edits before editing another region.'});if(live())child.focus();return false;}
   if(!open())return false;pendingProperty=pid;openPendingProperty();return true;
  }
  function installButton(host){
   client.button?.remove();if(!host)return;
   const button=client.button=host.ownerDocument.createElement('button');button.id='btn-reserve-factor-table';button.type='button';button.className='small panel-table-open';
   button.textContent='Open reserve factor table \u2197';button.title='Open or return to this Study window\u2019s reserve factor table. Choose a property list or rib-bay matrix and filter components there. Property edits update this existing table automatically.';
   button.onclick=open;host.append(button);
   // Rebind an existing tab after a Study/controller rebuild without opening or
   // focusing it. Inspect-only clients never displace the full Stress Report.
   if(!active)activate(client);refresh(client,true);return button;
  }
  return{open,openProperty,refresh:force=>refresh(client,force),clearResults,installButton,destroy(){
   if(client.destroyed)return;client.destroyed=true;client.button?.remove();
   if(active===client){closeEditor();pendingProperty=null;lastSent=null;clearReason='The Study view changed. Waiting for its current reserve factor assessment.';send('clear',{reason:clearReason});send('disconnected');active=null;}
  }};
 }
 root.WingReserveFactorTables={connect,CHANNEL};
})(globalThis);
