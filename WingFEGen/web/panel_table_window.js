/* Authenticated same-origin detached table bridge; the Study owns all edits. */
(function(root){
 'use strict';const CHANNEL='WingFEGen.panel-tables.v1';
 function connect(options){
  const data=root.WingPanelTableData,origin=root.location.origin,token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,'0')).join('');
  const children=new Map(),buttons=[],queue=[];let revision=0,destroyed=false,last=null,busy=false,reading=false,lastDrafts=false;
  const snapshot=()=>{try{reading=true;return last=data.compact(options.readSnapshot());}catch(error){return{...(last||data.compact()),error:'Fix the Study inputs before editing: '+error.message,busy:true};}finally{reading=false;}};
  const send=(record,type,payload={})=>{if(record.ready&&!record.window.closed)record.window.postMessage({channel:CHANNEL,token,type,kind:record.kind,revision,...payload},origin);};
  const broadcast=(type,payload={})=>{for(const record of children.values())send(record,type,payload);};
  const hasDrafts=()=>busy||queue.length>0||[...children.values()].some(c=>!c.window.closed&&c.drafts>0);
  const notifyDrafts=()=>{const pending=hasDrafts();if(pending!==lastDrafts){lastDrafts=pending;options.onDraftChange?.(pending);}};
  const refresh=()=>{if(destroyed)return;revision++;const value=snapshot();broadcast('snapshot',{snapshot:value});for(const button of buttons)button.disabled=!value.panels.length;};
  async function drain(){
   if(busy||destroyed)return;
   busy=true;notifyDrafts();
   try{while(queue.length){const {record,message}=queue.shift();if(record.window.closed)continue;
    try{
     const value=snapshot();if(value.busy||value.error)throw Error(value.error||'A Study file operation is in progress. Your cell edit is retained; apply it after the operation finishes.');
     if(message.type==='edit'&&message.base){
      if(message.layoutToken!==value.layout_token)throw Error('The panel layout changed. Review the current P labels before applying this edit.');
      if(!data.sameField(message.base,data.fieldState(value,record.kind,message.key,message.field)))throw Error('This property changed in the Study while you were editing. Review its current value and apply your edit again.');
     }else if(message.revision!==revision)throw Error('The Study changed while you were editing. Review the current values and try again.');
     const rows=message.type==='reset'?[]:data.update(value,record.kind,message.key,message.field,message.value);
     if(message.type==='reset')for(const child of children.values())child.drafts=0;
     await options.onEdit(data.PARAMETER,rows);revision++;
     broadcast('snapshot',{snapshot:snapshot(),applied:message.requestId,resetAll:message.type==='reset'});send(record,'accepted',{requestId:message.requestId});
    }catch(error){send(record,'rejected',{requestId:message.requestId,error:error.message,snapshot:snapshot()});options.onError?.(error.message);}
   }}finally{busy=false;notifyDrafts();}
  }
  const receive=event=>{
   const message=event.data,record=[...children.values()].find(r=>r.window===event.source);
   if(!record||event.origin!==origin||!message||message.channel!==CHANNEL||message.token!==token||message.kind!==record.kind)return;
   if(message.type==='ready'){record.ready=true;send(record,'snapshot',{snapshot:snapshot()});return;}
   if(message.type==='ping'){send(record,'pong');return;}
   if(message.type==='draft-status'){record.drafts=Number.isInteger(message.count)&&message.count>=0?message.count:1;notifyDrafts();return;}
   if(message.type!=='edit'&&message.type!=='reset')return;
   queue.push({record,message});notifyDrafts();void drain();
  };
  root.addEventListener('message',receive);const disconnect=()=>broadcast('disconnected');root.addEventListener('pagehide',disconnect);
  // Closing a tab can bypass pagehide (browser crash/forced close). Reconcile
  // its draft ownership so the Study's paused live-mesh queue can resume.
  const closedTimer=root.setInterval(notifyDrafts,1000);
  function open(kind){if(!data.FIELDS[kind])throw Error('Unknown panel editor.');const prior=children.get(kind);if(prior&&!prior.window.closed){prior.window.focus();send(prior,'snapshot',{snapshot:snapshot()});return true;}
   const url=new URL('panel_table.html',root.location.href);url.searchParams.set('kind',kind);url.hash=token;const child=root.open(url.href,'_blank');if(!child){options.onError?.('The browser blocked the panel table. Allow pop-ups for this site and try again.');return false;}children.set(kind,{kind,window:child,ready:false});return true;}
  function installButtons(doc=root.document){for(const b of buttons)b.remove();buttons.length=0;for(const[kind,id,title]of[['skins','group-shell-properties','Skin panel table'],['stringers','group-beam-sections','Stringer panel table']]){
   const host=doc.getElementById(id);if(!host)continue;const button=doc.createElement('button');button.type='button';button.className='small panel-table-open';button.id='btn-panel-table-'+kind;button.textContent=title+' ↗';button.title='Open a separate browser tab: stringers down the rows, physical rib bays across columns. Blank values inherit the defaults.';button.dataset.parameterLockExempt='true';button.onclick=()=>open(kind);host.prepend(button);buttons.push(button);
  }refresh();}
  return{open,refresh,installButtons,hasDrafts,resetDrafts(){queue.length=0;for(const child of children.values())child.drafts=0;revision++;broadcast('snapshot',{snapshot:snapshot(),resetDrafts:true});notifyDrafts();},assertValidDraft(){if(reading)return;if(hasDrafts())throw Error('Finish or cancel the unapplied cell edits in the panel tables before saving or creating FEM. Press Enter to apply, or Escape to cancel; queued edits finish automatically.');},destroy(){if(destroyed)return;disconnect();destroyed=true;queue.length=0;root.clearInterval(closedTimer);root.removeEventListener('message',receive);root.removeEventListener('pagehide',disconnect);for(const b of buttons)b.remove();children.clear();}};
 }
 root.WingPanelTables={connect,CHANNEL};
})(globalThis);
