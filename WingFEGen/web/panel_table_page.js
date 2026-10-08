(function(){
 'use strict';
 const api=WingPanelTableData,CHANNEL='WingFEGen.panel-tables.v1',token=location.hash.slice(1),parent=window.opener,origin=location.origin;
 const kind=new URLSearchParams(location.search).get('kind')==='stringers'?'stringers':'skins',target=api.section(kind),get=id=>document.getElementById(id),drafts=new Map(),requests=new Map();
 let snapshot=api.compact(),revision=0,connected=false,lastSeen=Date.now(),counter=0;
 const title=kind==='skins'?'Skin panel properties':'Stringer panel properties';document.title='WingFEGen · '+title;get('table-title').textContent=title;
 for(const f of api.FIELDS[kind]){const option=document.createElement('option');option.value=f.name;option.textContent=f.label+(f.unit?' ('+f.unit+')':'');get('property').append(option);}
 const send=(type,payload={})=>{if(parent&&!parent.closed)parent.postMessage({channel:CHANNEL,token,type,kind,revision,...payload},origin);};
 const identity=(key,field)=>key+'|'+field;
 const notifyDrafts=()=>{const submitting=new Set(requests.values());send('draft-status',{count:[...drafts.keys()].filter(id=>!submitting.has(id)).length});};
 function showError(message){get('table-error').textContent=message||'';get('table-error').hidden=!message;}
 function status(){const control=get('connection');control.classList.toggle('warning',!connected||!!snapshot.error||snapshot.modelDirty);control.textContent=!connected?'Study window disconnected. Reopen this table from the Study to reconnect.':snapshot.error||snapshot.busy?'Study operation in progress. Editing resumes when it finishes.':snapshot.modelDirty?'Study modified · last generated panel layout. Create FEM to update the mesh; use Save Study or TOML to save edits.':'Live from Study · edits use the Study’s automatic-mesh setting. Save Study or TOML there to keep them.';if(snapshot.error)control.textContent=snapshot.error;}
 function dormant(value,field){return kind==='skins'&&(value.kind==='sandwich'?['thickness','material'].includes(field):['face_thickness','core_thickness','face_material','core_material'].includes(field));}
 function render(){
  const active=document.activeElement,focus=active?.dataset.editorId,selection=active?.tagName==='INPUT'?[active.selectionStart,active.selectionEnd]:null,scroll=get('table-scroll'),left=scroll.scrollLeft,top=scroll.scrollTop;
  const layout=api.matrix(snapshot,get('skin').value),field=api.FIELDS[kind].find(f=>f.name===get('property').value),head=get('panel-table').tHead,body=get('panel-table').tBodies[0];head.replaceChildren();body.replaceChildren();
  const h=head.insertRow(),corner=document.createElement('th');corner.scope='col';corner.textContent='Stringer ↓';h.append(corner);for(const bay of layout.bays){const th=document.createElement('th');th.scope='col';th.textContent='R'+bay+'–R'+(bay+1);h.append(th);}
  const materialNames=new Map(api.materialList(snapshot.parameters).map(m=>[m.id,m.name]));
  for(const stringer of layout.stringers){const tr=body.insertRow(),th=document.createElement('th');th.scope='row';th.textContent=(get('skin').value==='upper'?'U':'L')+stringer;tr.append(th);
   for(const bay of layout.bays){const td=tr.insertCell(),panels=layout.cells.get(stringer+':'+bay)||[];if(!panels.length){td.className='no-panel';td.textContent='—';continue;}
    for(const panel of panels){const id=identity(panel.key,field.name),draft=drafts.get(id),record=api.override(snapshot,panel.key),explicit=record?.[target]?.[field.name],base=api.inherited(snapshot,panel,kind),effective=api.effective(snapshot,panel,kind),wrap=document.createElement('div');wrap.className='panel-cell';wrap.dataset.panelKey=panel.key;wrap.classList.toggle('explicit',explicit!==undefined);wrap.classList.toggle('invalid',!!draft?.error);wrap.classList.toggle('pending',[...requests.values()].some(r=>r===id));
     const label=document.createElement('strong');label.textContent='P'+panel.id+(panels.length>1?' · segment '+panel.segment:'');label.title=panel.key;wrap.append(label);
     const inherited=base[field.name],current=effective[field.name],format=value=>field.type==='material'?(materialNames.get(value)||'Missing material')+' (ID '+value+')':field.type==='kind'?(value==='sandwich'?'Sandwich':'Monolithic'):api.display(value,field)+(field.unit?' '+field.unit:'');
     const control=document.createElement(field.type==='number'?'input':'select');control.dataset.editorId=id;control.dataset.panel=String(panel.id);control.dataset.field=field.name;control.setAttribute('aria-label','P'+panel.id+' '+field.label+(field.unit?' ('+field.unit+')':''));
     if(field.type==='number'){control.type='text';control.inputMode='decimal';control.placeholder=api.display(inherited,field);control.value=draft?draft.raw:explicit===undefined?'':api.display(explicit,field);}
     else{const choices=[['','Inherit: '+format(inherited)],...(field.type==='kind'?[['monolithic','Monolithic'],['sandwich','Sandwich · face/core/face']]:api.materialList(snapshot.parameters).map(m=>[m.id,m.name+' (ID '+m.id+')']))];for(const[value,text]of choices){const option=document.createElement('option');option.value=String(value);option.textContent=text;control.append(option);}if(explicit!==undefined&&!choices.some(c=>String(c[0])===String(explicit))){const option=document.createElement('option');option.value=String(explicit);option.textContent='Missing material ID '+explicit;control.append(option);}control.value=draft?draft.raw:explicit===undefined?'':String(explicit);}
     control.disabled=!connected||snapshot.busy||!!snapshot.error||!snapshot.layout_token||requests.size>0;control.title='P'+panel.id+' · '+(explicit===undefined?'Inherited: ':'Explicit: ')+format(current)+'; clear to inherit '+format(inherited);wrap.append(control);
     const note=document.createElement('small');note.textContent=(explicit===undefined?'Inherited · ':'Override · ')+format(current);wrap.append(note);
     if(dormant(effective,field.name)){const warning=document.createElement('small');warning.className='dormant';warning.textContent='Dormant for '+effective.kind+' construction';wrap.append(warning);}
     if(kind==='skins'&&effective.kind==='sandwich'){const total=document.createElement('small');total.textContent='Total laminate '+api.display(2*effective.face_thickness+effective.core_thickness,{scale:1000})+' mm';wrap.append(total);}
     const error=document.createElement('small');error.className='cell-error';error.textContent=draft?.error||'';error.hidden=!draft?.error;wrap.append(error);td.append(wrap);
     control.addEventListener('input',()=>{drafts.set(id,{raw:control.value,error:''});wrap.classList.remove('invalid');error.hidden=true;notifyDrafts();});
     const controlRevision=revision;
     control.addEventListener('change',()=>{if(control.isConnected&&controlRevision===revision)commit(panel,field,control.value,id);});
     control.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();control.blur();}if(event.key==='Escape'){event.preventDefault();drafts.delete(id);render();}});
    }
   }
  }
  get('empty').hidden=!!layout.stringers.length;get('panel-table').hidden=!layout.stringers.length;get('table-count').textContent=layout.stringers.length+' stringers · '+layout.bays.length+' rib bays · '+snapshot.panels.filter(p=>p.skin===get('skin').value).length+' panels';
  get('reset-button').disabled=!connected||snapshot.busy||!!snapshot.error||!api.rows(snapshot.parameters).length||requests.size>0;status();scroll.scrollLeft=left;scroll.scrollTop=top;
  if(focus){const next=Array.from(body.querySelectorAll('[data-editor-id]')).find(el=>el.dataset.editorId===focus);if(next&&!next.disabled){next.focus({preventScroll:true});if(selection&&next.setSelectionRange)next.setSelectionRange(...selection);}}
  notifyDrafts();
 }
 function commit(panel,field,raw,id){
  if(requests.size)return;
  try{api.update(snapshot,kind,panel.key,field.name,raw);showError('');drafts.set(id,{raw,error:''});const requestId=kind+'-'+Date.now()+'-'+(++counter);requests.set(requestId,id);notifyDrafts();send('edit',{key:panel.key,field:field.name,value:raw,requestId});render();}
  catch(error){drafts.set(id,{raw,error:error.message});render();}
 }
 get('skin').onchange=render;get('property').onchange=render;get('help-button').onclick=()=>{get('help').hidden=!get('help').hidden;get('help-button').setAttribute('aria-expanded',String(!get('help').hidden));};
 get('reset-button').onclick=()=>{if(!confirm('Reset all '+api.rows(snapshot.parameters).length+' panel override rows in this Study? Both skin and stringer overrides will return to shared defaults.'))return;const requestId=kind+'-reset-'+(++counter);requests.set(requestId,'__reset__');send('reset',{requestId});render();};
 function accept(message){const id=requests.get(message.requestId??message.applied);if(id){if(id==='__reset__')drafts.clear();else drafts.delete(id);requests.delete(message.requestId??message.applied);}}
 window.addEventListener('message',event=>{const message=event.data;if(event.source!==parent||event.origin!==origin||!message||message.channel!==CHANNEL||message.token!==token||message.kind!==kind)return;lastSeen=Date.now();
  if(message.type==='snapshot'){const changedLayout=snapshot.layout_token&&snapshot.layout_token!==message.snapshot.layout_token;if(changedLayout&&drafts.size){drafts.clear();showError('The panel layout changed. Unapplied cell edits were cleared; review the new P labels before editing.');}if(message.resetAll||message.resetDrafts){drafts.clear();showError('');}snapshot=api.compact(message.snapshot);revision=message.revision;connected=true;accept(message);const keys=new Set(snapshot.panels.map(p=>p.key));for(const id of drafts.keys())if(!keys.has(id.split('|')[0]))drafts.delete(id);render();}
  else if(message.type==='accepted'){accept(message);render();}
  else if(message.type==='rejected'){const id=requests.get(message.requestId);if(id&&drafts.has(id))drafts.get(id).error=message.error;requests.delete(message.requestId);snapshot=api.compact(message.snapshot);revision=message.revision;showError(message.error);render();}
  else if(message.type==='disconnected'){connected=false;render();}
 });
 if(!parent||!token){get('connection').textContent='Open this table from Skins or Stringers in the WingFEGen Study window.';get('reset-button').disabled=true;return;}
 send('ready');const timer=setInterval(()=>{if(parent.closed){connected=false;render();clearInterval(timer);}else{if(connected&&Date.now()-lastSeen>8000){connected=false;render();}send(connected?'ping':'ready');}},2000);window.addEventListener('pagehide',()=>clearInterval(timer),{once:true});
})();
