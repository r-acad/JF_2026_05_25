(function(){
 'use strict';
 const api=WingPanelTableData,CHANNEL='WingFEGen.panel-tables.v1',token=location.hash.slice(1),parent=window.opener,origin=location.origin;
 const kind=new URLSearchParams(location.search).get('kind')==='stringers'?'stringers':'skins',target=api.section(kind),get=id=>document.getElementById(id),drafts=new Map(),requests=new Map(),queued=new Map();
 let snapshot=api.compact(),revision=0,connected=false,lastSeen=Date.now(),counter=0,rendering=false;
 const title=kind==='skins'?'Skin panel properties':'Stringer panel properties';document.title='WingFEGen · '+title;get('table-title').textContent=title;
 for(const f of api.FIELDS[kind]){const option=document.createElement('option');option.value=f.name;option.textContent=f.label+(f.unit?' ('+f.unit+')':'');get('property').append(option);}
 const send=(type,payload={})=>{if(parent&&!parent.closed)parent.postMessage({channel:CHANNEL,token,type,kind,revision,...payload},origin);};
 const identity=(key,field)=>key+'|'+field;
 const notifyDrafts=()=>send('draft-status',{count:drafts.size+requests.size+queued.size});
 function showError(message){get('table-error').textContent=message||'';get('table-error').hidden=!message;}
 function status(){const control=get('connection');control.classList.toggle('warning',!connected||!!snapshot.error||snapshot.modelDirty||drafts.size>0);control.textContent=!connected?'Study window disconnected. Reopen this table from the Study to reconnect.':snapshot.error||snapshot.busy?'A Study file operation is in progress. Your drafts are retained.':requests.size||queued.size?'Applying table edits · you can continue editing other cells. No analysis is started.':drafts.size?'Study modified · finish each cell with Enter or Tab; Escape cancels its unapplied edit.':snapshot.modelDirty?'Study modified · last generated panel layout. Live mesh updates after your final edit; results require Run in JFEM.':snapshot.updating?'Mesh updating · you can keep editing; the latest properties will be used.':'Live from Study · edits update the mesh when Live mesh is enabled. Analysis runs only with Run in JFEM.';if(snapshot.error)control.textContent=snapshot.error;}
 function dormant(value,field){return kind==='skins'&&(value.kind==='sandwich'?['thickness','material'].includes(field):['face_thickness','core_thickness','face_material','core_material'].includes(field));}
 function render(){
  rendering=true;
  const active=document.activeElement,focus=active?.dataset.editorId,selection=active?.tagName==='INPUT'?[active.selectionStart,active.selectionEnd]:null,scroll=get('table-scroll'),left=scroll.scrollLeft,top=scroll.scrollTop;
  const layout=api.matrix(snapshot,get('skin').value),field=api.FIELDS[kind].find(f=>f.name===get('property').value),head=get('panel-table').tHead,body=get('panel-table').tBodies[0];head.replaceChildren();body.replaceChildren();
  const h=head.insertRow(),corner=document.createElement('th');corner.scope='col';corner.textContent='Stringer ↓';h.append(corner);for(const bay of layout.bays){const th=document.createElement('th');th.scope='col';th.textContent='R'+bay+'–R'+(bay+1);h.append(th);}
  const materialNames=new Map(api.materialList(snapshot.parameters).map(m=>[m.id,m.name]));
  for(const stringer of layout.stringers){const tr=body.insertRow(),th=document.createElement('th');th.scope='row';th.textContent=(get('skin').value==='upper'?'U':'L')+stringer;tr.append(th);
   for(const bay of layout.bays){const td=tr.insertCell(),panels=layout.cells.get(stringer+':'+bay)||[];if(!panels.length){td.className='no-panel';td.textContent='—';continue;}
    for(const panel of panels){const id=identity(panel.key,field.name),draft=drafts.get(id),record=api.override(snapshot,panel.key),explicit=record?.[target]?.[field.name],base=api.inherited(snapshot,panel,kind),effective=api.effective(snapshot,panel,kind),wrap=document.createElement('div');wrap.className='panel-cell';wrap.dataset.panelKey=panel.key;wrap.classList.toggle('explicit',explicit!==undefined);wrap.classList.toggle('invalid',!!draft?.error);wrap.classList.toggle('pending',queued.has(id)||[...requests.values()].some(r=>r.id===id));
     const label=document.createElement('strong');label.textContent='P'+panel.id+(panels.length>1?' · segment '+panel.segment:'');label.title=panel.key;wrap.append(label);
     const inherited=base[field.name],current=effective[field.name],format=value=>field.type==='material'?(materialNames.get(value)||'Missing material')+' (ID '+value+')':field.type==='kind'?(value==='sandwich'?'Sandwich':'Monolithic'):api.display(value,field)+(field.unit?' '+field.unit:'');
     const control=document.createElement(field.type==='number'?'input':'select');control.dataset.editorId=id;control.dataset.panel=String(panel.id);control.dataset.field=field.name;control.setAttribute('aria-label','P'+panel.id+' '+field.label+(field.unit?' ('+field.unit+')':''));
     if(field.type==='number'){control.type='text';control.inputMode='decimal';control.placeholder=api.display(inherited,field);control.value=draft?draft.raw:explicit===undefined?'':api.display(explicit,field);}
     else{const choices=[['','Inherit: '+format(inherited)],...(field.type==='kind'?[['monolithic','Monolithic'],['sandwich','Sandwich · face/core/face']]:api.materialList(snapshot.parameters).map(m=>[m.id,m.name+' (ID '+m.id+')']))];for(const[value,text]of choices){const option=document.createElement('option');option.value=String(value);option.textContent=text;control.append(option);}if(explicit!==undefined&&!choices.some(c=>String(c[0])===String(explicit))){const option=document.createElement('option');option.value=String(explicit);option.textContent='Missing material ID '+explicit;control.append(option);}control.value=draft?draft.raw:explicit===undefined?'':String(explicit);}
     control.disabled=!connected||snapshot.busy||!!snapshot.error||!snapshot.layout_token;control.title='P'+panel.id+' · '+(explicit===undefined?'Inherited: ':'Explicit: ')+format(current)+'; clear to inherit '+format(inherited);wrap.append(control);
     const note=document.createElement('small');note.textContent=(explicit===undefined?'Inherited · ':'Override · ')+format(current);wrap.append(note);
     if(dormant(effective,field.name)){const warning=document.createElement('small');warning.className='dormant';warning.textContent='Dormant for '+effective.kind+' construction';wrap.append(warning);}
     if(kind==='skins'&&effective.kind==='sandwich'){const total=document.createElement('small');total.textContent='Total laminate '+api.display(2*effective.face_thickness+effective.core_thickness,{scale:1000})+' mm';wrap.append(total);}
     const error=document.createElement('small');error.className='cell-error';error.textContent=draft?.error||'';error.hidden=!draft?.error;wrap.append(error);td.append(wrap);
     control.addEventListener('input',()=>{const prior=drafts.get(id);drafts.set(id,{raw:control.value,error:'',version:++counter,base:prior&&!prior.error?prior.base:api.fieldState(snapshot,kind,panel.key,field.name)});queued.delete(id);wrap.classList.remove('invalid');error.hidden=true;notifyDrafts();status();});
     control.addEventListener('change',()=>{if(!rendering&&control.isConnected)commit(panel,field,control.value,id);});
     // A live snapshot recreates the focused input. Its restored value is then
     // the browser's initial value, so Tab need not emit a native change event.
     control.addEventListener('blur',()=>{if(!rendering&&control.isConnected&&drafts.has(id))commit(panel,field,control.value,id);});
     control.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();control.blur();}if(event.key==='Escape'){event.preventDefault();drafts.delete(id);queued.delete(id);render();}});
    }
   }
  }
  get('empty').hidden=!!layout.stringers.length;get('panel-table').hidden=!layout.stringers.length;get('table-count').textContent=layout.stringers.length+' stringers · '+layout.bays.length+' rib bays · '+snapshot.panels.filter(p=>p.skin===get('skin').value).length+' panels';
  get('reset-button').disabled=!connected||snapshot.busy||!!snapshot.error||!api.rows(snapshot.parameters).length||requests.size>0||queued.size>0;status();scroll.scrollLeft=left;scroll.scrollTop=top;
  if(focus){const next=Array.from(body.querySelectorAll('[data-editor-id]')).find(el=>el.dataset.editorId===focus);if(next&&!next.disabled){next.focus({preventScroll:true});if(selection&&next.setSelectionRange)next.setSelectionRange(...selection);}}
  rendering=false;notifyDrafts();
 }
 function commit(panel,field,raw,id){
  const prior=drafts.get(id),draft=prior&&prior.raw===raw?prior:{raw,error:'',version:++counter,base:api.fieldState(snapshot,kind,panel.key,field.name)};
  if(queued.get(id)?.version===draft.version||[...requests.values()].some(p=>p.id===id&&p.version===draft.version))return;
  try{api.update(snapshot,kind,panel.key,field.name,raw);showError('');draft.error='';drafts.set(id,draft);queued.set(id,{id,key:panel.key,field:field.name,value:raw,version:draft.version,base:draft.base,layoutToken:snapshot.layout_token});pump();render();}
  catch(error){draft.error=error.message;drafts.set(id,draft);queued.delete(id);render();}
 }
 function pump(){if(!connected||snapshot.busy||snapshot.error||requests.size||!queued.size)return;const[id,patch]=queued.entries().next().value;queued.delete(id);const requestId=kind+'-'+Date.now()+'-'+(++counter);requests.set(requestId,patch);notifyDrafts();send('edit',{...patch,requestId});}
 get('skin').onchange=render;get('property').onchange=render;get('help-button').onclick=()=>{get('help').hidden=!get('help').hidden;get('help-button').setAttribute('aria-expanded',String(!get('help').hidden));};
 get('reset-button').onclick=()=>{if(!confirm('Reset all '+api.rows(snapshot.parameters).length+' panel override rows in this Study? Both skin and stringer overrides will return to shared defaults.'))return;const requestId=kind+'-reset-'+(++counter);requests.set(requestId,{id:'__reset__'});send('reset',{requestId});render();};
 function accept(message){const requestId=message.requestId??message.applied,patch=requests.get(requestId);if(!patch)return;if(patch.id==='__reset__'){drafts.clear();queued.clear();}else{const draft=drafts.get(patch.id);if(draft?.version===patch.version)drafts.delete(patch.id);else if(draft){draft.base=api.fieldState(snapshot,kind,patch.key,patch.field);const next=queued.get(patch.id);if(next)next.base=draft.base;}}requests.delete(requestId);}
 window.addEventListener('message',event=>{const message=event.data;if(event.source!==parent||event.origin!==origin||!message||message.channel!==CHANNEL||message.token!==token||message.kind!==kind)return;lastSeen=Date.now();
  if(message.type==='snapshot'){const changedLayout=snapshot.layout_token&&snapshot.layout_token!==message.snapshot.layout_token;if(changedLayout&&drafts.size){drafts.clear();queued.clear();requests.clear();showError('The panel layout changed. Unapplied cell edits were cleared; review the new P labels before editing.');}if(message.resetAll||message.resetDrafts){drafts.clear();queued.clear();requests.clear();showError('');}snapshot=api.compact(message.snapshot);revision=message.revision;connected=true;accept(message);const keys=new Set(snapshot.panels.map(p=>p.key));for(const id of drafts.keys())if(!keys.has(id.split('|')[0]))drafts.delete(id);pump();render();}
  else if(message.type==='accepted'){accept(message);pump();render();}
  else if(message.type==='rejected'){const patch=requests.get(message.requestId);requests.delete(message.requestId);snapshot=api.compact(message.snapshot);revision=message.revision;if(patch&&drafts.has(patch.id)){const draft=drafts.get(patch.id);draft.error=message.error;draft.base=api.fieldState(snapshot,kind,patch.key,patch.field);queued.delete(patch.id);}showError(message.error);pump();render();}
  else if(message.type==='disconnected'){connected=false;render();}
 });
 if(!parent||!token){get('connection').textContent='Open this table from Skins or Stringers in the WingFEGen Study window.';get('reset-button').disabled=true;return;}
 send('ready');const timer=setInterval(()=>{if(parent.closed){connected=false;render();clearInterval(timer);}else{if(connected&&Date.now()-lastSeen>8000){connected=false;render();}send(connected?'ping':'ready');}},2000);window.addEventListener('pagehide',()=>{send('draft-status',{count:0});clearInterval(timer);},{once:true});
})();
