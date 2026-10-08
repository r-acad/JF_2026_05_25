/* Authenticated same-origin detached table bridge; the Study owns all edits. */
(function(root){
 'use strict';const CHANNEL='WingFEGen.panel-tables.v1';
 function connect(options){
  const data=root.WingPanelTableData,origin=root.location.origin,token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,'0')).join('');
  const children=new Map(),buttons=[];let revision=0,destroyed=false,last=null,busy=false,reading=false;
  const snapshot=()=>{try{reading=true;return last=data.compact(options.readSnapshot());}catch(error){return{...(last||data.compact()),error:'Fix the Study inputs before editing: '+error.message,busy:true};}finally{reading=false;}};
  const send=(record,type,payload={})=>{if(record.ready&&!record.window.closed)record.window.postMessage({channel:CHANNEL,token,type,kind:record.kind,revision,...payload},origin);};
  const broadcast=(type,payload={})=>{for(const record of children.values())send(record,type,payload);};
  const refresh=()=>{if(destroyed)return;revision++;const value=snapshot();broadcast('snapshot',{snapshot:value});for(const button of buttons)button.disabled=!value.panels.length;};
  const receive=async event=>{
   const message=event.data,record=[...children.values()].find(r=>r.window===event.source);
   if(!record||event.origin!==origin||!message||message.channel!==CHANNEL||message.token!==token||message.kind!==record.kind)return;
   if(message.type==='ready'){record.ready=true;send(record,'snapshot',{snapshot:snapshot()});return;}
   if(message.type==='ping'){send(record,'pong');return;}
   if(message.type==='draft-status'){if(message.revision===revision)record.drafts=Number.isInteger(message.count)&&message.count>=0?message.count:1;return;}
   if(message.type!=='edit'&&message.type!=='reset')return;
   try{
    if(busy)throw Error('A table edit is already being applied. Please try again.');
    if(message.revision!==revision)throw Error('The Study changed while you were editing. Review the current values and try again.');
    const value=snapshot();if(value.busy||value.error)throw Error(value.error||'Wait for the current Study operation to finish.');
    const rows=message.type==='reset'?[]:data.update(value,record.kind,message.key,message.field,message.value);
    busy=true;if(message.type==='reset')for(const child of children.values())child.drafts=0;
    await options.onEdit(data.PARAMETER,rows);revision++;
    broadcast('snapshot',{snapshot:snapshot(),applied:message.requestId,resetAll:message.type==='reset'});send(record,'accepted',{requestId:message.requestId});
   }catch(error){send(record,'rejected',{requestId:message.requestId,error:error.message,snapshot:snapshot()});options.onError?.(error.message);}
   finally{busy=false;}
  };
  root.addEventListener('message',receive);const disconnect=()=>broadcast('disconnected');root.addEventListener('pagehide',disconnect);
  function open(kind){if(!data.FIELDS[kind])throw Error('Unknown panel editor.');const prior=children.get(kind);if(prior&&!prior.window.closed){prior.window.focus();send(prior,'snapshot',{snapshot:snapshot()});return true;}
   const url=new URL('panel_table.html',root.location.href);url.searchParams.set('kind',kind);url.hash=token;const child=root.open(url.href,'_blank');if(!child){options.onError?.('The browser blocked the panel table. Allow pop-ups for this site and try again.');return false;}children.set(kind,{kind,window:child,ready:false});return true;}
  function installButtons(doc=root.document){for(const b of buttons)b.remove();buttons.length=0;for(const[kind,id,title]of[['skins','group-shell-properties','Skin panel table'],['stringers','group-beam-sections','Stringer panel table']]){
   const host=doc.getElementById(id);if(!host)continue;const button=doc.createElement('button');button.type='button';button.className='small panel-table-open';button.id='btn-panel-table-'+kind;button.textContent=title+' ↗';button.title='Open a separate browser tab: stringers down the rows, physical rib bays across columns. Blank values inherit the defaults.';button.dataset.parameterLockExempt='true';button.onclick=()=>open(kind);host.prepend(button);buttons.push(button);
  }refresh();}
  return{open,refresh,installButtons,resetDrafts(){for(const child of children.values())child.drafts=0;revision++;broadcast('snapshot',{snapshot:snapshot(),resetDrafts:true});},assertValidDraft(){if(reading)return;const child=[...children.values()].find(c=>!c.window.closed&&c.drafts);if(child)throw Error('Finish or cancel the unapplied cell edit in the '+(child.kind==='skins'?'Skin':'Stringer')+' panel table before saving or creating FEM. Press Enter to apply, or Escape to cancel.');},destroy(){if(destroyed)return;disconnect();destroyed=true;root.removeEventListener('message',receive);root.removeEventListener('pagehide',disconnect);for(const b of buttons)b.remove();children.clear();}};
 }
 root.WingPanelTables={connect,CHANNEL};
})(globalThis);
