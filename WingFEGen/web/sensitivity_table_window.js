(function(root){
 'use strict';const CHANNEL='WingFEGen.sensitivity-table.v1';
 function connect(options){const origin=root.location.origin,token=Array.from(root.crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16).padStart(8,'0')).join('');let child=null,ready=false,button=null,destroyed=false;
  const snapshot=()=>{try{return root.WingSensitivityTableData.compact(options.readSnapshot());}catch(error){return{result:null,error:error.message,compatibility:{},panels:[]};}};
  const send=(type,payload={})=>{if(ready&&child&&!child.closed)child.postMessage({channel:CHANNEL,token,type,...payload},origin);};
  const refresh=()=>{if(destroyed)return;const value=snapshot();if(button)button.disabled=!value.result?.rows?.length;send('snapshot',{snapshot:value});};
  const receive=event=>{const data=event.data;if(event.origin!==origin||event.source!==child||!data||data.channel!==CHANNEL||data.token!==token)return;if(data.type==='ready'){ready=true;refresh();}else if(data.type==='ping')send('pong');};
  const disconnect=()=>send('disconnected');root.addEventListener('message',receive);root.addEventListener('pagehide',disconnect);
  function open(){if(child&&!child.closed){child.focus();refresh();return true;}ready=false;const url=new URL('sensitivity_table.html',root.location.href);url.hash=token;child=root.open(url.href,'_blank');if(!child){options.onError?.('The browser blocked the sensitivity data table. Allow pop-ups for this site and try again.');return false;}return true;}
  function installButton(host){button?.remove();if(!host)return;button=host.ownerDocument.createElement('button');button.id='btn-sensitivity-data-table';button.type='button';button.className='mini';button.textContent='Open data table ↗';button.title='Open a separate browser tab with panel grids, a full derivative table, raw/normalized values and CSV export';button.onclick=open;host.append(button);refresh();return button;}
  return{open,refresh,installButton,destroy(){if(destroyed)return;disconnect();destroyed=true;root.removeEventListener('message',receive);root.removeEventListener('pagehide',disconnect);button?.remove();child=null;}};
 }
 root.WingSensitivityTables={connect,CHANNEL};
})(globalThis);
