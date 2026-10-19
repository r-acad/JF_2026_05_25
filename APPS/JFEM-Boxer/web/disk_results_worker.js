/* The archived mesh is committed only after decoding and validation finish. */
importScripts('shared/jfem_binary.js','solid_boundary.js','disk_results.js');
let parsed;
self.onmessage=event=>{try{if(event.data.buffer){parsed=JFEMBinary.parse(event.data.buffer);self.postMessage({info:WingDiskResults.kindInfo(parsed)});return;}const prepared=WingDiskResults.prepare(parsed,event.data),buffers=new Set();function visit(value){if(!value||typeof value!=='object')return;if(ArrayBuffer.isView(value)){buffers.add(value.buffer);return;}for(const child of Object.values(value))visit(child);}visit(prepared);self.postMessage({prepared},[...buffers]);parsed=null;}catch(error){self.postMessage({error:error.message});}};
