/* Comment entry and read-only Study previews. Neither action writes a file. */
(function(root,factory){
  const api=factory(typeof module==="object"&&module.exports?require("./workspace.js"):root.WingWorkspace);
  if(typeof module==="object"&&module.exports)module.exports=api;else root.WingStudyComments=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(workspace){
  "use strict";
  function metadata(text){
    const data=JSON.parse(text);
    if(!data||data.format!==workspace.FORMAT||data.version!==workspace.VERSION)throw Error("Choose a valid .wingfem.json Study file.");
    // Preview only metadata: do not decode references or prepare a model.
    return {notes:workspace.normalizeNotes(data.notes),savedAt:data.saved_at||null,createdAt:data.created_at||null};
  }
  function element(doc,tag,cls,text){const node=doc.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;}
  function history(doc,notes){
    const section=element(doc,"section","study-comments-history"),heading=element(doc,"h3","","Saved comments");section.append(heading);
    if(!notes.history.length)section.append(element(doc,"p","study-comments-empty","No saved comments in this Study."));
    const list=element(doc,"ol","study-comments-list");
    for(const entry of [...notes.history].reverse()){
      const item=element(doc,"li"),time=element(doc,"time","",new Date(entry.saved_at).toLocaleString());time.dateTime=entry.saved_at;time.title=entry.saved_at;
      item.append(time,element(doc,"p","",entry.text));list.append(item);
    }
    section.append(list);
    if(notes.text.trim()&&notes.text!==notes.history.at(-1)?.text)section.append(element(doc,"h3","","Current note"),element(doc,"p","study-comments-current",notes.text));
    return section;
  }
  function modal(doc,title){
    const dialog=element(doc,"dialog","study-comments-dialog"),heading=element(doc,"h2","",title);heading.id="study-comments-heading";
    dialog.setAttribute("aria-labelledby",heading.id);dialog.append(heading);doc.body.append(dialog);return dialog;
  }
  function promptSave({document:doc=globalThis.document,notes,draft="",saveAs=false,onSave,onCancel}={}){
    const saved=workspace.normalizeNotes(notes),dialog=modal(doc,saveAs?"Save Study as":"Save Study"),input=element(doc,"textarea","study-save-comment"),label=element(doc,"label","","Comment about this save (optional)");
    input.id="study-save-comment";input.rows=5;input.maxLength=workspace.MAX_NOTE_LENGTH;input.value=draft;input.placeholder="Describe what changed and why…";label.htmlFor=input.id;
    dialog.append(element(doc,"p","study-comments-intro","A new comment is appended to the Study history with the date and time when saved. Earlier comments are retained."),label,input,history(doc,saved));
    const actions=element(doc,"div","study-comments-actions"),cancel=element(doc,"button","study-comments-cancel","Cancel"),save=element(doc,"button","study-comments-save",saveAs?"Save Study as…":"Save Study");
    cancel.type=save.type="button";actions.append(cancel,save);dialog.append(actions);
    return new Promise((resolve,reject)=>{
      let settled=false;
      const dismiss=()=>{dialog.close();dialog.remove();};
      const close=()=>{if(settled)return;settled=true;onCancel?.(input.value);dismiss();resolve(false);};
      cancel.onclick=close;dialog.addEventListener("cancel",event=>{event.preventDefault();close();});
      save.onclick=()=>{if(settled)return;settled=true;const text=input.value;dismiss();try{
        // Call immediately in this click: native file pickers require user activation.
        resolve(onSave(text));
      }catch(error){reject(error);}};
      dialog.showModal();input.focus();
    });
  }
  async function previewFile(file,{document:doc=globalThis.document,source="browse",recordedAt=null}={}){
    if(!file)return false;
    const dialog=modal(doc,"Study comments"),name=element(doc,"p","study-comments-filename",file.name),status=element(doc,"p","study-comments-source",source==="snapshot"?"Stored browser copy"+(recordedAt?" captured "+new Date(recordedAt).toLocaleString():"")+". Later disk changes are not included.":"Selected disk file. This Study has not been loaded.");
    const content=element(doc,"div","study-comments-content"),actions=element(doc,"div","study-comments-actions"),cancel=element(doc,"button","study-comments-cancel","Cancel"),open=element(doc,"button","study-comments-open","Load Study");
    cancel.type=open.type="button";open.disabled=true;content.textContent="Reading comments…";actions.append(cancel,open);dialog.append(name,status,content,actions);
    let finish,closed=false;
    const result=new Promise(resolve=>{finish=value=>{if(closed)return;closed=true;dialog.close();dialog.remove();resolve(value);};});
    cancel.onclick=()=>finish(false);open.onclick=()=>finish(true);dialog.addEventListener("cancel",event=>{event.preventDefault();finish(false);});dialog.showModal();cancel.focus();
    try{
      const data=metadata(await file.text());if(closed)return result;content.replaceChildren();
      if(data.savedAt&&Number.isFinite(Date.parse(data.savedAt)))content.append(element(doc,"p","study-comments-saved","Study saved "+new Date(data.savedAt).toLocaleString()));
      content.append(history(doc,data.notes));open.disabled=false;
    }catch(error){if(!closed){content.textContent="Cannot read Study comments: "+error.message;content.setAttribute("role","alert");}}
    return result;
  }
  return {metadata,promptSave,previewFile};
});
