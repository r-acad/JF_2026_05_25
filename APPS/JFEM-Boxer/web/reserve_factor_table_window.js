/* Same-origin, read-only companion to the live Stress Report. */
(function(root){
 'use strict';const CHANNEL='JFEM-Boxer.reserve-factor-table.v1';
 function connect(options){
  const origin=root.location.origin,token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,'0')).join('');
  let child=null,ready=false,button=null,destroyed=false,lastSent=null;
  const snapshot=()=>{try{return options.readSnapshot()||{report:null};}catch(error){return{report:null,error:error.message};}};
  const send=(type,payload={})=>{if(ready&&child&&!child.closed)child.postMessage({channel:CHANNEL,token,type,...payload},origin);};
  function refresh(force=false){if(destroyed)return;const value=snapshot();if(button)button.disabled=!value.report?.rows?.length;if(!ready||!child||child.closed)return;const deps=[value.report,value.panels,value.componentGroups,value.generated,value.caseScopeLabel,value.error];if(!force&&lastSent&&deps.every((v,i)=>v===lastSent[i]))return;send('snapshot',{snapshot:root.WingReserveFactorTableData.compact(value)});lastSent=deps;}
  function receive(event){const message=event.data;if(event.origin!==origin||event.source!==child||!message||message.channel!==CHANNEL||message.token!==token)return;if(message.type==='ready'){ready=true;refresh(true);}else if(message.type==='ping')send('pong');else if(message.type==='failure-mode'&&['von_mises','euler_column','stringer_blade'].includes(message.value)){try{options.onFailureMode?.(message.value);}catch(error){send('error',{message:error.message});}}}
  const disconnect=()=>send('disconnected');root.addEventListener('message',receive);root.addEventListener('pagehide',disconnect);
  function open(){if(child&&!child.closed){child.focus();refresh();return true;}ready=false;lastSent=null;const url=new URL('reserve_factor_table.html',root.location.href);url.hash=token;child=root.open(url.href,'_blank');if(!child){options.onError?.('The browser blocked the reserve factor table. Allow pop-ups for this site and try again.');return false;}return true;}
  function installButton(host){button?.remove();if(!host)return;button=host.ownerDocument.createElement('button');button.id='btn-reserve-factor-table';button.type='button';button.className='small panel-table-open';button.textContent='Open reserve factor table \u2197';button.title='Open a read-only structural-group grid or property list. It follows this Stress Report\u2019s load cases, envelope method, material allowables and recovery coverage.';button.onclick=open;host.append(button);refresh();return button;}
  return{open,refresh,installButton,destroy(){if(destroyed)return;disconnect();destroyed=true;root.removeEventListener('message',receive);root.removeEventListener('pagehide',disconnect);button?.remove();child=null;}};
 }
 root.WingReserveFactorTables={connect,CHANNEL};
})(globalThis);
