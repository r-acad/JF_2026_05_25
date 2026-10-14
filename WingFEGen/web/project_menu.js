(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingProjectMenu=api;})(globalThis,function(){
 'use strict';
 function install(doc){
  if(doc.getElementById('btn-project'))return;
  const actions=doc.getElementById('actions');if(!actions)return;
  const wrap=doc.createElement('div');wrap.id='project-actions';
  const toggle=doc.createElement('button');toggle.id='btn-project';toggle.type='button';toggle.textContent='Project ▾';toggle.setAttribute('aria-haspopup','menu');toggle.setAttribute('aria-controls','project-menu');toggle.setAttribute('aria-expanded','false');
  const menu=doc.createElement('div');menu.id='project-menu';menu.hidden=true;menu.setAttribute('role','menu');menu.setAttribute('aria-label','Project files');wrap.append(toggle,menu);actions.prepend(wrap);
  const group=(label)=>{const host=doc.createElement('div');host.className='project-command-group';host.setAttribute('role','group');host.setAttribute('aria-label',label);const title=doc.createElement('div');title.className='project-command-heading';title.textContent=label;host.append(title);menu.append(host);return host;};
  const move=(id,host)=>{const button=doc.getElementById(id);if(button){host.append(button);button.setAttribute('role','menuitem');}return button;};
  for(const [label,ids,helpId]of [
   ['Study',['btn-new-study','btn-load-model','btn-save-model','btn-save-model-as','btn-study-notes'],'study-help'],
   ['TOML parameters',['btn-load-toml','btn-save-toml','btn-view-toml'],'toml-help'],
   ['Reference',['btn-read-reference','btn-reference'],null]]){
    const host=group(label);for(const id of ids)move(id,host);
    const help=helpId&&doc.getElementById(helpId);if(help){const details=doc.createElement('details'),summary=doc.createElement('summary');summary.textContent='About '+label.toLowerCase()+' files';details.append(summary,help);host.append(details);}
  }
  for(const old of actions.querySelectorAll('.file-action-group'))old.remove();
  const exported=doc.getElementById('panel-geometry-export');
  if(exported){
   const host=group('Export'),button=doc.createElement('button');button.id='btn-project-export';button.type='button';button.textContent='Export geometry…';button.setAttribute('role','menuitem');button.title='Export STL or GLB with entity, deformation and reference options.';host.append(button);
   const dialog=doc.createElement('dialog');dialog.id='project-export-dialog';dialog.setAttribute('aria-label','Geometry export');const close=doc.createElement('button');close.type='button';close.className='project-dialog-close';close.textContent='×';close.setAttribute('aria-label','Close geometry export');close.onclick=()=>dialog.close();
   exported.hidden=false;exported.classList.remove('workspace-panel');exported.removeAttribute('data-workspace-panel');exported.removeAttribute('role');exported.removeAttribute('aria-labelledby');dialog.append(close,exported);doc.body.append(dialog);
   button.onclick=()=>dialog.showModal();dialog.addEventListener('close',()=>toggle.focus());
  }
  const server=doc.getElementById('server-input-menu');if(server){const host=group('Configured server file');host.append(server);for(const button of server.querySelectorAll('button'))button.setAttribute('role','menuitem');}
  const inputHeading=doc.querySelector('#panel-input h2');if(inputHeading)inputHeading.textContent='Input file';
  function close(focus=false){menu.hidden=true;toggle.setAttribute('aria-expanded','false');if(focus)toggle.focus();}
  const visibleButtons=()=>[...menu.querySelectorAll('button:not(:disabled)')].filter(button=>button.getClientRects().length);
  function open(focus=false){menu.hidden=false;toggle.setAttribute('aria-expanded','true');if(focus)visibleButtons()[0]?.focus();}
  toggle.onclick=()=>menu.hidden?open():close();
  toggle.onkeydown=event=>{if(event.key==='Escape'&&!menu.hidden){event.preventDefault();event.stopPropagation();close(true);}else if(['ArrowDown','ArrowUp'].includes(event.key)){event.preventDefault();open(true);if(event.key==='ArrowUp')visibleButtons().at(-1)?.focus();}};
  // Commands can disable themselves synchronously before this event bubbles.
  menu.addEventListener('click',event=>{if(event.target.closest('button'))close();});
  menu.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close(true);return;}if(!['ArrowDown','ArrowUp','Home','End'].includes(event.key)||event.target.matches('input,select'))return;event.preventDefault();const buttons=visibleButtons(),index=buttons.indexOf(doc.activeElement);const next=event.key==='Home'?0:event.key==='End'?buttons.length-1:(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;buttons[next]?.focus();});
  doc.addEventListener('pointerdown',event=>{if(!wrap.contains(event.target))close();});
  const save=doc.getElementById('btn-save-model');if(save){const sync=()=>{const status=save.dataset.saved;toggle.dataset.saved=status||'';toggle.title=status==='false'?'Project · unsaved definition changes (orange). New, read, save and export.':status==='true'?'Project · study definition saved (green). New, read, save and export.':'Project · new, read, save and export.';};new doc.defaultView.MutationObserver(sync).observe(save,{attributes:true,attributeFilter:['data-saved']});sync();}
  return{open,close,menu,toggle};
 }
 return{install};
});
