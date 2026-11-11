/* Imported decks remain the source of truth; no wing reconstruction. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingReferenceImport=api;})(globalThis,function(){
 'use strict';
 function path(value){
  if(typeof value!=='string'||!value||value.length>512)throw Error('A deck filename is required.');
  const name=value.replaceAll('\\','/');
  if(name.startsWith('/')||/[\x00-\x1f:]/.test(name)||name.split('/').some(p=>!p||p==='.'||p==='..'))throw Error('Use relative INCLUDE filenames without parent directories or drive letters: '+value);
  return name;
 }
 function format(name,text,requested='auto'){
  if(!['auto','reference','abaqus'].includes(requested))throw Error('Unknown imported source format.');
  if(requested!=='auto')return requested;if(/\.inp(?:\.gz)?$/i.test(name))return 'abaqus';
  const input=String(text||'');let start=0;
  while(start<input.length){let end=input.indexOf('\n',start);if(end<0)end=input.length;const line=input.slice(start,end).trim();start=end+1;if(!line||/^(?:\*\*|\$)/.test(line))continue;return /^\*(?:HEADING|NODE|ELEMENT|PART|PREPRINT|INCLUDE)(?:,|\s|$)/i.test(line)?'abaqus':'reference';}
  return 'reference';
 }
 function completion(raw){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||typeof raw.enabled!=='boolean')throw Error('Invalid Abaqus analysis completion.');
  if(!raw.enabled)return {enabled:false};
  const v={enabled:true,E:7e10,nu:.3,rho:2700,total_force:1,element_set:'ALL',constraint_set:'',constraint_dofs:'123',force_set:'',force_direction:[0,0,1],solution:'101',modes:10,...raw};
  for(const k of ['E','nu','rho','total_force'])if(!Number.isFinite(v[k]))throw Error('Invalid '+k+' value.');
  if(!(v.E>0&&v.nu>-1&&v.nu<.5&&v.rho>0))throw Error('Use E > 0, -1 < Poisson ratio < 0.5 and density > 0 in consistent units.');
  for(const k of ['element_set','constraint_set','force_set','constraint_dofs','solution']){v[k]=String(v[k]).trim();if(v[k].length>200||/[\r\n,]/.test(v[k]))throw Error('Invalid '+k+' value.');}
  if(!v.constraint_set||!/^[123]+$/.test(v.constraint_dofs))throw Error('Specify a constrained node set and solid displacement components (1, 2, 3).');
  if(!['101','103'].includes(v.solution)||v.solution==='101'&&!v.force_set)throw Error('Select SOL101 with a force node set, or SOL103.');
  if(!Number.isInteger(v.modes)||v.modes<1||v.modes>200)throw Error('Requested modes must be an integer from 1 to 200.');
  if(!Array.isArray(v.force_direction)||v.force_direction.length!==3||!v.force_direction.every(Number.isFinite)||!Math.hypot(...v.force_direction))throw Error('Force direction needs three finite components and nonzero length.');
  return Object.fromEntries(['enabled','E','nu','rho','total_force','element_set','constraint_set','constraint_dofs','force_set','force_direction','solution','modes'].map(k=>[k,v[k]]));
 }
 function source(raw){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||raw.kind!=='reference'||typeof raw.text!=='string'||!raw.text.trim()||!Array.isArray(raw.includes||[]))throw Error('The imported Reference source is incomplete.');
  const seen=new Set();
  // Do not encode/copy entire decks just to check their size. Large native
  // files and their INCLUDE trees are normal inputs, not an import error.
  const file=item=>{if(!item||typeof item.text!=='string'||item.text.includes('\0'))throw Error('Reference files must contain plain text.');const name=path(item.name),key=name.toLowerCase();if(seen.has(key))throw Error('Duplicate imported filename: '+name);seen.add(key);return{name,text:item.text};};
 const main=file(raw),includes=(raw.includes||[]).map(file),result={kind:'reference',...main,includes};
 if(raw.format!=null||format(main.name,main.text)==='abaqus')result.format=format(main.name,main.text,raw.format||'auto');
 if(raw.completion!=null){if(result.format!=='abaqus')throw Error('Analysis completion applies only to Abaqus inputs.');result.completion=completion(raw.completion);}
 if(raw.analysis!=null){if(typeof raw.analysis!=='object'||Array.isArray(raw.analysis))throw Error('Invalid imported analysis settings.');result.analysis=JSON.parse(JSON.stringify(raw.analysis));}return result;
 }
 function includeReferences(text,name){
  const references=[];let pending='';
  for(const match of text.matchAll(/[^\r\n]*(?:\r?\n|$)/g)){
   const line=match[0].trim();if(/^\*INCLUDE(?:,|\s|$)/i.test(line)){
    const item=/^\*INCLUDE\s*,\s*INPUT\s*=\s*(.*?)\s*$/i.exec(line);if(!item)throw Error('Malformed Abaqus *INCLUDE in '+name);const target=item[1].replace(/^(['"])(.*)\1$/,'$2');if(!target)throw Error('Abaqus *INCLUDE has no filename in '+name);references.push(target);continue;
   }if(!pending&&!/^INCLUDE(?:\s|,|$)/i.test(line))continue;
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
   active.add(key);const text=await item.file.text();if(text.includes('\0'))throw Error('Reference file contains binary data: '+name);contents.set(key,{name,text});
   for(const reference of includeReferences(text,name))await read(relativeInclude(name,reference));active.delete(key);
  }
  await read(mainName);const mainSource=contents.get(mainName.toLowerCase());return source({kind:'reference',...mainSource,includes:[...contents].filter(([key])=>key!==mainName.toLowerCase()).map(([,item])=>item)});
 }
 function create({document:doc=globalThis.document,onImport,pickFile,pickFolder,scanFolder,listFolder,prepareImporter}){
  const dialog=doc.createElement('dialog');dialog.className='reference-import-dialog';
  dialog.innerHTML='<form><div class="reference-import-heading"><h2>Read Nastran</h2><button id="reference-close" type="button" aria-label="Close Nastran importer">\u00d7</button></div><p>Open a Nastran deck (.bdf, .dat or .nas) or Abaqus input (.inp or .inp.gz). Node and element IDs, sections, named sets and supported analysis definitions are retained.</p><label for="reference-local-path">Main deck path</label><div class="reference-path-row"><input id="reference-local-path" type="text" placeholder="C:\\models\\wing\\model.bdf" spellcheck="false"><button id="reference-browse" type="button">Browse\u2026</button></div><p>Select the main deck on this computer. All INCLUDE files are read automatically relative to their containing files, without further selections. There is no file-size limit.</p><p>Save Study embeds the complete source for portable reopening. Loads \u2192 Cases and Model \u2192 Constraints show the read-only source cases and boundary conditions; selecting a case updates the viewport. Display \u2192 Properties and Inspect show supported native properties. Run in JFEM uses the original deck; Sensitivity lists supported native design variables where available; Abaqus sensitivity is not yet supported. Lifting surface parameter forms do not modify imported decks.</p><p id="reference-import-status" role="status" hidden></p><pre id="reference-import-error" role="alert" hidden></pre><button id="reference-read" type="submit" class="primary">Read deck</button></form>';
  const formatRow=doc.createElement('label');formatRow.textContent='Input format ';const formatSelect=doc.createElement('select');formatSelect.id='reference-format';
  for(const [value,label]of [['auto','Detect from filename and contents'],['reference','Nastran deck (.bdf, .dat, .nas)'],['abaqus','Abaqus input (.inp or .inp.gz)']]){const option=doc.createElement('option');option.value=value;option.textContent=label;formatSelect.append(option);}formatRow.append(formatSelect);dialog.querySelector('.reference-path-row').before(formatRow);
  const single=doc.createElement('section');single.id='reference-single-source';const pathRow=dialog.querySelector('.reference-path-row'),pathLabel=dialog.querySelector('label[for=reference-local-path]'),singleHelp=pathRow.nextElementSibling;
  formatRow.before(single);single.append(formatRow,pathLabel,pathRow,singleHelp);
  const modeRow=doc.createElement('label');modeRow.textContent='Read from ';const modeSelect=doc.createElement('select');modeSelect.id='reference-mode';modeSelect.title='Read a main deck with its INCLUDE tree, or combine the Nastran fragments in a folder and its subfolders.';
  for(const[value,label]of[['single','Single main deck and its INCLUDE files'],['folder','Folder of Nastran fragments · recursive']]){const option=doc.createElement('option');option.value=value;option.textContent=label;modeSelect.append(option);}modeRow.append(modeSelect);single.before(modeRow);
  const folder=doc.createElement('section');folder.id='reference-folder-source';folder.hidden=true;
  folder.innerHTML='<label for="reference-folder-path">Model folder</label><div class="reference-path-row reference-folder-path-row"><input id="reference-folder-path" type="text" placeholder="C:\\models\\fuselage" spellcheck="false" title="Folder containing the related Nastran fragments. All subfolders will be searched."><button id="reference-folder-browse" type="button" title="Choose a folder inside this app, without opening a system file dialog.">Choose folder…</button></div><p>Searches this folder and all subfolders for .bdf, .dat, .nas, .bulk, .blk, .fem, .pch, .inc, .include and their gzip versions. A .inp file is included only when its contents are Nastran. Review the files before combining them.</p><div class="reference-folder-actions"><button id="reference-folder-scan" type="button" title="Search recursively and review the model fragments. This does not replace the current model.">Scan folder</button><button id="reference-folder-scan-cancel" type="button" hidden>Cancel scan</button></div><p id="reference-folder-scan-status" role="status" hidden></p><section id="reference-file-browser" hidden aria-label="Choose a local model folder"><h3>Choose a folder on this computer</h3><div class="reference-path-row"><input id="reference-directory-path" type="text" aria-label="Browse folder path" spellcheck="false"><button id="reference-folder-go" type="button">Go</button></div><div class="reference-folder-options"><button id="reference-folder-up" type="button" title="Go to the parent folder.">Up</button><label>Drive<select id="reference-folder-drive" aria-label="Drive or file-system root"></select></label></div><p id="reference-folder-status" role="status"></p><div id="reference-folder-list"></div><button id="reference-folder-more" type="button" hidden>Show more entries</button><div class="reference-folder-actions"><button id="reference-folder-use" class="primary" type="button" title="Select this directory and scan its subfolders.">Select this folder</button><button id="reference-folder-cancel" type="button">Cancel folder selection</button></div></section><section id="reference-folder-review" hidden><h3>Review the fragments</h3><p id="reference-folder-summary"></p><label class="reference-folder-check"><input id="reference-folder-all" type="checkbox" checked title="Include or exclude every discovered fragment, including files on other pages.">Include all discovered files</label><div class="reference-scan-table"><table><caption>Files to combine</caption><thead><tr><th scope="col">Use</th><th scope="col">Relative file path</th><th scope="col">Size</th></tr></thead><tbody id="reference-scan-rows"></tbody></table></div><div class="reference-folder-actions"><button id="reference-scan-previous" type="button">Previous files</button><span id="reference-scan-page"></span><button id="reference-scan-next" type="button">Next files</button></div><label id="reference-folder-primary-row" hidden>Analysis / case-control file<select id="reference-folder-primary" title="Choose the file whose executive and case-control definitions will be used. Other files contribute their bulk-data cards."></select></label><p id="reference-folder-primary-help" hidden></p><ul id="reference-folder-warnings"></ul><p>Identical duplicate cards are combined once. Conflicting definitions of the same ID stop the read and identify the files and lines; no definition is silently overwritten. The combined source is embedded when you Save Study.</p></section>';
  single.after(folder);
  const ignoreRow=doc.createElement('label');ignoreRow.className='reference-folder-check';ignoreRow.innerHTML='<input id="reference-folder-ignore-includes" type="checkbox" title="Use only when the original INCLUDE folder hierarchy is missing. Collect available fragments inside the chosen folder, ignore unresolved INCLUDE paths and report the missing dependencies. Missing model definitions can still fail native validation.">Ignore unresolved INCLUDE paths';folder.querySelector('.reference-folder-actions').before(ignoreRow);
  const ignoreHelp=doc.createElement('p');ignoreHelp.id='reference-folder-ignore-help';ignoreHelp.hidden=true;ignoreHelp.textContent='Only available files inside the chosen folder are combined. Missing INCLUDE dependencies are reported; this option does not invent missing nodes, properties, materials or constraints.';ignoreRow.after(ignoreHelp);
  const setup=doc.createElement('fieldset');setup.id='abaqus-completion';setup.hidden=true;
  setup.innerHTML='<legend>Mesh-only solid model: optional analysis setup</legend><label class="completion-enable"><input id="abaqus-completion-enabled" type="checkbox"> Add the material, constraints and analysis below</label><p>Leave unchecked to inspect the mesh and its named sets without inventing missing physics. Enable only for a solid mesh with no authored materials, sections or analysis steps. The selected element set must cover the complete model. Values use the input file&#39;s consistent unit system; no unit conversion is applied. Original source and these explicit choices are saved in the Study.</p><div class="completion-fields"></div>';
  const setupFields=setup.querySelector('.completion-fields');
  for(const [key,label,type,value]of [['E','Young modulus','number',7e10],['nu','Poisson ratio','number',.3],['rho','Mass density','number',2700],['element_set','Element set (ALL = every element)','text','ALL'],['constraint_set','Constrained node set(s), separated by ;','text',''],['constraint_dofs','Constrained components (1=X, 2=Y, 3=Z)','text','123'],['force_set','Force node set (static)','text',''],['total_force','Total applied force (static)','number',1],['force_x','Force direction X','number',0],['force_y','Force direction Y','number',0],['force_z','Force direction Z','number',1],['modes','Requested normal modes','number',10]]){
   const line=doc.createElement('label');line.textContent=label;const input=doc.createElement('input');input.dataset.completion=key;input.type=type;input.value=String(value);if(type==='number')input.step=key==='modes'?'1':'any';line.append(input);setupFields.append(line);if(key==='constraint_set')input.title='Use one existing node-set name, or join several with semicolons: BLOCK_FIXED;CYLINDER_TO_BLOCK. All selected nodes receive the chosen constraints. This does not create contact between disconnected bodies.';
  }
  const solutionLine=doc.createElement('label');solutionLine.textContent='Analysis ';const solutionSelect=doc.createElement('select');solutionSelect.dataset.completion='solution';for(const [v,t]of [['101','SOL101 - linear static'],['103','SOL103 - normal modes']]){const option=doc.createElement('option');option.value=v;option.textContent=t;solutionSelect.append(option);}solutionLine.append(solutionSelect);setupFields.prepend(solutionLine);
  const forceHelp=doc.createElement('p');forceHelp.textContent='Static force is distributed equally over the selected force nodes along the normalized direction. It is a total resultant, not a force applied separately at every node. Constraints fix the listed translations. For normal modes the density supplies mass; no force is applied.';setup.append(forceHelp);
  dialog.querySelector('#reference-import-status').before(setup);
  const setupToggle=setup.querySelector('#abaqus-completion-enabled');
  function syncSetup(){setup.hidden=modeSelect.value==='folder'||formatSelect.value!=='abaqus';for(const input of setup.querySelectorAll('[data-completion]'))input.disabled=!setupToggle.checked;}
  setupToggle.onchange=syncSetup;formatSelect.onchange=syncSetup;syncSetup();
  const preparation=doc.createElement('p');preparation.id='reference-preparation-status';preparation.setAttribute('role','status');preparation.hidden=true;dialog.querySelector('#reference-import-status').before(preparation);
  doc.body.append(dialog);const get=id=>dialog.querySelector('#'+id),error=get('reference-import-error'),status=get('reference-import-status');let running=false,picking=false,settle=null,outcome=false;
  let preparationTimer=null,preparationSerial=0,prepared=!prepareImporter;
  let folderData=null,folderScanPath='',folderScanIgnore=false,folderScanning=false,folderBrowsing=false,folderSerial=0,directorySerial=0,directoryData=null,filePage=0,selectedFiles=new Set();
  const byteText=value=>{const n=Number(value||0);return n>=1048576?(n/1048576).toFixed(2)+' MiB':n>=1024?(n/1024).toFixed(1)+' KiB':n+' B';};
  const folderFiles=()=>folderData?.files||[];
  const folderReady=()=>!!folderData&&!folderScanning&&!folderBrowsing&&folderScanPath===get('reference-folder-path').value.trim()&&folderScanIgnore===get('reference-folder-ignore-includes').checked&&selectedFiles.size>0&&(!folderData.primary_required||!!get('reference-folder-primary').value)&&(!get('reference-folder-primary').value||selectedFiles.has(get('reference-folder-primary').value));
  const syncReadReady=()=>{
   const folderMode=modeSelect.value==='folder',button=get('reference-read'),ready=prepared&&!running&&!picking&&(folderMode?folderReady():!!get('reference-local-path').value.trim());
   button.classList.toggle('deck-ready',ready);
   button.dataset.ready=String(ready);
   button.disabled=running||picking||(folderMode&&!folderReady());button.textContent=running?'Reading…':folderMode?'Read combined model':'Read deck';
   button.title=ready?(folderMode?'Importer ready. Combine the reviewed fragments into one model.':'Importer ready. Read the selected deck and its INCLUDE files.'):running?'Reading the selected model.':!prepared?'Importer preparation is still running. Reading can wait for preparation.':folderMode?'Scan the folder, review its files and select an analysis header when required.':'Select the main deck first.';
   modeSelect.disabled=running||picking;get('reference-folder-scan').disabled=running||picking||!get('reference-folder-path').value.trim();get('reference-folder-browse').disabled=running||picking;
   single.inert=running||picking;folder.inert=running||picking;
  };
  get('reference-local-path').addEventListener('input',syncReadReady);
  get('reference-local-path').addEventListener('change',syncReadReady);
  function invalidateFolder(message='Folder changed. Scan it again to review the fragments.'){
   folderSerial++;folderScanning=false;folderData=null;folderScanPath='';selectedFiles.clear();filePage=0;get('reference-folder-review').hidden=true;get('reference-folder-scan-cancel').hidden=true;
   const note=get('reference-folder-scan-status');note.hidden=!message;note.textContent=message;syncReadReady();
  }
  function updateFolderSummary(){
   const files=folderFiles(),selected=files.filter(file=>selectedFiles.has(file.path));
   get('reference-folder-summary').textContent=selected.length+' / '+files.length+' files selected · '+byteText(selected.reduce((sum,file)=>sum+Number(file.bytes||0),0))+' selected · '+byteText(folderData?.total_bytes??files.reduce((sum,file)=>sum+Number(file.bytes||0),0))+' found recursively';
   const all=get('reference-folder-all');all.checked=files.length>0&&selected.length===files.length;all.indeterminate=selected.length>0&&selected.length<files.length;
   const primary=get('reference-folder-primary');for(const option of primary.options)if(option.value)option.disabled=!selectedFiles.has(option.value);
   if(primary.value&&!selectedFiles.has(primary.value))primary.value='';syncReadReady();
  }
  function renderFolderFiles(){
   const files=folderFiles(),rows=get('reference-scan-rows');rows.replaceChildren();filePage=Math.max(0,Math.min(filePage,Math.ceil(files.length/100)-1));
   files.slice(filePage*100,filePage*100+100).forEach(file=>{const row=doc.createElement('tr'),checkCell=doc.createElement('td'),check=doc.createElement('input');check.type='checkbox';check.checked=selectedFiles.has(file.path);check.title='Include '+file.path;check.setAttribute('aria-label','Include '+file.path);check.onchange=()=>{if(check.checked)selectedFiles.add(file.path);else selectedFiles.delete(file.path);updateFolderSummary();};checkCell.append(check);const name=doc.createElement('td');name.textContent=file.path;const size=doc.createElement('td');size.textContent=byteText(file.bytes);row.append(checkCell,name,size);rows.append(row);});
   get('reference-scan-page').textContent=files.length?'Files '+(filePage*100+1)+'–'+Math.min((filePage+1)*100,files.length)+' of '+files.length:'No model fragments';get('reference-scan-previous').disabled=filePage===0;get('reference-scan-next').disabled=(filePage+1)*100>=files.length;updateFolderSummary();
  }
  async function scanCurrentFolder(){
   if(running||picking)return;const path=get('reference-folder-path').value.trim().replace(/^"(.*)"$/,'$1');if(!path){showError('Select a model folder or paste its full path.');return;}get('reference-folder-path').value=path;
   invalidateFolder('Scanning this folder and all subfolders…');const serial=folderSerial;folderScanning=true;get('reference-folder-scan-cancel').hidden=false;error.hidden=true;syncReadReady();
   try{
    if(!scanFolder)throw Error('Recursive scanning is unavailable. Restart Boxer to enable folder import.');
    const ignore_unresolved_includes=get('reference-folder-ignore-includes').checked;folderScanIgnore=ignore_unresolved_includes;
    const data=await scanFolder({path,ignore_unresolved_includes});if(serial!==folderSerial||!dialog.open)return;if(data?.ok===false)throw Error(data.error||'The folder scan failed.');
    if(!Array.isArray(data?.files))throw Error('The folder scan did not return a file list.');
    const files=data.files.map(file=>typeof file==='string'?{path:file,bytes:0}:{...file,path:String(file.path||file.name||'')});if(files.some(file=>!file.path))throw Error('The folder scan returned a file without its relative path.');
    if(!files.length)throw Error('No Nastran fragments were found in this folder or its subfolders.');
    const candidates=(data.primary_candidates||files.filter(file=>file.has_case_control).map(file=>file.path)).map(item=>typeof item==='string'?item:item.path);
    folderData={...data,files,primary_required:data.primary_required??candidates.length>1};folderScanPath=String(data.directory||data.path||path);get('reference-folder-path').value=folderScanPath;selectedFiles=new Set(files.map(file=>file.path));filePage=0;
    const primary=get('reference-folder-primary');primary.replaceChildren();const prompt=doc.createElement('option');prompt.value='';prompt.textContent=folderData.primary_required?'Choose which analysis definition to use':candidates.length>1?'Use matching analysis definitions':'No separate analysis header';primary.append(prompt);
    for(const name of candidates){const option=doc.createElement('option');option.value=name;option.textContent=name;primary.append(option);}if(candidates.length===1)primary.value=candidates[0];
    get('reference-folder-primary-row').hidden=!candidates.length;get('reference-folder-primary-help').hidden=!candidates.length;get('reference-folder-primary-help').textContent=folderData.primary_required?'Several files contain different analysis definitions. Select the intended analysis file explicitly; the other files contribute bulk data.':candidates.length>1?'The discovered analysis definitions match. A selected header can provide the analysis; all selected fragments contribute their bulk data.':'The listed file provides the analysis definition; all selected fragments contribute their bulk data.';
    const warnings=get('reference-folder-warnings');warnings.replaceChildren();for(const warning of data.warnings||[]){const item=doc.createElement('li');item.textContent=String(warning);warnings.append(item);}
    folderScanning=false;get('reference-folder-scan-cancel').hidden=true;get('reference-folder-review').hidden=false;renderFolderFiles();get('reference-folder-scan-status').textContent='Scan complete. Review the files below before reading the combined model.';
   }catch(problem){if(serial!==folderSerial)return;folderScanning=false;folderData=null;get('reference-folder-scan-cancel').hidden=true;get('reference-folder-scan-status').textContent='Scan failed. The current model has not changed.';showError(problem);}
   finally{if(serial===folderSerial)syncReadReady();}
  }
  async function loadDirectory(path,offset=0){
   path=String(path||'').trim().replace(/^"(.*)"$/,'$1');
   const serial=++directorySerial;get('reference-folder-status').textContent='Reading folder…';get('reference-folder-use').disabled=true;
   try{
    let data;if(listFolder)data=await listFolder({path,offset});else{const response=await (doc.defaultView||globalThis).fetch('/api/import_reference/browse?path='+encodeURIComponent(path||'')+'&all=1&offset='+offset,{cache:'no-store'});data=await response.json();if(!response.ok)throw Error(data.error||'Cannot browse this folder.');}
    if(serial!==directorySerial||!folderBrowsing||!dialog.open)return;if(data.ok===false)throw Error(data.error||'Cannot browse this folder.');directoryData=data;get('reference-directory-path').value=data.directory;get('reference-folder-up').disabled=!data.parent;const drives=get('reference-folder-drive');drives.replaceChildren();for(const name of data.drives||[]){const option=doc.createElement('option');option.value=name;option.textContent=name;drives.append(option);}const drive=[...drives.options].find(option=>String(data.directory).toLowerCase().startsWith(option.value.toLowerCase()));if(drive)drives.value=drive.value;
    const entries=get('reference-folder-list');if(!offset)entries.replaceChildren();for(const entry of data.entries||[]){const row=doc.createElement('button');row.type='button';row.className='reference-file-entry';row.dataset.kind=entry.directory?'folder':'file';row.disabled=!entry.directory;const name=doc.createElement('span');name.textContent=(entry.directory?'▸ ':'')+entry.name;const size=doc.createElement('small');size.textContent=entry.directory?'Folder':byteText(entry.bytes);row.append(name,size);row.title=entry.path;if(entry.directory)row.onclick=()=>loadDirectory(entry.path);entries.append(row);}
    get('reference-folder-status').textContent='Showing '+entries.children.length+' of '+data.total+' entries. Open a folder, then select it.';get('reference-folder-more').hidden=data.next_offset==null;get('reference-folder-use').disabled=false;
   }catch(problem){if(serial===directorySerial){get('reference-folder-status').textContent=problem.message||String(problem);get('reference-folder-use').disabled=true;}}
  }
  function closeFolderBrowser(){directorySerial++;folderBrowsing=false;get('reference-file-browser').hidden=true;syncReadReady();}
  async function chooseFolder(){
   if(running||picking)return;
   if(pickFolder){picking=true;syncReadReady();try{const data=await pickFolder({path:get('reference-folder-path').value.trim()});if(data?.ok===false)throw Error(data.error||'Cannot select a folder.');if(!data?.cancelled&&data?.path){get('reference-folder-path').value=data.path;invalidateFolder('');picking=false;await scanCurrentFolder();}}catch(problem){showError(problem);}finally{picking=false;syncReadReady();}return;}
   folderBrowsing=true;get('reference-file-browser').hidden=false;syncReadReady();await loadDirectory(get('reference-folder-path').value.trim());
  }
  get('reference-folder-path').addEventListener('input',()=>invalidateFolder());get('reference-folder-path').addEventListener('change',()=>{if(get('reference-folder-path').value.trim()!==folderScanPath)invalidateFolder();});
  get('reference-folder-ignore-includes').onchange=()=>{get('reference-folder-ignore-help').hidden=!get('reference-folder-ignore-includes').checked;invalidateFolder('INCLUDE handling changed. Scan the folder again to review its dependencies.');};
  get('reference-folder-browse').onclick=chooseFolder;get('reference-folder-scan').onclick=scanCurrentFolder;get('reference-folder-scan-cancel').onclick=()=>invalidateFolder('Scan cancelled. The current model has not changed.');
  get('reference-folder-all').onchange=()=>{selectedFiles=get('reference-folder-all').checked?new Set(folderFiles().map(file=>file.path)):new Set();renderFolderFiles();};get('reference-folder-primary').onchange=syncReadReady;
  get('reference-scan-previous').onclick=()=>{filePage--;renderFolderFiles();};get('reference-scan-next').onclick=()=>{filePage++;renderFolderFiles();};
  get('reference-folder-go').onclick=()=>loadDirectory(get('reference-directory-path').value.trim());get('reference-folder-up').onclick=()=>directoryData?.parent&&loadDirectory(directoryData.parent);get('reference-folder-drive').onchange=()=>loadDirectory(get('reference-folder-drive').value);get('reference-folder-more').onclick=()=>directoryData&&loadDirectory(directoryData.directory,directoryData.next_offset);
  get('reference-directory-path').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();loadDirectory(get('reference-directory-path').value.trim());}});
  get('reference-folder-cancel').onclick=closeFolderBrowser;get('reference-folder-use').onclick=()=>{if(!directoryData)return;get('reference-folder-path').value=directoryData.directory;closeFolderBrowser();invalidateFolder('');scanCurrentFolder();};
  modeSelect.onchange=()=>{single.hidden=modeSelect.value==='folder';folder.hidden=modeSelect.value!=='folder';closeFolderBrowser();syncSetup();syncReadReady();};
  const stopPreparation=()=>{preparationSerial++;clearTimeout(preparationTimer);preparationTimer=null;};
  async function prepare(start,serial){
   if(!prepareImporter)return;
   preparation.hidden=false;if(start){prepared=false;syncReadReady();preparation.textContent='Preparing importer\u2026 You can browse local files while it starts.';}
   try{
    const data=await prepareImporter(start);if(serial!==preparationSerial)return;
    const seconds=Number(data.seconds||0).toFixed(1);
    preparation.textContent=data.state==='ready'?'Importer ready \u00b7 preparation '+seconds+' s':data.state==='failed'?'Preparation failed: '+data.stage+' Read deck can retry.':(data.stage||'Preparing importer')+' \u00b7 '+seconds+' s. You can browse while this runs.';
    preparation.dataset.state=data.state;
    prepared=data.state==='ready';syncReadReady();
    if(data.state==='preparing')preparationTimer=setTimeout(()=>prepare(false,serial),750);
   }catch(problem){if(serial===preparationSerial)preparation.textContent='Importer preparation unavailable: '+(problem.message||problem)+'. Read deck remains available.';}
  }
  const showError=problem=>{error.textContent=problem?.message||String(problem);error.hidden=false;};
  get('reference-close').onclick=()=>dialog.close();
  dialog.addEventListener('cancel',event=>{if(running||picking)event.preventDefault();});
  dialog.addEventListener('close',()=>{stopPreparation();invalidateFolder('');closeFolderBrowser();const complete=settle;settle=null;complete?.(outcome);});
  async function browse(){
   if(picking||running)return;
   picking=true;syncReadReady();error.hidden=true;get('reference-browse').disabled=true;get('reference-read').disabled=true;get('reference-close').disabled=true;
   status.hidden=false;status.textContent='Select your main deck in the system Open dialog. INCLUDE files will be resolved automatically.';
   try{
    if(!pickFile)throw Error('The system picker is unavailable. Paste the complete main-deck path.');
    const data=await pickFile({path:get('reference-local-path').value.trim(),...(formatSelect.value==='auto'?{}:{format:formatSelect.value})});
    if(data.ok===false)throw Error(data.error||'Could not open the file dialog.');
    if(!data.cancelled&&data.path){get('reference-local-path').value=data.path;if(/\.inp(?:\.gz)?$/i.test(data.path)){formatSelect.value='abaqus';syncSetup();}get('reference-read').focus();}
   }catch(problem){showError(problem);}
   finally{picking=false;status.hidden=true;get('reference-browse').disabled=false;get('reference-read').disabled=false;get('reference-close').disabled=false;syncReadReady();}
  }
  get('reference-browse').onclick=browse;
  dialog.querySelector('form').onsubmit=async event=>{
   event.preventDefault();if(running||picking)return;error.hidden=true;
   const folderMode=modeSelect.value==='folder',selected=get(folderMode?'reference-folder-path':'reference-local-path').value.trim().replace(/^"(.*)"$/,'$1');if(!selected){showError(folderMode?'Choose a model folder and scan its fragments.':'Browse for the main deck or paste its full path. INCLUDE files will be read automatically.');return;}
   let request={path:selected};try{
    if(folderMode){if(!folderReady())throw Error('Scan the folder and review the selected fragments before reading. Select the intended analysis file if several definitions were found.');request.mode='folder';request.selected_files=[...selectedFiles];request.ignore_unresolved_includes=get('reference-folder-ignore-includes').checked;if(get('reference-folder-primary').value)request.primary_file=get('reference-folder-primary').value;if(folderData.scan_id!=null)request.scan_id=folderData.scan_id;if(folderData.expected_scan!=null)request.expected_scan=folderData.expected_scan;}
    else if(formatSelect.value!=='auto')request.format=formatSelect.value;
    if(!folderMode&&formatSelect.value==='abaqus'&&setupToggle.checked){const values={enabled:true};for(const input of setup.querySelectorAll('[data-completion]'))values[input.dataset.completion]=input.type==='number'?Number(input.value):input.value;values.force_direction=[values.force_x,values.force_y,values.force_z];request.completion=completion(values);}
   }catch(problem){showError(problem);return;}
   const button=get('reference-read'),started=Date.now();running=true;syncReadReady();button.disabled=true;get('reference-close').disabled=true;get('reference-browse').disabled=true;button.textContent='Reading\u2026';status.hidden=false;
   const update=()=>{status.textContent=(folderMode?'Combining folder fragments':'Importing deck')+' \u00b7 '+Math.floor((Date.now()-started)/1000)+' s. Parser preparation, file reading and geometry stages are shown in Log.';};update();const timer=setInterval(update,1000);
   try{if(await onImport(request)){outcome=true;dialog.close();}else throw Error('The deck was not loaded. Wait for the current operation to finish and try again.');}
   catch(problem){showError(problem);if(!dialog.open)dialog.showModal();}
   finally{clearInterval(timer);running=false;status.hidden=true;button.disabled=false;get('reference-close').disabled=false;get('reference-browse').disabled=false;button.textContent='Read deck';syncReadReady();}
  };
  syncReadReady();
  return{open(options={}){modeSelect.value=options.format==='abaqus'?'single':options.mode||'single';single.hidden=modeSelect.value==='folder';folder.hidden=modeSelect.value!=='folder';formatSelect.value=options.format||'auto';syncSetup();dialog.querySelector('h2').textContent=options.format==='abaqus'?'Read Abaqus input':'Read Nastran';error.hidden=true;outcome=false;dialog.showModal();get(modeSelect.value==='folder'?'reference-folder-path':'reference-local-path').focus();stopPreparation();syncReadReady();prepare(true,preparationSerial);const promise=new Promise(resolve=>{settle=resolve;});if(options.browse!==false){if(modeSelect.value==='folder')chooseFolder();else browse();}return promise;},destroy(){stopPreparation();folderSerial++;directorySerial++;settle?.(false);settle=null;dialog.remove();}};
 }
 return{source,path,format,completion,includeReferences,relativeInclude,uploadSource,create};
});
