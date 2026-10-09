/* Imported decks remain the source of truth; no wing reconstruction. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingNastranImport=api;})(globalThis,function(){
 'use strict';
 function path(value){
  if(typeof value!=='string'||!value||value.length>512)throw Error('A deck filename is required.');
  const name=value.replaceAll('\\','/');
  if(name.startsWith('/')||/[\x00-\x1f:]/.test(name)||name.split('/').some(p=>!p||p==='.'||p==='..'))throw Error('Use relative INCLUDE filenames without parent directories or drive letters: '+value);
  return name;
 }
 function source(raw){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||raw.kind!=='nastran'||typeof raw.text!=='string'||!raw.text.trim()||!Array.isArray(raw.includes||[]))throw Error('The imported Nastran source is incomplete.');
  const seen=new Set();
  // Do not encode/copy entire decks just to check their size. Large native
  // files and their INCLUDE trees are normal inputs, not an import error.
  const file=item=>{if(!item||typeof item.text!=='string'||item.text.includes('\0'))throw Error('Nastran files must contain plain text.');const name=path(item.name),key=name.toLowerCase();if(seen.has(key))throw Error('Duplicate imported filename: '+name);seen.add(key);return{name,text:item.text};};
 const main=file(raw),includes=(raw.includes||[]).map(file);return{kind:'nastran',...main,includes};
 }
 function includeReferences(text,name){
  const references=[];let pending='';
  for(const match of text.matchAll(/[^\r\n]*(?:\r?\n|$)/g)){
   const line=match[0].trim();if(!pending&&!/^INCLUDE(?:\s|,|$)/i.test(line))continue;
   pending+=line;const entry=/^INCLUDE\s*,?\s*(?:'([^']+)'|"([^"]+)"|([^\s$'"]+))\s*(?:\$.*)?$/i.exec(pending);
   if(entry){references.push((entry[1]||entry[2]||entry[3]).trim());pending='';}
   else if((pending.match(/'/g)||[]).length%2===0&&(pending.match(/"/g)||[]).length%2===0)throw Error('Malformed INCLUDE in '+name+': '+pending);
  }
  if(pending)throw Error('Unterminated INCLUDE in '+name+': '+pending);return references;
 }
 function relativeInclude(parent,reference){
  const value=reference.replaceAll('\\','/');if(value.startsWith('/')||value.includes(':'))throw Error('This INCLUDE uses an absolute path: '+reference+'. Use the local main-deck path option to read it automatically.');
  const parts=parent.split('/').slice(0,-1);for(const part of value.split('/')){if(!part||part==='.')continue;if(part==='..'){if(!parts.length)throw Error('INCLUDE is outside the selected folder: '+reference+'. Select its common parent folder or use the local main-deck path option.');parts.pop();}else parts.push(part);}return path(parts.join('/'));
 }
 async function uploadSource(main,files){
  const relative=f=>f.webkitRelativePath?f.webkitRelativePath.split('/').slice(1).join('/'):f.name;
  const candidates=files.filter(f=>f.webkitRelativePath&&f.name===main.name&&f.size===main.size);
  if(candidates.length>1)throw Error('The selected folder contains more than one matching main deck. Select its containing folder directly.');
  const mainName=path(candidates.length?relative(candidates[0]):main.name),available=new Map(),contents=new Map(),active=new Set();
  for(const file of files){const name=path(relative(file)),key=name.toLowerCase();if(!available.has(key))available.set(key,{name,file});}
  available.set(mainName.toLowerCase(),{name:mainName,file:main});
  async function read(name){
   const key=name.toLowerCase();if(active.has(key))throw Error('Cyclic INCLUDE dependency: '+name);if(contents.has(key))return;
   if(active.size>=64)throw Error('INCLUDE nesting exceeds 64 levels: '+name);
   const item=available.get(key);if(!item)throw Error('INCLUDE file not found in the selected folder: '+name+'. Choose the common model folder, or use the local main-deck path option.');
   active.add(key);const text=await item.file.text();if(text.includes('\0'))throw Error('Nastran file contains binary data: '+name);contents.set(key,{name,text});
   for(const reference of includeReferences(text,name))await read(relativeInclude(name,reference));active.delete(key);
  }
  await read(mainName);const mainSource=contents.get(mainName.toLowerCase());return source({kind:'nastran',...mainSource,includes:[...contents].filter(([key])=>key!==mainName.toLowerCase()).map(([,item])=>item)});
 }
 function create({document:doc=globalThis.document,onImport,browseFiles,prepareImporter}){
  const dialog=doc.createElement('dialog');dialog.className='nastran-import-dialog';
  dialog.innerHTML='<form><div class="nastran-import-heading"><h2>Read Nastran</h2><button id="nastran-close" type="button" aria-label="Close Nastran importer">\u00d7</button></div><p>Open a complete Nastran analysis deck (.bdf, .dat or .nas). Its IDs, case control, properties and loads are retained.</p><label for="nastran-local-path">Main deck path</label><div class="nastran-path-row"><input id="nastran-local-path" type="text" placeholder="C:\\models\\wing\\model.bdf" spellcheck="false"><button id="nastran-browse" type="button">Browse\u2026</button></div><p>Select the main deck on this computer. All INCLUDE files are read automatically relative to their containing files, without further selections. There is no file-size limit.</p><p>Save Study embeds the complete source for portable reopening. Loads \u2192 Cases and Model \u2192 Supports show the read-only source cases and boundary conditions; selecting a case updates the viewport. Display \u2192 Properties and Inspect show supported native properties. Run in JFEM uses the original deck; Sensitivity lists supported native design variables. Wing parameter forms do not modify imported decks.</p><p id="nastran-import-status" role="status" hidden></p><pre id="nastran-import-error" role="alert" hidden></pre><button id="nastran-read" type="submit" class="primary">Read deck</button></form>';
  const browser=doc.createElement('section');browser.id='nastran-file-browser';browser.hidden=true;browser.setAttribute('aria-label','Files on this computer');
  browser.innerHTML='<div class="nastran-import-heading"><h3>Files on this computer</h3><button id="nastran-browser-close" type="button">Cancel browsing</button></div><div class="nastran-path-row"><button id="nastran-folder-up" type="button" title="Parent folder">Up</button><input id="nastran-folder-path" aria-label="Folder path" spellcheck="false"><button id="nastran-folder-go" type="button">Go</button></div><div class="nastran-folder-options"><select id="nastran-drives" aria-label="Drive"><option value="">Drives</option></select><label><input id="nastran-all-files" type="checkbox">All files</label></div><p id="nastran-folder-status" role="status"></p><div id="nastran-folder-list" role="group" aria-label="Folders and Nastran files"></div><button id="nastran-folder-more" type="button" hidden>More files</button>';
  dialog.querySelector('.nastran-path-row').after(browser);
  const preparation=doc.createElement('p');preparation.id='nastran-preparation-status';preparation.setAttribute('role','status');preparation.hidden=true;browser.after(preparation);
  doc.body.append(dialog);const get=id=>dialog.querySelector('#'+id),error=get('nastran-import-error'),status=get('nastran-import-status');let running=false,settle=null,outcome=false,browseController=null,browseSerial=0,browseDirectory='',parent=null,nextOffset=null;
  let preparationTimer=null,preparationSerial=0;
  const stopPreparation=()=>{preparationSerial++;clearTimeout(preparationTimer);preparationTimer=null;};
  async function prepare(start,serial){
   if(!prepareImporter)return;
   preparation.hidden=false;if(start)preparation.textContent='Preparing importer\u2026 You can browse local files while it starts.';
   try{
    const data=await prepareImporter(start);if(serial!==preparationSerial)return;
    const seconds=Number(data.seconds||0).toFixed(1);
    preparation.textContent=data.state==='ready'?'Importer ready \u00b7 preparation '+seconds+' s':data.state==='failed'?'Preparation failed: '+data.stage+' Read deck can retry.':(data.stage||'Preparing importer')+' \u00b7 '+seconds+' s. You can browse while this runs.';
    preparation.dataset.state=data.state;
    if(data.state==='preparing')preparationTimer=setTimeout(()=>prepare(false,serial),750);
   }catch(problem){if(serial===preparationSerial)preparation.textContent='Importer preparation unavailable: '+(problem.message||problem)+'. Read deck remains available.';}
  }
  const showError=problem=>{error.textContent=problem?.message||String(problem);error.hidden=false;};
  const stopBrowse=()=>{browseSerial++;browseController?.abort();browseController=null;browser.hidden=true;};
  get('nastran-close').onclick=()=>{stopBrowse();dialog.close();};
  dialog.addEventListener('cancel',event=>{if(running)event.preventDefault();});
  dialog.addEventListener('close',()=>{stopBrowse();stopPreparation();const complete=settle;settle=null;complete?.(outcome);});
  async function navigate(folder,offset=0){
   error.hidden=true;browser.hidden=false;browseController?.abort();browseController=new AbortController();const controller=browseController,serial=++browseSerial,started=Date.now(),folderStatus=get('nastran-folder-status');let timedOut=false;
   const timer=setInterval(()=>{folderStatus.textContent='Reading local folder \u00b7 '+Math.floor((Date.now()-started)/1000)+' s';},1000);
   const timeout=setTimeout(()=>{timedOut=true;controller.abort();},30000);
   folderStatus.textContent='Reading local folder\u2026';get('nastran-folder-more').disabled=true;
   try{
    if(!browseFiles)throw Error('Local browsing is unavailable. Paste the complete main-deck path.');
    const data=await browseFiles({path:folder,all:get('nastran-all-files').checked,offset,signal:controller.signal});if(serial!==browseSerial)return;
    if(data.ok===false)throw Error(data.error||'Could not read this folder.');
    browseDirectory=data.directory;parent=data.parent;nextOffset=data.next_offset;get('nastran-folder-path').value=data.directory;get('nastran-folder-up').disabled=!parent;
    const drives=get('nastran-drives');drives.replaceChildren();const prompt=doc.createElement('option');prompt.value='';prompt.textContent='Drives';drives.append(prompt);
    for(const drive of data.drives||[]){const option=doc.createElement('option');option.value=drive;option.textContent=drive;drives.append(option);}
    const list=get('nastran-folder-list');if(!offset)list.replaceChildren();
    for(const entry of data.entries||[]){
     const button=doc.createElement('button');button.type='button';button.className='nastran-file-entry';button.dataset.kind=entry.directory?'folder':'file';button.title=entry.path;
     const name=doc.createElement('span');name.textContent=(entry.directory?'\u25b8 ':'')+entry.name;button.append(name);
     if(!entry.directory&&entry.bytes!=null){const size=doc.createElement('small');size.textContent=entry.bytes>=1048576?(entry.bytes/1048576).toFixed(1)+' MiB':Math.ceil(entry.bytes/1024)+' KiB';button.append(size);}
     button.onclick=()=>{if(entry.directory)navigate(entry.path);else{get('nastran-local-path').value=entry.path;stopBrowse();get('nastran-read').focus();}};list.append(button);
    }
    folderStatus.textContent=data.total?'Select a folder or choose the main deck \u00b7 '+Math.min(offset+(data.entries||[]).length,data.total)+' of '+data.total+' entries':'No matching files or folders. Enable All files or choose another folder.';
    get('nastran-folder-more').hidden=nextOffset==null;
   }catch(problem){if(serial===browseSerial){folderStatus.textContent='Folder could not be read. Change the path or cancel browsing.';if(timedOut)showError('Reading this folder timed out. Choose another folder or paste the complete main-deck path.');else if(problem.name!=='AbortError')showError(problem);}}
   finally{clearInterval(timer);clearTimeout(timeout);if(serial===browseSerial){browseController=null;get('nastran-folder-more').disabled=false;}}
  }
  get('nastran-browse').onclick=()=>navigate(get('nastran-local-path').value.trim().replace(/^"(.*)"$/,'$1')||browseDirectory);
  get('nastran-browser-close').onclick=()=>{stopBrowse();get('nastran-browse').focus();};
  get('nastran-folder-up').onclick=()=>{if(parent)navigate(parent);};
  get('nastran-folder-go').onclick=()=>navigate(get('nastran-folder-path').value);
  get('nastran-folder-path').onkeydown=event=>{if(event.key==='Enter'){event.preventDefault();navigate(event.target.value);}};
  get('nastran-drives').onchange=event=>{if(event.target.value)navigate(event.target.value);};
  get('nastran-all-files').onchange=()=>navigate(browseDirectory);
  get('nastran-folder-more').onclick=()=>{if(nextOffset!=null)navigate(browseDirectory,nextOffset);};
  dialog.querySelector('form').onsubmit=async event=>{
   event.preventDefault();if(running)return;error.hidden=true;
   const selected=get('nastran-local-path').value.trim().replace(/^"(.*)"$/,'$1');if(!selected){showError('Browse for the main deck or paste its full path. INCLUDE files will be read automatically.');return;}
   stopBrowse();const button=get('nastran-read'),started=Date.now();running=true;button.disabled=true;get('nastran-close').disabled=true;get('nastran-browse').disabled=true;button.textContent='Reading\u2026';status.hidden=false;
   const update=()=>{status.textContent='Importing deck \u00b7 '+Math.floor((Date.now()-started)/1000)+' s. Parser preparation, file reading and geometry stages are shown in Log.';};update();const timer=setInterval(update,1000);
   try{if(await onImport({path:selected})){outcome=true;dialog.close();}else throw Error('The deck was not loaded. Wait for the current operation to finish and try again.');}
   catch(problem){showError(problem);if(!dialog.open)dialog.showModal();}
   finally{clearInterval(timer);running=false;status.hidden=true;button.disabled=false;get('nastran-close').disabled=false;get('nastran-browse').disabled=false;button.textContent='Read deck';}
  };
  return{open(){error.hidden=true;outcome=false;dialog.showModal();get('nastran-local-path').focus();stopPreparation();prepare(true,preparationSerial);return new Promise(resolve=>{settle=resolve;});},destroy(){stopBrowse();stopPreparation();settle?.(false);settle=null;dialog.remove();}};
 }
 return{source,path,includeReferences,relativeInclude,uploadSource,create};
});
