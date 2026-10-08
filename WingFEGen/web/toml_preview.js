(function(root){
 "use strict";
 function create({document:doc=root.document,readCurrent,readServer}){
  const dialog=doc.createElement("dialog");dialog.className="toml-preview";dialog.setAttribute("aria-labelledby","toml-preview-title");
  dialog.innerHTML='<header><h2 id="toml-preview-title">View TOML</h2><button type="button" data-toml="maximize" aria-pressed="false">Maximize</button><button type="button" data-toml="close" aria-label="Close TOML preview">×</button></header><div class="toml-preview-actions"><label>Source <select data-toml="source" aria-label="TOML preview source"><option value="current">Current definition · includes unsaved edits</option><option value="server">Server input file · saved on disk</option></select></label><button type="button" data-toml="refresh">Refresh</button><button type="button" data-toml="copy">Copy text</button></div><p data-toml="status" role="status"></p><p data-toml="note"></p><pre tabindex="0" data-toml="text" aria-label="Read-only TOML text"></pre>';
  doc.body.append(dialog);const get=name=>dialog.querySelector('[data-toml="'+name+'"]');let revision=0,timer=null,returnFocus=null;
  async function refresh(){const request=++revision,source=get("source").value,started=performance.now();get("text").textContent="";get("note").textContent="";get("copy").disabled=true;
   clearInterval(timer);const tick=()=>{get("status").textContent="Reading TOML · "+((performance.now()-started)/1000).toFixed(1)+" s";};tick();timer=setInterval(tick,100);
   try{const result=await(source==="server"?readServer():readCurrent());if(request!==revision)return;get("text").textContent=result.text;get("status").textContent=result.name||"TOML";get("note").textContent=result.note||"Read-only preview. No file has been written.";get("copy").disabled=false;}
   catch(error){if(request!==revision)return;get("status").textContent="Cannot show TOML: "+error.message;get("note").textContent=source==="current"?"Correct the invalid inputs, or choose Server input file to inspect the saved file.":"The server file is separate from the current Study definition.";}
   finally{if(request===revision){clearInterval(timer);timer=null;}}
  }
  get("source").onchange=refresh;get("refresh").onclick=refresh;get("close").onclick=()=>dialog.close();
  get("maximize").onclick=()=>{const on=dialog.classList.toggle("is-maximized");get("maximize").textContent=on?"Restore":"Maximize";get("maximize").setAttribute("aria-pressed",String(on));};
  get("copy").onclick=async()=>{try{await root.navigator.clipboard.writeText(get("text").textContent);get("note").textContent="TOML copied to clipboard. No file has been written.";}catch{get("note").textContent="Select the text and copy it using Ctrl+C (Cmd+C on Mac).";const range=doc.createRange();range.selectNodeContents(get("text"));const selection=doc.getSelection();selection.removeAllRanges();selection.addRange(range);}};
  dialog.addEventListener("close",()=>{revision++;clearInterval(timer);returnFocus?.focus();});
  return{open(source="current"){get("source").value=source;returnFocus=doc.activeElement;if(!dialog.open)dialog.showModal();refresh();},dialog,destroy(){revision++;clearInterval(timer);dialog.remove();}};
 }
 root.WingTomlPreview={create};
})(globalThis);
