/* Imported decks remain the source of truth; no wing reconstruction. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingNastranImport=api;})(globalThis,function(){
 'use strict';const MAX_BYTES=32*1024*1024;
 function path(value){
  if(typeof value!=='string'||!value||value.length>512)throw Error('A deck filename is required.');
  const name=value.replaceAll('\\','/');
  if(name.startsWith('/')||/[\x00-\x1f:]/.test(name)||name.split('/').some(p=>!p||p==='.'||p==='..'))throw Error('Use relative INCLUDE filenames without parent directories or drive letters: '+value);
  return name;
 }
 function source(raw){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||raw.kind!=='nastran'||typeof raw.text!=='string'||!raw.text.trim()||!Array.isArray(raw.includes||[]))throw Error('The imported Nastran source is incomplete.');
  if((raw.includes||[]).length>128)throw Error('At most 128 INCLUDE files can be imported.');
  let size=0;const seen=new Set();
  const file=item=>{if(!item||typeof item.text!=='string'||item.text.includes('\0'))throw Error('Nastran files must contain plain text.');const name=path(item.name),key=name.toLowerCase();if(seen.has(key))throw Error('Duplicate imported filename: '+name);seen.add(key);size+=new TextEncoder().encode(item.text).length;if(size>MAX_BYTES)throw Error('Imported Nastran files exceed 32 MiB.');return{name,text:item.text};};
  const main=file(raw),includes=(raw.includes||[]).map(file);return{kind:'nastran',...main,includes};
 }
 function create({document:doc=globalThis.document,onImport}){
  const dialog=doc.createElement('dialog');dialog.className='nastran-import-dialog';
  dialog.innerHTML='<form method="dialog"><div class="nastran-import-heading"><h2>Read Nastran</h2><button value="cancel" aria-label="Close Nastran importer">×</button></div><p>Open a complete Nastran analysis deck (.bdf, .dat or .nas). Its IDs, case control, properties and loads are retained. The solver reports unsupported cards; the viewer reports entities it cannot draw.</p><label>Main deck<input id="nastran-main-file" type="file" accept=".bdf,.dat,.nas,.bulk,.pch,text/plain"></label><label>INCLUDE files (optional)<input id="nastran-include-files" type="file" multiple></label><label>Or an INCLUDE folder (optional)<input id="nastran-include-folder" type="file" webkitdirectory multiple></label><p>Upload every referenced INCLUDE. Files from a folder keep their path relative to that folder. Absolute paths and parent-directory traversal are not followed. Saving the Study embeds these source files so it can be reopened on another computer.</p><p>Use Display → Properties and Inspect to review supported native properties. Run in JFEM uses this deck; Sensitivity lists supported native design variables. Wing parameter forms do not modify imported decks. Use New Study or load a generated Study to return to the wing generator.</p><p id="nastran-import-error" role="alert" hidden></p><button id="nastran-read" type="button" class="primary">Read deck</button></form>';
  doc.body.append(dialog);const get=id=>dialog.querySelector('#'+id),error=get('nastran-import-error');
  get('nastran-read').onclick=async()=>{
   error.hidden=true;const main=get('nastran-main-file').files[0];if(!main){error.textContent='Choose the main deck first.';error.hidden=false;return;}
   const files=[...get('nastran-include-files').files,...get('nastran-include-folder').files];
   if(main.size+files.reduce((sum,f)=>sum+f.size,0)>MAX_BYTES){error.textContent='Imported files exceed 32 MiB.';error.hidden=false;return;}
   const button=get('nastran-read');button.disabled=true;button.textContent='Reading…';
   try{const includes=[];for(const f of files){const name=f.webkitRelativePath?f.webkitRelativePath.split('/').slice(1).join('/'):f.name;if(name===main.name)continue;includes.push({name,text:await f.text()});}const value=source({kind:'nastran',name:main.name,text:await main.text(),includes});dialog.close();if(!await onImport(value)){error.textContent='Import failed. See the full error in the Study window and Log.';error.hidden=false;dialog.showModal();}}
   catch(problem){error.textContent=problem.message;error.hidden=false;if(!dialog.open)dialog.showModal();}
   finally{button.disabled=false;button.textContent='Read deck';}
  };
  return{open(){error.hidden=true;dialog.showModal();},destroy(){dialog.remove();}};
 }
 return{source,path,MAX_BYTES,create};
});
