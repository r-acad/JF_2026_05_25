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
 const main=file(raw),includes=(raw.includes||[]).map(file),result={kind:'nastran',...main,includes};
 if(raw.analysis!=null){if(typeof raw.analysis!=='object'||Array.isArray(raw.analysis))throw Error('Invalid imported analysis settings.');result.analysis=JSON.parse(JSON.stringify(raw.analysis));}return result;
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
 function create({document:doc=globalThis.document,onImport,pickFile,prepareImporter}){
  const dialog=doc.createElement('dialog');dialog.className='nastran-import-dialog';
  dialog.innerHTML='<form><div class="nastran-import-heading"><h2>Read Nastran</h2><button id="nastran-close" type="button" aria-label="Close Nastran importer">\u00d7</button></div><p>Open a complete Nastran analysis deck (.bdf, .dat or .nas). Its IDs, case control, properties and loads are retained.</p><label for="nastran-local-path">Main deck path</label><div class="nastran-path-row"><input id="nastran-local-path" type="text" placeholder="C:\\models\\wing\\model.bdf" spellcheck="false"><button id="nastran-browse" type="button">Browse\u2026</button></div><p>Select the main deck on this computer. All INCLUDE files are read automatically relative to their containing files, without further selections. There is no file-size limit.</p><p>Save Study embeds the complete source for portable reopening. Loads \u2192 Cases and Model \u2192 Supports show the read-only source cases and boundary conditions; selecting a case updates the viewport. Display \u2192 Properties and Inspect show supported native properties. Run in JFEM uses the original deck; Sensitivity lists supported native design variables. Wing parameter forms do not modify imported decks.</p><p id="nastran-import-status" role="status" hidden></p><pre id="nastran-import-error" role="alert" hidden></pre><button id="nastran-read" type="submit" class="primary">Read deck</button></form>';
  const preparation=doc.createElement('p');preparation.id='nastran-preparation-status';preparation.setAttribute('role','status');preparation.hidden=true;dialog.querySelector('.nastran-path-row').after(preparation);
  doc.body.append(dialog);const get=id=>dialog.querySelector('#'+id),error=get('nastran-import-error'),status=get('nastran-import-status');let running=false,picking=false,settle=null,outcome=false;
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
  get('nastran-close').onclick=()=>dialog.close();
  dialog.addEventListener('cancel',event=>{if(running||picking)event.preventDefault();});
  dialog.addEventListener('close',()=>{stopPreparation();const complete=settle;settle=null;complete?.(outcome);});
  async function browse(){
   if(picking||running)return;
   picking=true;error.hidden=true;get('nastran-browse').disabled=true;get('nastran-read').disabled=true;get('nastran-close').disabled=true;
   status.hidden=false;status.textContent='Select your main deck in the system Open dialog. INCLUDE files will be resolved automatically.';
   try{
    if(!pickFile)throw Error('The system picker is unavailable. Paste the complete main-deck path.');
    const data=await pickFile({path:get('nastran-local-path').value.trim()});
    if(data.ok===false)throw Error(data.error||'Could not open the file dialog.');
    if(!data.cancelled&&data.path){get('nastran-local-path').value=data.path;get('nastran-read').focus();}
   }catch(problem){showError(problem);}
   finally{picking=false;status.hidden=true;get('nastran-browse').disabled=false;get('nastran-read').disabled=false;get('nastran-close').disabled=false;}
  }
  get('nastran-browse').onclick=browse;
  dialog.querySelector('form').onsubmit=async event=>{
   event.preventDefault();if(running||picking)return;error.hidden=true;
   const selected=get('nastran-local-path').value.trim().replace(/^"(.*)"$/,'$1');if(!selected){showError('Browse for the main deck or paste its full path. INCLUDE files will be read automatically.');return;}
   const button=get('nastran-read'),started=Date.now();running=true;button.disabled=true;get('nastran-close').disabled=true;get('nastran-browse').disabled=true;button.textContent='Reading\u2026';status.hidden=false;
   const update=()=>{status.textContent='Importing deck \u00b7 '+Math.floor((Date.now()-started)/1000)+' s. Parser preparation, file reading and geometry stages are shown in Log.';};update();const timer=setInterval(update,1000);
   try{if(await onImport({path:selected})){outcome=true;dialog.close();}else throw Error('The deck was not loaded. Wait for the current operation to finish and try again.');}
   catch(problem){showError(problem);if(!dialog.open)dialog.showModal();}
   finally{clearInterval(timer);running=false;status.hidden=true;button.disabled=false;get('nastran-close').disabled=false;get('nastran-browse').disabled=false;button.textContent='Read deck';}
  };
  return{open(){error.hidden=true;outcome=false;dialog.showModal();get('nastran-local-path').focus();stopPreparation();prepare(true,preparationSerial);const promise=new Promise(resolve=>{settle=resolve;});browse();return promise;},destroy(){stopPreparation();settle?.(false);settle=null;dialog.remove();}};
 }
 return{source,path,includeReferences,relativeInclude,uploadSource,create};
});
